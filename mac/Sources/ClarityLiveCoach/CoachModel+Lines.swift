import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// The coaching line on screen: asking Claude, holding a line until the rep has read it, history and journey.
extension CoachModel {
    func trackJourney(_ stage: String) {
        let step: Int?
        switch stage {
        case "Opener", "Screener", "Gatekeeper", "Voicemail": step = 0
        case "Discovery": step = 1
        case "Value": step = 2
        case "Closing", "Goal reached": step = 3
        default: step = nil // Objection, Exit: stay where we are
        }
        if let step, step > journeyStep { journeyStep = step }
    }

    /// Shows the line before the one on screen.
    func back() {
        let current = historyIndex ?? history.count - 1
        guard current > 0 else { return }
        historyIndex = current - 1
        suggestion = history[current - 1].s
        kind = history[current - 1].kind
    }

    /// Back to the newest line after looking back.
    func showLatest() {
        guard let latest = history.last else { return }
        historyIndex = nil
        suggestion = latest.s
        kind = latest.kind
    }

    /// Asks for the line that moves the call to the next step.
    func advanceStep() {
        guard let next = nextStepName else { newLine(); return }
        newLine(extra: "Move the call forward to the next step: \(next). Write the line that starts it now.")
    }

    /// The meeting times Claude may offer, with stable codes for this call, and which two to offer next.
    func bookingText() -> String? {
        let slots = availability.offerSlots()
        guard !slots.isEmpty else { return nil }
        for slot in slots where codeByDate[slot] == nil {
            codeByDate[slot] = "T\(codeByDate.count + 1)"
        }
        let next = pickNextPair(from: slots)
        nextOffer = next
        let list = slots.map { slot in
            "\(codeByDate[slot]!): \(availability.label(slot))" + (offeredTimes.contains(slot) ? " (already offered)" : "")
        }.joined(separator: "\n")
        let nextCodes = next.compactMap { codeByDate[$0] }.joined(separator: " or ")
        return """
        Meeting times open on the host's calendar (exact start times, \(availability.zoneName) time). Offer only these:
        \(list)
        When asking for the meeting, offer exactly these two next: \(nextCodes). Say them naturally, like "Tuesday at 10 or Wednesday at 2:30".
        If they turn times down, the next message gives you new ones; never re-offer a time marked already offered.
        If the prospect names a time, check the list. If it's there, confirm it. If not, offer the closest listed time.
        Whenever your SAY offers or confirms specific times, add a last line: OFFERED: <their codes, comma separated>.
        """
    }

    /// Two not-yet-offered times: the soonest, plus one on another day (or at least 3 hours apart).
    func pickNextPair(from slots: [Date]) -> [Date] {
        let fresh = slots.filter { !offeredTimes.contains($0) }
        guard let first = fresh.first else { return [] }
        let cal = Calendar.current
        let second = fresh.dropFirst().first { !cal.isDate($0, inSameDayAs: first) }
            ?? fresh.dropFirst().first { $0.timeIntervalSince(first) >= 3 * 3600 }
            ?? fresh.dropFirst().first
        return [first] + (second.map { [$0] } ?? [])
    }

