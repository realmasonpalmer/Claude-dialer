import AppKit
import CoachCore
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
        CallTrace.event("manual", ["action": "Different line", "was": suggestion.say])
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
        guard status == .live, !screenerActive, !voicemailActive else { return } // prepare even while a line is up
        let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
        guard isMeaningful(text) else { return }
        // Known objection mid-sentence: the approved answer is ready the moment they stop.
        if scriptAnswers.match(text) != nil {
            specTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                _ = self.instantAnswer(text)
            }
            return
        }
        // Draft early once their meaning is clear: a finished sentence (200 ms), or 6+ words that
        // stopped changing (450 ms). Each new word cancels the wait, so there's no flood of requests.
        let finished = text.last.map { ".?!".contains($0) } ?? false
        guard finished || text.split(separator: " ").count >= 6 else { return }
        specTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(finished ? 200 : 450))
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
        if status == .live, LiveCoach.isOptOut(said) { handleOptOut(said); return }
        if phoneTreeActive { uncoached = ""; askPhoneTree(); return } // the menu goes on: re-plan the route
        if voicemailActive { uncoached = ""; return } // no coaching while a greeting plays
        // Started early on exactly these words? Then the answer is already on its way.
        if let basis = specBasis {
            specBasis = nil
            if basis != normalized(said) {
                CallTrace.event("early.wasted", ["basis": basis, "said": said, "why": "they kept talking after the early draft started"])
            }
            if basis == normalized(said) {
                CallTrace.event("early.used", ["basis": basis, "said": said, "why": "their final words matched the early draft"])
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
        // Always prepare an answer. Whether it shows now or waits is the display controller's call
        // (CoachMachine.canReplace): the line being read is never swapped out from under the rep.
        uncoached = ""
        latestProspect = said
        // A plain "Hello?" is already answered by the opener on screen.
        let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
        // "Sure" or "Yes" is filler while the rep talks, but a real answer to the rep's question.
        let repAsked = turns.last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else { return }
        if instantAnswer(said) { return }
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: said, calling: calling, details: recordDetails, style: callOpener,
            openTimes: bookingText()
        ))
        updateSummaryIfDue()
    }

    /// Every 4 prospect turns, Haiku writes a short summary of the call in the background, so each live
    /// line only needs the last minute word for word.
    func updateSummaryIfDue() {
        let theirs = turns.filter { $0.speaker == .prospect }.count
        guard theirs >= 4, theirs % 4 == 0, let key = Keychain.read(.anthropic) else { return }
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        Task {
            var c = LiveCoach.client(key)
            c.maxTokens = 250
            var text = ""
            try? await c.stream(system: "Summarize a live sales call for a coach in 3 to 6 short bullets: who they are, their situation, any numbers, pains, objections raised, what was agreed. Only what was said. No preamble.",
                                user: transcript) { text = $0 }
            if !text.isEmpty {
                CoachPrompt.liveSummary = text
                CallTrace.memVersion += 1
                CallTrace.event("memory.update", ["summary": text, "covers_turns": theirs, "evidence_chars": transcript.count])
            }
        }
    }

    /// "Take me off your list": the goodbye line, DoNotCall written in Salesforce, off every list, hang up. No AI.
    func handleOptOut(_ said: String) {
        coachTask?.cancel()
        thinking = false
        seq += 1
        show(Suggestion(say: LiveCoach.optOutLine, cue: "Opt out. Do not call is saved in Salesforce.", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
        guard let key = currentAttemptKey else { return }
        RemovedList.add(key)
        outcomeSaved.insert(String(key.prefix(15))) // nothing more to log
        ActivityLog.add("Opt out from \(calling ?? key): \"\(said)\". Off every list, writing DoNotCall")
        CallTrace.event("intent", ["intent": "opt_out", "said": said, "why": "opt-out phrase in their words", "action": "goodbye line, DoNotCall, hang up"])
        Task { [weak self] in
            do {
                try await Salesforce.setDoNotCall(key)
                ActivityLog.add("Opt out: DoNotCall saved in Salesforce for \(self?.calling ?? key)")
            } catch {
                ActivityLog.problem("Opt out: couldn't save DoNotCall in Salesforce: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(6)) // time to say goodbye
            guard let self, self.status == .live, AircallPhone.isOn else { return }
            _ = await AircallPhone.shared.hangUp()
        }
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
        if kind == .reply { CoachPrompt.questionFacts = questionTracker.promptText }
        if kind == .reply { ActivityLog.add("Coach #\(id): asking Claude\(early == nil ? "" : " early, from their words so far")") }
        CallTrace.event("claude.request", [
            "kind": "\(kind)", "early": early != nil, "early_basis": early ?? "",
            "system_chars": self.system.count, "system_hash": String(self.system.hashValue, radix: 16),
            "user_message": user, "summary_version": CallTrace.memVersion,
        ], req: id)
        specBasis = early.map(normalized)
        specHeld = nil
        confirmedAt = nil
        // Live lines: Haiku, short and fast. Voicemails also Haiku, so the message is ready before the beep.
        let client = kind == .reply ? LiveCoach.client(key)
            : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)
        let system = self.system
        thinking = true
        CallTrace.event("claude.settings", ["model": client.model, "max_tokens": client.maxTokens, "effort": client.effort,
                                            "thinking": client.thinking?["type"] ?? "default", "stream": true,
                                            "idle_timeout_s": client.idleTimeout, "total_timeout_s": client.totalTimeout], req: id)

        coachTask = Task { [weak self] in
            do {
                var finalText = ""
                let gate = LineGate()
                let started = Date()
                var firstToken = false
                try await client.stream(system: system, user: user) { text in
                    if !firstToken, kind == .reply {
                        firstToken = true
                        ActivityLog.add("Coach #\(id): first words from Claude after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        Task { @MainActor in CallTrace.event("claude.first_token", ["ms": ms], req: id) }
                    }
                    finalText = text
                    let s = Suggestion.parse(text)
                    Task { @MainActor in
                        guard kind == .reply else { self?.offer(s, id: id, kind: kind, askedAt: askedAt); return }
                        // A live line shows only once it's whole and passes the house rules.
                        guard s.sayComplete || s.skip, !gate.checked else { if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }; return }
                        gate.checked = true
                        gate.passed = s.skip || Self.lineProblems(s).isEmpty
                        if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
                    }
                }
                if kind == .reply { ActivityLog.add("Coach #\(id): Claude done after \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
                CallTrace.event("claude.done", ["ms": Int(Date().timeIntervalSince(started) * 1000), "output": finalText,
                                                "fresh": self?.seq == id], req: id)
                var last = Suggestion.parse(finalText)
                last.sayComplete = true
                if kind == .reply, !last.skip, !last.say.isEmpty, !Self.lineProblems(last).isEmpty {
                    last = await self?.fixLine(last, system: system, user: user, key: key) ?? last
                }
                self?.offer(last, id: id, kind: kind, askedAt: askedAt)
            } catch is CancellationError {
                CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
            } catch let error as URLError where error.code == .cancelled {
                CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
            } catch {
                CallTrace.event("claude.error", ["error": error.localizedDescription], req: id)
                // Keep the last good line on screen; just flag it.
                self?.problem = "Coach hiccup: \(error.localizedDescription)"
                ActivityLog.problem("Claude error: \(error.localizedDescription)")
            }
            if self?.seq == id { self?.thinking = false }
        }
    }

    /// The house rules for a live line (offered meeting times are allowed).
    static func lineProblems(_ s: Suggestion) -> [String] {
        Guardrail.problems(s.say, endsCall: ["Exit", "Goal reached", "Voicemail"].contains(s.stage), allowTimes: true)
    }

    /// A line broke the rules: Haiku tries again with the reasons, then Sonnet, then the smallest safe fix.
    func fixLine(_ bad: Suggestion, system: String, user: String, key: String) async -> Suggestion {
        var problems = Self.lineProblems(bad)
        ActivityLog.add("Line check: failed (\(problems.joined(separator: "; "))): \(bad.say)")
        CallTrace.event("check.fail", ["line": bad.say, "problems": problems])
        for model in ["claude-haiku-5-5", "claude-sonnet-5-5"] {
            var text = ""
            let retry = user + "\n\nYour last SAY broke these rules: \(problems.joined(separator: "; ")). It was: \"\(bad.say)\". Write it again."
            try? await LiveCoach.client(key, model: model).stream(system: system, user: retry) { text = $0 }
            var s = Suggestion.parse(text)
            s.sayComplete = true
            if s.skip || (!s.say.isEmpty && Self.lineProblems(s).isEmpty) {
                ActivityLog.add("Line check: fixed by \(model.contains("haiku") ? "Haiku" : "Sonnet")")
                CallTrace.event("check.fixed", ["model": model, "line": s.say])
                return s
            }
            if !s.say.isEmpty { problems = Self.lineProblems(s) }
        }
        var s = bad
        s.say = LiveCoach.sanitize(bad.say)
        ActivityLog.add("Line check: trimmed to fit: \(s.say)")
        CallTrace.event("check.trimmed", ["line": s.say])
        return s
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
            var s = s
            s.say = fillTags(s.say, for: calling) // never show a bare [Name] or [SDR]
            suggestion = s // same answer, still streaming in
            note(s)
            return
        }
        // The call is live and someone already talked: keep the opener the rep is reading.
        if kind == .opener, status == .live, repWordsInCall > 0 || turns.contains(where: { $0.speaker == .prospect }) { return }
        // The AI thinks ahead, the screen follows the conversation: never swap the line while the rep is
        // speaking. Queue it, flag the old one as outdated, and show it the moment they stop.
        // A new prospect turn since the line appeared = the conversation moved on.
        // Only a real reply moves the conversation on (3+ words or a question), not "uh-huh" or "yeah".
        // Any answer to a question you asked counts too, even "yes" or "nope", so you never have to press Next.
        let youAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        if kind == .reply, let last = turns.last, last.speaker == .prospect,
           youAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?") { lineSuperseded = true }
        if kind == .opener || kind == .voicemail || shownID == 0 || (!holdLine && CoachMachine.canReplace(signals())) {
            show(s, id: id, kind: kind)
        } else {
            if pending?.id != id {
                let why = holdLine ? "held by you" : repSpeaking ? "you're speaking" : "you may be reading"
                ActivityLog.add("Coach #\(id): line queued (\(why))")
                CallTrace.event("suggestion.queued", ["line": s.say, "why": why, "signals": "\(signals())"], sug: id)
            }
            pending = (id, s)
        }
    }

    /// The approved script answer for what they said, shown with no AI wait. True if one matched.
    func instantAnswer(_ said: String) -> Bool {
        guard status == .live else { return false }
        let answers = scriptAnswers
        guard let e = answers.match(said) else {
            CallTrace.event("script.match", ["searched": answers.entries.count, "matched": false, "said": said])
            return false
        }
        CallTrace.event("script.match", ["searched": answers.entries.count, "matched": true, "row": e.id,
                                         "phrases": e.phrases, "said": said, "answer": e.say, "why": "a Sounds-like phrase appears in their words"])
        if suggestion.say == e.say || pending?.suggestion.say == e.say { return true } // already up
        coachTask?.cancel() // any slower AI draft for this is stale now
        thinking = false
        specBasis = nil
        specHeld = nil
        seq += 1
        ActivityLog.add("Coach #\(seq): instant answer from your script (\(e.id)), no AI")
        offer(Suggestion(say: e.say, cue: "From your script: \(e.id)", stage: "Objection", sayComplete: true),
              id: seq, kind: .reply, askedAt: Date())
        return true
    }

    /// Called twice a second: a queued line shows once the rep stops speaking.
    func promotePendingIfReady() {
        guard status == .live, let p = pending, CoachMachine.isFresh(requestID: p.id, latestID: seq),
              !holdLine, CoachMachine.canReplace(signals()) else { return }
        ActivityLog.add("Coach #\(p.id): queued line shown")
        CallTrace.event("suggestion.promoted", ["why": "safe to replace now (rep stopped, line read or delivered)"], sug: p.id)
        show(p.suggestion, id: p.id, kind: .reply)
    }

    /// The Next button: show the queued line now.
    func promoteNow() {
        guard let p = pending else { return }
        ActivityLog.add("Coach: Next clicked, queued line shown")
        CallTrace.event("manual", ["action": "Next"], sug: p.id)
        show(p.suggestion, id: p.id, kind: .reply)
    }

    func show(_ s: Suggestion, id: Int, kind: Kind) {
        if status == .live, !s.say.isEmpty {
            let ms = lastHeardThemAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            ActivityLog.add("Coach line shown (\(kind)\(ms.map { ", \($0) ms after their last words" } ?? "")): \(s.say)")
        }
        var s = s
        s.say = fillTags(s.say, for: calling) // [SDR], {first name} and other slots Claude copied from the script
        if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
        if let old = pending, old.id != id {
            ActivityLog.add("Coach #\(old.id): queued line discarded (newer one shown)")
            CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer line was shown"], sug: old.id)
        }
        if status == .live {
            CallTrace.event("suggestion.shown", ["line": s.say, "cue": s.cue, "stage": s.stage, "kind": "\(kind)",
                                                 "replaced": suggestion.say, "replaced_delivered": lineDelivered], sug: id)
        }
        pending = nil
        lineSuperseded = false
        repSaidSinceShown = ""
        lineDelivered = false
        answeredAfterDelivery = false
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
        if s.stage == "Goal reached", !goalHit {
            goalHit = true
            meetingThisWeek = touchpoints.meetingsThisWeek() + 1 // logged when the call ends
            meetingMoments += 1
            NSSound(named: "Hero")?.play()
        }
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
            var nudge = Suggestion(say: "Still with me?", cue: "6 seconds of silence after your question.",
                                   stage: "", sayComplete: true)
            nudge.nudge = true
            self.show(nudge, id: self.seq, kind: .reply)
            self.repWordsSinceShown = 99 // a nudge, not a script line: never hold the prospect's answer for it
        }
    }

    /// Switches (or refreshes) the campaign. Takes effect right away between calls.
    /// Refreshes the opener after a setting changes (rotation, your name).
    func refreshOpener() {
        if status == .ready { prepareOpener() }
    }
}