    /// The rep asked for a different line right now. Skips the wait and the hold.
    func newLine(extra: String = "The rep asked for a different line than the last one.") {
        guard status == .live, !voicemailActive else { return }
        let latest = uncoached.trimmed.isEmpty ? (turns.last { $0.speaker == .prospect }?.text ?? "") : uncoached.trimmed
        uncoached = ""
        shownAt = .distantPast // no hold for a line the rep asked for
        repWordsSinceShown = 99
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: latest, calling: calling, details: recordDetails, style: callOpener,
            openTimes: bookingText()
        ) + "\n" + extra)
    }

    /// The rep clicked "Other times": count the current pair as turned down.
    func skipOfferedTimes() {
        offeredTimes.formUnion(nextOffer)
        nextOffer = pickNextPair(from: availability.offerSlots())
    }

    /// Instant line for a call screener. No Claude call, no waiting.
    func showScreenerLine() {
        screenerActive = true
        coachTask?.cancel()
        thinking = false
        holdTask?.cancel()
        pending = nil
        if kind == .opener { openerBeforeScreener = suggestion }
        seq += 1
        show(Suggestion(say: Screener.line(calling: calling),
                        cue: "Call screener. Say it slowly and clearly, then wait.",
                        stage: "Screener"),
             id: seq, kind: .screener)
    }

    /// If the prospect's words end like a finished sentence and hold still for a moment,
    /// start Claude now instead of waiting for the end-of-speech signal.
    func scheduleEarlyStart() {
        specTimer?.cancel()
        guard status == .live, !screenerActive, !voicemailActive, !lineIsFresh else { return }
        let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
        guard let last = text.last, ".?!".contains(last), isMeaningful(text) else { return }
        specTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled,
                  (self.uncoached + " " + (self.interim[.prospect] ?? "")).trimmed == text,
                  normalized(text) != self.specBasis else { return }
            self.ask(.reply, user: CoachPrompt.reply(
                turns: self.turns, latest: text, calling: self.calling, details: self.recordDetails, style: self.callOpener,
                openTimes: self.bookingText()
            ), early: text)
        }
    }

    /// The prospect stopped talking. Decide if the rep needs a new line.
    func prospectFinished() {
        specTimer?.cancel()
        let said = uncoached.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        if phoneTreeActive { uncoached = ""; askPhoneTree(); return } // the menu goes on: re-plan the route
        if voicemailActive { uncoached = ""; return } // no coaching while a greeting plays
        // Started early on exactly these words? Then the answer is already on its way.
        if let basis = specBasis {
            specBasis = nil
            if basis == normalized(said) {
                uncoached = ""
                latestProspect = said
                confirmedAt = Date()
                if let held = specHeld {
                    specHeld = nil
                    offer(held.s, id: held.id, kind: .reply, askedAt: confirmedAt!)
                }
                return
            }
        }
        if screenerActive {
            uncoached = ""
            if Screener.detects(said) { return } // still the screener talking
            // A real person picked up after the screener: back to the opener.
            screenerActive = false
            latestProspect = said
            if let opener = openerBeforeScreener {
                seq += 1
                show(opener, id: seq, kind: .opener)
                return
            }
        }
        // The rep hasn't said the line on screen yet: keep it. Their words stay queued
        // and are answered once the rep has spoken and they reply.
        if lineIsFresh {
            latestProspect = said
            return
        }
        uncoached = ""
        latestProspect = said
        // A plain "Hello?" is already answered by the opener on screen.
        let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
        // "Sure" or "Yes" is filler while the rep talks, but a real answer to the rep's question.
        let repAsked = turns.last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else { return }
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: said, calling: calling, details: recordDetails, style: callOpener,
            openTimes: bookingText()
        ))
    }

    func prepareOpener() {
        // A ready-to-read line right away (from the opener template), so there's always a script
        // on screen before the phone rings. Claude's personal version replaces it when it's ready.
        seq += 1
        instantOpenerID = seq
        show(instantOpener(for: calling), id: seq, kind: .opener)
        ask(.opener, user: CoachPrompt.opener(calling: calling, details: recordDetails, style: openerStyle,
                                              scriptOpener: openerStyle == nil ? scriptOpenerLine() : nil))
    }

    func ask(_ kind: Kind, user: String, early: String? = nil) {
        guard let key = Keychain.read(.anthropic) else {
            problem = "Add your Anthropic key: gear > Setup > AI keys."
            return
        }
        coachTask?.cancel() // a newer statement makes the old answer stale
        seq += 1
        let id = seq
        let askedAt = Date()
        specBasis = early.map(normalized)
        specHeld = nil
        confirmedAt = nil
        // Voicemails always use Haiku, so the message is ready before the beep.
        let client = (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)
        let system = self.system
        thinking = true

        coachTask = Task { [weak self] in
            do {
                var finalText = ""
                try await client.stream(system: system, user: user) { text in
                    finalText = text
                    let s = Suggestion.parse(text)
                    Task { @MainActor in self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
                }
                var last = Suggestion.parse(finalText)
                last.sayComplete = true
                self?.offer(last, id: id, kind: kind, askedAt: askedAt)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                // Keep the last good line on screen; just flag it.
                self?.problem = "Coach hiccup: \(error.localizedDescription)"
                ActivityLog.problem("Claude error: \(error.localizedDescription)")
            }
            if self?.seq == id { self?.thinking = false }
        }
    }

    /// Shows a suggestion, but never swaps a fresh line out from under the rep.
    func offer(_ s: Suggestion, id: Int, kind: Kind, askedAt: Date) {
        guard id == seq, !s.skip, !s.say.isEmpty else { return }
        // Easier to read live: show the line once it's whole, not word by word (setting).
        let wholeLine = Prefs.wholeLine
        if wholeLine && !s.sayComplete { return }
        if specBasis != nil {
            specHeld = (s, id) // started early: wait until they really stop talking
            return
        }
        if kind == .reply, timedID != id {
            timedID = id // time from "they stopped talking" to the first words of the answer
            latency = max(0, Date().timeIntervalSince(confirmedAt ?? askedAt))
        }
        if id == shownID {
            if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
            suggestion = s // same answer, still streaming in
            note(s)
            return
        }
        // The call is live and someone already talked: keep the opener the rep is reading.
        if kind == .opener, status == .live, repWordsInCall > 0 || turns.contains(where: { $0.speaker == .prospect }) { return }
        let waited = Date().timeIntervalSince(shownAt)
        if kind == .opener || kind == .voicemail || shownID == 0 || waited >= hold {
            show(s, id: id, kind: kind)
        } else {
            pending = (id, s)
            holdTask?.cancel()
            let delay = hold - waited
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, let next = self.pending, next.id == self.seq else { return }
                self.show(next.suggestion, id: next.id, kind: kind)
            }
        }
    }

    func show(_ s: Suggestion, id: Int, kind: Kind) {
        if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
        pending = nil
        shownID = id
        shownAt = Date()
        repWordsSinceShown = 0
        suggestion = s
        historyIndex = nil
        if !s.say.isEmpty, s.sayComplete || kind != .reply { history.append((s: s, kind: kind)) }
        self.kind = kind
        problem = nil
        note(s)
    }

    /// Bookkeeping for what a line tells us: stage reached, times offered, goal, voicemail.
    func note(_ s: Suggestion) {
        if status != .ready, !s.stage.isEmpty {
            stagesSeen.insert(s.stage)
            trackJourney(s.stage)
        }
        if voicemailActive, !s.textMessage.isEmpty || !s.linkedin.isEmpty || !s.linkedinMessage.isEmpty { fillFollowUp(from: s) }
        // Remember which meeting times this line offered, so the next ones are different.
        if !s.offered.isEmpty {
            let dates = s.offered.compactMap { code in codeByDate.first { $0.value == code }?.key }
            offeredTimes.formUnion(dates)
            nextOffer = pickNextPair(from: availability.offerSlots())
        }
        if s.stage == "Closing" { availability.refreshIfOlder() } // fresh times while booking
        if s.stage == "Goal reached" { goalHit = true }
        if s.stage == "Voicemail" { sawVoicemail = true }
    }

    func scheduleStillWithMe() {
        stillWithMeTask?.cancel()
        guard let last = turns.last, last.speaker == .rep, last.text.trimmed.hasSuffix("?"),
              turns.contains(where: { $0.speaker == .prospect }),
              !voicemailActive, !screenerActive, !phoneTreeActive, !badNumberThisCall else { return }
        let askedAt = lastWordsAt
        stillWithMeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, self.status == .live, self.lastWordsAt == askedAt,
                  self.turns.last?.speaker == .rep, !self.voicemailActive,
                  (self.interim[.prospect] ?? "").isEmpty else { return } // they're mid-answer
            self.coachTask?.cancel()
            self.thinking = false
            self.seq += 1
            self.show(Suggestion(say: "Still with me?", cue: "6 seconds of silence after your question.",
                                 stage: "", sayComplete: true), id: self.seq, kind: .reply)
            self.repWordsSinceShown = 99 // a nudge, not a script line: never hold the prospect's answer for it
        }
    }

    /// Switches (or refreshes) the campaign. Takes effect right away between calls.
    /// Refreshes the opener after a setting changes (rotation, your name).
    func refreshOpener() {
        if status == .ready { prepareOpener() }
    }
}
