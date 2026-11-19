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
        if let step { journeyStep = step } // follows the call both ways (calls aren't linear)
    }

    /// Shows the line before the one on screen.
    func back() {
        guard !doNotCall else { return } // the goodbye line stays (Fix 2)
        let current = historyIndex ?? history.count - 1
        guard current > 0 else { return }
        historyIndex = current - 1
        suggestion = history[current - 1].s
        kind = history[current - 1].kind
    }

    /// Back to the newest line after looking back.
    func showLatest() {
        guard !doNotCall else { return } // Fix 2
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

    /// Space bar during a live call: a fresh line from the whole call, word for word, on Sonnet, shown at once.
    func freshLine() {
        guard status == .live, !doNotCall, !voicemailActive, !callClosed else { return }
        let latest = uncoached.trimmed.isEmpty ? (turns.last?.text ?? "") : uncoached.trimmed
        CallTrace.event("manual", ["action": "space: fresh line", "was": suggestion.say])
        ActivityLog.add("Space: fresh line from the whole call (Sonnet)")
        holdLine = false
        nextAskModel = "claude-sonnet-5-5"
        freshLineIDs.insert(seq + 1) // the id ask() is about to use
        ask(.reply, user: CoachPrompt.reply(turns: turns, latest: latest, calling: calling, details: recordDetails, style: callOpener,
                                            openTimes: bookingText(), fullContext: true)
            + "\nThe rep pressed for a fresh line. Read the whole call and give the best next line for this exact moment.")
    }

    /// Space bar while this app is in front and a call is live (not while typing in a text box).
    func installSpaceKey() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  self.status == .live, !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            self.freshLine()
            return nil // used: don't also type a space
        }
    }

    /// The rep asked for a different line right now. Skips the wait and the hold.
    func newLine(extra: String = "The rep asked for a different line than the last one.") {
        // ⌘J and the space bar are one feature: the fresh line from the whole call.
        if status == .live, !voicemailActive { freshLine(); return }
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
        screenerRetries = 0 // each screener gets its own retries
        screenerCallID = CallTrace.callID
        // Never over the rep mid-sentence (C6): wait up to 3 s for them to stop.
        if signals().repSpeaking || !(interim[.rep] ?? "").isEmpty {
            screenerWait?.cancel()
            screenerWait = Task { [weak self] in
                for _ in 0..<33 { // up to about 10 s
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, !Task.isCancelled else { return }
                    var sig = self.signals(); sig.queuedIsForNewTopic = true
                    if !sig.repSpeaking && (self.interim[.rep] ?? "").isEmpty && CoachMachine.canReplace(sig) { self.showScreenerLineNow(); return }
                }
                // Still talking after 10 s: they're handling the screener themselves. Don't interrupt.
                CallTrace.event("suggestion.dropped", ["line": "screener", "why": "the rep kept talking"])
            }
            return
        }
        showScreenerLineNow()
    }

    private func showScreenerLineNow() {
        yesShowTask?.cancel()
        guard status == .live, !doNotCall, screenerCallID == CallTrace.callID else { return }
        // Every caller is covered: never over the rep's speech or reading; wait again instead (Fix 6).
        guard CoachController.canInterrupt(signals: signals()), (interim[.rep] ?? "").isEmpty else {
            CallTrace.event("screener.waiting", ["why": "the rep is talking or reading"])
            screenerRetries += 1
            if screenerRetries <= 30 {
                screenerWait?.cancel()
                screenerWait = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, !Task.isCancelled else { return }
                    self.showScreenerLineNow()
                }
            }
            return
        }
        screenerRetries = 0
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
        guard status == .live, !screenerActive, !voicemailActive, !doNotCall else { return } // prepare even while a line is up
        let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
        if pendingAmbiguousOptOut != nil, !(interim[.prospect] ?? "").isEmpty { armPendingOptOutTimer() } // still talking: wait more
        if pendingAmbiguousOptOut != nil || OptOut.hasAmbiguous(text) { return } // never draft on a possible opt-out (Fix 3)
        // "Don't call me back" mid-sentence: stop selling now, don't wait for them to finish.
        if LiveCoach.isOptOut(text, isFinal: false) { handleOptOut(text); return }
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
        // A yes to the rep's question, with the yes line already written: no draft needed.
        if yesBranch != nil, ProspectReply.kind(text) == .yes { return } // ready or still being written
        // One or two word fragments ("No.") almost always grow: drafting on them wastes a request.
        guard let wait = EarlyStart.delayMS(for: text),
              EarlyStart.shouldRedraft(previous: lastEarlyBasis, text: text, draftsThisTurn: earlyDraftsThisTurn) else { return }
        specTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard let self, !Task.isCancelled, !self.doNotCall,
                  EarlyStart.shouldRedraft(previous: self.lastEarlyBasis, text: text, draftsThisTurn: self.earlyDraftsThisTurn),
                  (self.uncoached + " " + (self.interim[.prospect] ?? "")).trimmed == text,
                  normalized(text) != self.specBasis else { return }
            self.ask(.reply, user: CoachPrompt.reply(
                turns: self.turns, latest: text, calling: self.calling, details: self.recordDetails, style: self.callOpener,
                openTimes: self.bookingText(), speculative: true
            ), early: text)
            self.lastEarlyBasis = text
            self.earlyDraftsThisTurn += 1
        }
    }

    /// The prospect stopped talking. Decide if the rep needs a new line.
    func prospectFinished() {
        specTimer?.cancel()
        lastEarlyBasis = nil
        earlyDraftsThisTurn = 0
        if goalPending, !goalHit { // once per full turn, not per chunk (Fix 5)
            goalPendingTurns = GoalPendingRule.turnsLeft(after: goalPendingTurns, confirmed: false)
            if goalPendingTurns <= 0 { goalPending = false }
        }
        var said = uncoached.trimmingCharacters(in: .whitespaces)
        // A possible opt-out is waiting: decide it first, with whatever they said after it (Fix 1c).
        if let pendingSaid = pendingAmbiguousOptOut {
            let outcome = PendingOptOut.resolve(pending: pendingSaid, later: said, utteranceEnded: false, callEnded: false,
                                                secondsWaited: Date().timeIntervalSince(pendingAmbiguousAt))
            if outcome != .wait {
                pendingAmbiguousOptOut = nil
                pendingOptOutTask?.cancel()
                if outcome == .optOut { handleOptOut((pendingSaid + " " + said).trimmingCharacters(in: .whitespaces)); return }
                said = (pendingSaid + " " + said).trimmingCharacters(in: .whitespaces) // a callback request: answer it as one
                CallTrace.event("optout.not", ["said": said, "why": "a later time followed: a callback request"])
            }
        }
        guard !said.isEmpty else { return }
        if doNotCall {
            uncoached = ""
            CallTrace.event("coach.suppressed", ["said": said, "why": "do not call: no more sales lines this call"])
            return
        }
        if status == .live, LiveCoach.isOptOut(said, isFinal: false) { handleOptOut(said); return } // clear phrases
        // Hold only if no later time already follows; "...until Tuesday" is a callback and gets a normal answer.
        if status == .live, OptOut.hasAmbiguous(said), OptOut.matches(said, isFinal: true) {
            // "Don't call me back..." might go on ("...until Tuesday"). No sales line; decide at the full pause.
            pendingAmbiguousOptOut = said
            pendingAmbiguousAt = Date()
            CallTrace.event("optout.waiting", ["said": said, "why": "might be a callback request; waiting for the full pause"])
            uncoached = ""
            armPendingOptOutTimer()
            return
        }
        if phoneTreeActive { uncoached = ""; askPhoneTree(); return } // the menu goes on: re-plan the route
        // Two no's and a go: count their no's; two (or a no plus "yep, thanks") ends it politely, no AI.
        if status == .live, prospectNos > 0 { prospectTurnsAfterFirstNo += 1 }
        if status == .live, !voicemailActive, Rejection.isNo(said) { prospectNos += 1 }
        if status == .live, !voicemailActive, Rejection.callOver(nosSoFar: prospectNos, latest: said), !callClosed {
            callClosed = true
            closedOnSecondNo = prospectNos >= 2
            uncoached = ""
            coachTask?.cancel(); specTimer?.cancel(); pending = nil; yesBranch = nil; yesBranchTask?.cancel()
            let first = Screener.firstName(calling) ?? ""
            seq += 1
            CallTrace.event("call.closing", ["said": said, "nos": prospectNos, "why": "two no's, or a no and a sign-off"])
            show(Suggestion(say: "Totally understand\(first.isEmpty ? "" : ", \(first)"). Thanks for your time. Have a good one.",
                            cue: "Two no's: end it kindly.", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
            return
        }
        if callClosed { uncoached = ""; return } // nothing more to sell on this call
        if voicemailActive { uncoached = ""; return } // no coaching while a greeting plays
        // The rep asked a yes/no question and the line for "yes" is ready: a clear yes shows it now,
        // with no wait. No, unsure, or anything else gets a fresh answer from their real words.
        // Too old: the talk moved on since the question. Drop it and answer fresh.
        if yesBranch != nil, !YesBranchRule.usable(ageSinceQuestion: Date().timeIntervalSince(yesBranchAskedAt)) {
            CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "expired"])
            yesBranch = nil; yesBranchTask?.cancel()
        }
        if let yb = yesBranch, !yb.ready, ProspectReply.kind(said) == .yes {
            yesBranchWanted = said // nearly done: use it when it lands instead of starting over (H3)
            // ...but never dead air: after 1.2 s, give up on it and answer from their words.
            let waitFor = yb.question
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(YesBranchRule.maxWait))
                guard let self, self.yesBranchWanted == said, self.yesBranch?.question == waitFor else { return }
                self.yesBranchWanted = nil
                self.yesBranch = nil
                self.yesBranchTask?.cancel()
                CallTrace.event("yes_branch.discarded", ["question": waitFor, "why": "not ready within \(YesBranchRule.maxWait) s"])
                self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
                                                         details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
            }
            specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
            uncoached = ""
            latestProspect = said
            CallTrace.event("yes_branch.waiting", ["question": yb.question, "answer": said])
            return
        }
        if let yb = yesBranch {
            yesBranch = nil
            yesBranchTask?.cancel()
            let kind = ProspectReply.kind(said)
            if kind == .yes, yb.ready {
                // A short wait so "Yeah. ...No, I'm not interested." can cancel it (call 6).
                specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
                uncoached = ""
                latestProspect = said
                let line = yb.s
                yesShowTask?.cancel()
                yesShowTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall, !self.callClosed,
                          !self.voicemailActive, !self.screenerActive,
                          self.uncoached.trimmingCharacters(in: .whitespaces).isEmpty,
                          (self.interim[.prospect] ?? "").isEmpty else {
                        CallTrace.event("yes_branch.discarded", ["question": yb.question, "why": "they kept talking after the yes"])
                        return
                    }
                    CallTrace.event("yes_branch.used", ["question": yb.question, "answer": said, "line": line.say])
                    ActivityLog.add("Coach: they said yes, ready line shown")
                    self.markRequestStart()
                    self.seq += 1
                    self.offer(line, id: self.seq, kind: .reply, askedAt: Date())
                }
                return
            }
            CallTrace.event("yes_branch.discarded", ["question": yb.question, "answer": said, "answer_kind": kind.rawValue,
                                                     "ready": yb.ready, "why": kind == .yes ? "not ready yet" : "their answer wasn't a clear yes"])
        }

        // Started early on exactly these words? Then the answer is already on its way.
        if let basis = specBasis {
            specBasis = nil
            if basis != normalized(said) {
                // Thrown out: stop it now, so it can't show later on any early return below (C5).
                coachTask?.cancel(); specHeld = nil; thinking = false
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
                // Not on the mutual "Hello?": wait for 0.8 s of quiet, so the rep isn't reading over the greeting.
                openerWaitTask?.cancel()
                openerWaitTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall,
                          (self.interim[.prospect] ?? "").isEmpty, self.uncoached.isEmpty else { return }
                    self.seq += 1
                    self.show(opener, id: self.seq, kind: .opener)
                }
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
        guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else {
            CallTrace.event("coach.skipped", ["said": said, "why": onlyGreeting ? "a plain greeting; the opener already answers it" : "not meaningful (filler)"])
            return
        }
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
        let total = turns.count
        guard CallMemoryRules.summaryDue(totalTurns: total, summaryCovers: CoachPrompt.summaryCoversTurns, inFlight: summaryInFlight),
              let key = Keychain.read(.anthropic) else { return }
        let theirs = turns.filter { $0.speaker == .prospect }.count
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        let callID = CallTrace.callID // the summary belongs to this call only
        summaryInFlight = true
        Task {
            defer { if CallTrace.callID == callID { self.summaryInFlight = false } }
            var c = LiveCoach.client(key)
            c.maxTokens = 250
            var text = ""
            try? await c.stream(system: "Summarize a live sales call for a coach in 3 to 6 short bullets: who they are, their situation, any numbers, pains, objections raised, what was agreed. Only what was said. No preamble.",
                                user: transcript) { text = $0 }
            guard CallMemoryRules.acceptSummary(currentCallID: CallTrace.callID, summaryCallID: callID,
                                                summaryCovers: total, storedCovers: CoachPrompt.summaryCoversTurns) else {
                CallTrace.event("memory.rejected", ["why": "older than the stored summary, or from another call", "covers_turns": total])
                return
            }
            if !text.isEmpty {
                CoachPrompt.liveSummary = text
                CoachPrompt.summaryCoversTurns = total
                CallTrace.memVersion += 1
                CallTrace.event("memory.update", ["summary": text, "covers_turns": total, "prospect_turns": theirs, "evidence_chars": transcript.count])
            }
        }
    }

    /// "Take me off your list": the goodbye line, DoNotCall written in Salesforce, off every list, hang up. No AI.
    func handleOptOut(_ said: String) {
        guard !doNotCall else { return }
        yesShowTask?.cancel()
        let optOutCallID = CallTrace.callID
        doNotCall = true // terminal: every later draft, early start and queued line is blocked
        specTimer?.cancel()
        coachTask?.cancel()
        yesBranchTask?.cancel(); yesBranch = nil
        stillWithMeTask?.cancel()
        phoneTreeTask?.cancel()
        openerTask?.cancel()
        if let p = pending {
            CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "do not call"], sug: p.id)
        }
        pending = nil
        specHeld = nil
        specBasis = nil
        uncoached = ""
        thinking = false
        CallTrace.event("state", ["from": coachState.rawValue, "to": CoachState.doNotCall.rawValue,
                                  "why": "opt-out phrase", "said": said, "cancelled_request": seq])
        coachState = .doNotCall
        seq += 1
        show(Suggestion(say: LiveCoach.optOutLine, cue: "Opt out. Say goodbye, then hang up. Saving Do Not Call in Salesforce...", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
        guard let key = currentAttemptKey else { return }
        RemovedList.add(key)
        followUp = nil // no text, no LinkedIn
        CallTrace.event("crm.suppress", ["record": key, "actions": ["DoNotCall", "status", "off every list", "no text"]])
        outcomeSaved.insert(String(key.prefix(15))) // nothing more to log
        ActivityLog.add("Opt out from \(calling ?? key): \"\(said)\". Off every list, no text, writing DoNotCall and status")
        CallTrace.event("intent", ["intent": "opt_out", "said": said, "why": "opt-out phrase in their words", "action": "goodbye line and DoNotCall; the rep hangs up"])
        Task { [weak self] in
            do {
                try await Salesforce.setDoNotCall(key)
                ActivityLog.add("Opt out: DoNotCall saved in Salesforce for \(self?.calling ?? key)")
                CallTrace.event("crm.saved", ["record": key, "field": "DoNotCall"])
                // Only now say it's saved in Salesforce (the line itself stays as is).
                if let self, self.suggestion.say == LiveCoach.optOutLine { self.suggestion.cue = "Opt out. Do Not Call saved in Salesforce. Hang up when you're done." }
            } catch {
                ActivityLog.problem("Opt out: couldn't save DoNotCall in Salesforce: \(error.localizedDescription)")
                CallTrace.event("crm.failed", ["record": key, "field": "DoNotCall", "error": error.localizedDescription])
                if let self, CallTrace.callID == optOutCallID { // never on the next call's screen
                    if self.suggestion.say == LiveCoach.optOutLine {
                        self.suggestion.cue = "Off your list here, but Salesforce didn't save Do Not Call. Mark it by hand."
                    }
                    self.problem = "Do Not Call didn't save in Salesforce for \(self.calling ?? key). Mark it by hand."
                }
            }
            // Status too: Leads go Unqualified, Contacts go Negative. Both keep them off every list.
            let status = key.hasPrefix("00Q") ? "Unqualified" : "Negative"
            do {
                try await Salesforce.setStatus(of: key, to: status, note: "Asked not to be called again: \"\(said.prefix(200))\"")
                ActivityLog.add("Opt out: status set to \(status)")
            } catch {
                ActivityLog.problem("Opt out: couldn't set status to \(status): \(error.localizedDescription)")
            }
            // No automatic hang-up: the rep says goodbye and hangs up themselves.
        }
    }

    func prepareOpener() {
        // A ready-to-read line right away (from the opener template), so there's always a script
        // on screen before the phone rings. Claude's personal version replaces it when it's ready.
        seq += 1
        instantOpenerID = seq
        show(instantOpener(for: calling), id: seq, kind: .opener)
        // Claude's personal opener costs tokens: only for someone we'll really call, once they've been
        // on screen 1.5 s (a skipped person is gone by then), and one request even when several things
        // (page open, details loaded) ask for it at once.
        openerTask?.cancel()
        let key = recordKey()
        if let key, MobileOnly.excluded(key) || RemovedList.contains(key) { return }
        openerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, self.recordKey() == key,
                  self.status == .ready || (self.status == .live && self.turns.isEmpty) else { return }
            if let key, MobileOnly.excluded(key) || RemovedList.contains(key) { return }
            self.ask(.opener, user: CoachPrompt.opener(calling: self.calling, details: self.recordDetails, style: self.openerStyle,
                                                       scriptOpener: self.openerStyle == nil ? self.scriptOpenerLine() : nil))
        }
    }

    func ask(_ kind: Kind, user: String, early: String? = nil) {
        guard let key = Keychain.read(.anthropic) else {
            problem = "Add your Anthropic key: gear > Setup > AI keys."
            return
        }
        if doNotCall, kind == .reply {
            CallTrace.event("claude.blocked", ["why": "do not call", "early": early != nil])
            return
        }
        coachTask?.cancel() // a newer statement makes the old answer stale
        if kind == .reply { repWordsAtLastAsk = repWordsInCall; repTextSinceAsk = "" }
        let repLed = nextIsRepLed
        nextIsRepLed = false
        seq += 1
        let id = seq
        if repLed { repLedIDs.insert(id) }
        let askedAt = Date()
        logSystemIfChanged()
        CallTrace.event("memory.snapshot", ["summary": CoachPrompt.liveSummary, "summary_version": CallTrace.memVersion,
                                            "question_facts": CoachPrompt.questionFacts, "objection_facts": CoachPrompt.objectionFacts, "blocker_hints": CoachPrompt.blockerHints,
                                            "turns": turns.count], req: id)
        let override = kind == .reply ? nextAskModel : nil // a space-bar fresh line uses Sonnet
        nextAskModel = nil
        let requested = (kind == .reply ? LiveCoach.client(key, model: override) : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)).model
        if kind == .reply { ActivityLog.add("Coach #\(id): asking \(ClaudeClient.displayName(requested))\(early == nil ? "" : " early, from their words so far")") }
        else { ActivityLog.add("Coach #\(id): \(kind) from \(ClaudeClient.displayName(requested))") }
        CallTrace.event("claude.request", [
            "kind": "\(kind)", "early": early != nil, "early_basis": early ?? "",
            "system_chars": self.system.count, "system_hash": Self.stableHash(self.system),
            "user_message": user, "summary_version": CallTrace.memVersion,
            "context": kind == .reply ? CoachPrompt.lastContext : [:], "user_chars": user.count,
        ], req: id)
        specBasis = early.map(normalized)
        specHeld = nil
        confirmedAt = nil
        // Live lines: Haiku, short and fast. Voicemails also Haiku, so the message is ready before the beep.
        let client = kind == .reply ? LiveCoach.client(key, model: override)
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
                try await client.stream(system: system, user: user, onText: { text in
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
                        guard (s.sayComplete && !s.stage.isEmpty) || s.skip, !gate.checked else { if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }; return }
                        gate.checked = true
                        let problems = s.skip ? [] : Self.lineProblems(s)
                        gate.passed = problems.isEmpty
                        CallTrace.event("check.result", ["stage": "stream", "line": s.say, "skip": s.skip,
                                                         "passed": gate.passed, "problems": problems], req: id)
                        if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
                    }
                }, onUsage: { u in
                    // Token counts and cache use: cache_read > 0 means the system prompt came from cache.
                    Task { @MainActor in CallTrace.event("claude.usage", u.merging(["ms": Int(Date().timeIntervalSince(started) * 1000)]) { a, _ in a }, req: id) }
                }, onModel: { served in
                    guard served != requested, !served.hasPrefix(requested) else { return }
                    Task { @MainActor in
                        ActivityLog.add("Coach #\(id): model switched: asked \(ClaudeClient.displayName(requested)), answered by \(ClaudeClient.displayName(served)) (fallback)")
                        CallTrace.event("claude.model_switch", ["requested": requested, "served": served], req: id)
                    }
                })
                if kind == .reply { ActivityLog.add("Coach #\(id): Claude done after \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
                CallTrace.event("claude.done", ["ms": Int(Date().timeIntervalSince(started) * 1000), "output": finalText,
                                                "fresh": self?.seq == id], req: id)
                var last = Suggestion.parse(finalText)
                last.sayComplete = true
                if kind == .reply, !last.skip, !last.say.isEmpty {
                    let problems = Self.lineProblems(last)
                    CallTrace.event("check.result", ["stage": "final", "line": last.say, "passed": problems.isEmpty,
                                                     "problems": problems], req: id)
                    if !problems.isEmpty { last = await self?.fixLine(last, system: system, user: user, key: key, id: id) ?? last }
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
        let p = Guardrail.problems(s.say, endsCall: ["Exit", "Goal reached", "Voicemail"].contains(s.stage) || s.rowTag != nil, allowTimes: true)
        // A script row copied word for word ("S2 open" is 26 words) isn't sent back for being long.
        return s.rowTag == nil ? p : p.filter { !$0.contains("words (max") }
    }

    /// A line broke the rules: Haiku tries again with the reasons, then Sonnet, then the smallest safe fix.
    func fixLine(_ bad: Suggestion, system: String, user: String, key: String, id: Int = 0) async -> Suggestion {
        var problems = Self.lineProblems(bad)
        ActivityLog.add("Line check: failed (\(problems.joined(separator: "; "))): \(bad.say)")
        CallTrace.event("check.fail", ["line": bad.say, "problems": problems], req: id)
        // Formatting only (an abbreviation like CRM, an em dash): fix it in code, no second request.
        if problems.allSatisfy({ $0.hasPrefix("abbreviation") || $0 == "em dash" || $0 == "more than one question" }),
           let fixed = LineRepair.fix(bad.say) {
            var s = bad
            s.say = fixed
            // Spelled-out words add syllables: allow half a grade of slack on a repaired line (M6).
            let left = Self.lineProblems(s).filter { !($0.hasPrefix("reading level") && ReadingLevel.grade(fixed) <= ReadingLevel.checkMax + 0.5) }
            if left.isEmpty {
                ActivityLog.add("Line check: fixed in code (no extra request)")
                CallTrace.event("check.fixed_locally", ["from": bad.say, "line": fixed], req: id)
                return s
            }
        }
        for model in [LiveCoach.callModel] { // one retry at most, on this call's model (H4)
            var text = ""
            let retry = user + "\n\nYour last SAY broke these rules: \(problems.joined(separator: "; ")). It was: \"\(bad.say)\". Write it again."
            CallTrace.event("claude.retry.request", ["model": model, "user_message": retry], req: id)
            let t0 = Date()
            ActivityLog.add("Line check: asking \(ClaudeClient.displayName(model)) to fix it")
            try? await LiveCoach.client(key, model: model).stream(system: system, user: retry) { text = $0 }
            var s = Suggestion.parse(text)
            s.sayComplete = true
            let left = s.skip ? [] : Self.lineProblems(s)
            CallTrace.event("claude.retry.done", ["model": model, "ms": Int(Date().timeIntervalSince(t0) * 1000), "output": text,
                                                  "passed": !s.say.isEmpty && left.isEmpty, "problems": left], req: id)
            if s.skip || (!s.say.isEmpty && Self.lineProblems(s).isEmpty) {
                ActivityLog.add("Line check: fixed by \(model.contains("haiku") ? "Haiku" : "Sonnet")")
                CallTrace.event("check.fixed", ["model": model, "line": s.say], req: id)
                return s
            }
            if !s.say.isEmpty { problems = Self.lineProblems(s) }
        }
        var s = bad
        s.say = LiveCoach.sanitize(bad.say)
        ActivityLog.add("Line check: trimmed to fit: \(s.say)")
        CallTrace.event("check.trimmed", ["line": s.say, "from": bad.say], req: id)
        return s
    }

    /// Shows a suggestion, but never swaps a fresh line out from under the rep.
    func offer(_ s: Suggestion, id: Int, kind: Kind, askedAt: Date) {
        guard id == seq, !s.skip, !s.say.isEmpty, !doNotCall else { // do not call: nothing replaces the goodbye
            // MOVE: silent: keep the line if it still fits; clear it if the talk moved past it.
            let movedOn: Bool = {
                guard let last = turns.last, last.speaker == .prospect else { return lineSuperseded }
                let repAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
                return lineSuperseded || repAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?")
            }()
            if s.move == "silent", id == seq, !doNotCall, status == .live, !suggestion.say.isEmpty,
               SilentRule.clearNow(superseded: movedOn, delivered: lineDelivered, answered: answeredAfterDelivery, signals: signals()) {
                CallTrace.event("suggestion.cleared", ["line": suggestion.say, "why": "Claude chose silent and the line was outdated"], sug: shownID)
                suggestion = Suggestion()
                lineSuperseded = false
            }
            if s.sayComplete || s.skip {
                let why = doNotCall ? "do not call" : id != seq ? "stale: request #\(seq) is newer" : s.move == "silent" ? "Claude chose silent: no new line needed" : s.skip ? "Claude said skip" : "empty"
                CallTrace.event("suggestion.dropped", ["line": s.say, "why": why], sug: id)
            }
            return
        }
        // Easier to read live: show the line once it's whole, not word by word (setting).
        let wholeLine = Prefs.wholeLine
        if wholeLine && !s.sayComplete { return }
        if specBasis != nil {
            if s.sayComplete, specHeld?.id != id {
                CallTrace.event("suggestion.held_early", ["line": s.say, "basis": specBasis ?? "", "why": "drafted early: waits for them to stop"], sug: id)
            }
            specHeld = (s, id) // started early: wait until they really stop talking
            return
        }
        if kind == .reply, timedID != id {
            timedID = id // time from "they stopped talking" to the first words of the answer
            latency = max(0, Date().timeIntervalSince(confirmedAt ?? askedAt))
        }
        if id == shownID {
            // Once a line is whole on screen, its words are frozen: a late chunk never changes it (N2).
            if suggestion.sayComplete { return }
            if frozenShownID == id { return }
            if status == .live, signals().repSpeaking || !(interim[.rep] ?? "").isEmpty { frozenShownID = id; return } // reading it: freeze for good
            if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
            var s = s
            s.say = fillTags(s.say, for: calling) // never show a bare [Name] or [SDR]
            suggestion = s // same answer, still streaming in
            note(s)
            return
        }
        // The call is live and someone already talked: keep the opener the rep is reading.
        if kind == .opener, status == .live, repWordsInCall > 0 || turns.contains(where: { $0.speaker == .prospect })
            || signals().repSpeaking || !(interim[.rep] ?? "").isEmpty {
            if s.sayComplete { CallTrace.event("suggestion.dropped", ["line": s.say, "why": "opener arrived after the talk started"], sug: id) }
            return
        }
        // The AI thinks ahead, the screen follows the conversation: never swap the line while the rep is
        // speaking. Queue it, flag the old one as outdated, and show it the moment they stop.
        // A new prospect turn since the line appeared = the conversation moved on.
        // Only a real reply moves the conversation on (3+ words or a question), not "uh-huh" or "yeah".
        // Any answer to a question you asked counts too, even "yes" or "nope", so you never have to press Next.
        let youAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        if kind == .reply, repLedIDs.contains(id), !lineSuperseded || supersededLogged != shownID {
            supersededLogged = shownID
            CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id,
                                                      "why": "the rep moved on in their own words", "delivered": lineDelivered], sug: shownID)
            lineSuperseded = true
        }
        if kind == .reply, let last = turns.last, last.speaker == .prospect,
           youAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?") {
            if !lineSuperseded || supersededLogged != shownID {
                supersededLogged = shownID
                let why = youAsked ? "they answered your question" : last.text.contains("?") ? "they asked a question" : "they said something new (3+ words)"
                CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id, "prospect_said": last.text,
                                                          "why": why, "delivered": lineDelivered], sug: shownID)
                ActivityLog.add("Coach #\(shownID): line outdated (\(why))")
            }
            lineSuperseded = true
        }
        // The rep moved past it while it was being written (asked, pivoted, or kept talking): drop it (round 2 #1).
        let readingOnScript = !lineDelivered && Delivery.onLine(line: suggestion.say, spoken: recentRepChunks.joined(separator: " "))
        let staleWhy = kind == .reply && id != shownID
            ? QueuedLine.staleReason(ageSeconds: 0, repWordsSinceQueued: readingOnScript ? 0 : repWordsInCall - repWordsAtLastAsk,
                                     repAskedSinceQueued: QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
                                                                                          lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate),
                                     repTextSinceQueued: repTextSinceAsk)
            : nil
        if freshLineIDs.contains(id) { // the rep pressed space: show it now, whatever is on screen
            defer { freshLineIDs.remove(id) } // still marked while show() counts it
            CallTrace.event("suggestion.fresh", ["line": s.say, "why": "the rep asked for a fresh line"], sug: id)
            show(s, id: id, kind: kind)
            return
        }
        let decision = CoachController.offer(isOpenerOrVoicemail: kind == .opener || kind == .voicemail, firstLine: shownID == 0,
                                             holdLine: holdLine, signals: signals(), staleReason: staleWhy)
        if case .drop(let why) = decision {
            CallTrace.event("suggestion.discarded", ["line": s.say, "why": "stale on arrival: \(why)", "rule": QueuedLine.ruleKind(why)], sug: id)
            // Only when they talked on in their own words: after a question or a pivot, the prospect's answer comes next.
            if why.hasPrefix("the rep said") { followRep(why: "the line arrived after the rep moved on") }
            return
        }
        if decision == .show {
            show(s, id: id, kind: kind)
        } else {
            if pending?.id != id {
                let why = holdLine ? "held by you" : repSpeaking ? "you're speaking" : "you may be reading"
                ActivityLog.add("Coach #\(id): line queued (\(why))")
                CallTrace.event("suggestion.queued", ["line": s.say, "why": why, "signals": signals().trace], sug: id)
            }
            if let old = pending, old.id != id {
                CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer queued line replaced it"], sug: old.id)
            }
            if pending?.id != id {
                pendingQueuedAt = Date()
                repWordsAtQueue = repWordsAtLastAsk // what the rep had said when this line was asked for
                // C4: a question the rep asked while this line was still being written counts too.
                repAskedSinceQueue = QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
                                                                     lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate)
            }
            pending = (id, s)
        }
    }

    /// Same text, same hash, on every run (Swift's hashValue changes each launch).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The full system prompt goes in the trace at call start and again whenever it changes.
    func logSystemIfChanged() {
        let h = Self.stableHash(system)
        guard h != loggedSystemHash else { return }
        loggedSystemHash = h
        CallTrace.event("context.system", ["text": system, "hash": h])
    }

    /// The approved script answer for what they said, shown with no AI wait. True if one matched.
    func instantAnswer(_ said: String) -> Bool {
        guard status == .live, !doNotCall else { return false }
        let answers = scriptAnswers
        // Only when they're answering the rep's question: otherwise a phrase match is out of context.
        let repJustAsked = turns.dropLast().last { $0.speaker == .rep }?.text.contains("?") ?? false
        guard repJustAsked, let e = answers.match(said) else {
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
        markRequestStart()
        seq += 1
        ActivityLog.add("Coach #\(seq): instant answer from your script (\(e.id)), no AI")
        offer(Suggestion(say: e.say, cue: "From your script: \(e.id)", stage: "Objection", sayComplete: true),
              id: seq, kind: .reply, askedAt: Date())
        return true
    }

    /// Called twice a second: a queued line shows once the rep stops speaking.
    func promotePendingIfReady() {
        guard status == .live, let p = pending, CoachMachine.isFresh(requestID: p.id, latestID: seq) else { return }
        let decision = CoachController.promote(holdLine: holdLine, signals: signals(),
                                               ageSeconds: Date().timeIntervalSince(pendingQueuedAt),
                                               repWordsSinceQueued: repWordsInCall - repWordsAtQueue,
                                               repAskedSinceQueued: repAskedSinceQueue, repTextSinceQueued: repTextSinceAsk)
        guard decision != .wait else {
            if blockedLoggedID != p.id { // once per queued line, not every tick
                blockedLoggedID = p.id
                CallTrace.event("promotion.blocked", ["why": holdLine ? "held by the rep" : "not safe to replace yet",
                                                      "signals": signals().trace], sug: p.id)
            }
            return
        }
        // The rep's words are the source of truth: if they moved on while this waited, it's stale.
        if case .drop(let why) = decision {
            pending = nil
            ActivityLog.add("Coach #\(p.id): queued line dropped (\(why); \(QueuedLine.ruleKind(why)) rule)")
            CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)",
                                                     "rule": QueuedLine.ruleKind(why)], sug: p.id)
            // They asked their own question: the next move is the prospect's answer. Otherwise write the
            // next line from where the rep actually is.
            if !repAskedSinceQueue { followRep() }
            return
        }
        ActivityLog.add("Coach #\(p.id): queued line shown")
        CallTrace.event("suggestion.promoted", ["why": "safe to replace now (rep stopped, line read or delivered)"], sug: p.id)
        show(p.suggestion, id: p.id, kind: .reply)
    }

    /// The rep went off script and paused without asking anything: the next line builds on what they
    /// actually said, not on what the script expected.
    func followRep(why: String = "the rep moved on from the queued line") {
        guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
              let rep = turns.last, rep.speaker == .rep else { return }
        CallTrace.event("follow_rep", ["rep_said": rep.text, "why": why])
        followsThisStretch += 1
        nextIsRepLed = true
        ask(.reply, user: CoachPrompt.reply(turns: turns, latest: rep.text, calling: calling, details: recordDetails,
                                            style: callOpener, openTimes: bookingText(), repLed: true))
    }

    /// After each thing the rep says: if they're off script, get the next line ready now, while they
    /// talk, so it's waiting when they pause. A queued line they've moved past is dropped first.
    func prepareWhileRepTalks(_ text: String) {
        guard status == .live, !doNotCall, !voicemailActive, !screenerActive, !suggestion.say.isEmpty else { return }
        let since = repWordsInCall - repWordsAtLastAsk
        guard !followPausedUntilQuiet,
              FollowRepLimit.allowed(repWordsSinceLastAsk: since, followsThisStretch: followsThisStretch) else { return }
        guard FollowRep.shouldPrepare(repJustSaid: text, recentRepSpeech: recentRepChunks.joined(separator: " "),
                                      shownLine: suggestion.say, shownLineDelivered: lineDelivered,
                                      repWordsSinceLastAsk: since) else { return }
        if let p = pending {
            pending = nil
            let why = "the rep said \(since) words of their own since"
            ActivityLog.add("Coach #\(p.id): queued line dropped while you talk (\(why); heuristic rule)")
            followPausedUntilQuiet = true // they're on their own roll: no more drafts until they pause
            CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)", "rule": "heuristic"], sug: p.id)
        }
        followRep(why: "preparing ahead: the rep is off script (\(since) words since the last request)")
    }

    /// The rep just asked a yes/no question: write the line for "yes" now, while they wait for the
    /// answer. It's held, never shown, until the prospect actually says yes. Open questions ("What do
    /// you use?") get nothing ahead: the answer comes from their real words.
    func prepareYesBranch(_ text: String) {
        // Keep the ready line through small talk; drop it for a new question or once the talk moved on (H3).
        if yesBranch != nil {
            yesBranchRepWords += text.split(separator: " ").count
            if YesBranchRule.keep(afterRepSaid: text, wordsSinceQuestion: yesBranchRepWords) { return }
            CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "the rep moved on or asked a new question"])
        }
        yesBranchTask?.cancel()
        yesBranch = nil
        yesBranchWanted = nil
        guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
              let q = RepQuestion.closedQuestion(in: text), let key = Keychain.read(.anthropic) else { return }
        yesBranchRepWords = 0
        yesBranchAskedAt = Date()
        let user = CoachPrompt.reply(turns: turns, latest: q, calling: calling, details: recordDetails, style: callOpener,
                                     openTimes: bookingText(), assumeYes: true)
        let system = self.system
        yesBranch = (q, Suggestion(say: "", cue: "", stage: ""), false)
        CallTrace.event("yes_branch.request", ["question": q, "user_message": user])
        let started = Date()
        yesBranchTask = Task { [weak self] in
            var text = ""
            try? await LiveCoach.client(key).stream(system: system, user: user, onText: { text = $0 }, onUsage: { u in
                Task { @MainActor in CallTrace.event("claude.usage", u.merging(["yes_branch": 1]) { a, _ in a }) }
            })
            guard let self, !Task.isCancelled, self.yesBranch?.question == q else { return }
            CallTrace.event("claude.done", ["yes_branch": true, "ms": Int(Date().timeIntervalSince(started) * 1000), "output": text])
            var s = Suggestion.parse(text)
            s.sayComplete = true
            let problems = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
            if !problems.isEmpty, let fixed = LineRepair.fix(s.say) { s.say = fixed }
            let left = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
            CallTrace.event("yes_branch.ready", ["question": q, "line": s.say, "ms": Int(Date().timeIntervalSince(started) * 1000),
                                                 "passed": left.isEmpty, "problems": left])
            if left.isEmpty { self.yesBranch = (q, s, true) } else { self.yesBranch = nil }
            // They already said yes while this was being written: show it now, or fall back to a normal answer.
            if let said = self.yesBranchWanted {
                self.yesBranchWanted = nil
                self.yesBranch = nil
                if left.isEmpty, self.status == .live, !self.doNotCall {
                    CallTrace.event("yes_branch.used", ["question": q, "answer": said, "line": s.say, "late": true])
                    self.markRequestStart()
                    self.seq += 1
                    self.offer(s, id: self.seq, kind: .reply, askedAt: Date())
                } else {
                    self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
                                                             details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
                }
            }
        }
    }

    /// The possible opt-out's timer: (re)started on the phrase and on any new prospect words. When it runs out with
    /// no later time said, it's an opt-out.
    func armPendingOptOutTimer() {
        pendingOptOutTask?.cancel()
        pendingAmbiguousAt = Date()
        pendingOptOutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PendingOptOut.timeout))
            guard let self, !Task.isCancelled, let p = self.pendingAmbiguousOptOut else { return }
            let later = self.uncoached.trimmingCharacters(in: .whitespaces)
            switch PendingOptOut.resolve(pending: p, later: later, utteranceEnded: false, callEnded: false,
                                         secondsWaited: PendingOptOut.timeout) {
            case .optOut:
                self.pendingAmbiguousOptOut = nil
                CallTrace.event("optout.timeout", ["said": p, "why": "no later time within \(PendingOptOut.timeout) s"])
                self.handleOptOut((p + " " + later).trimmingCharacters(in: .whitespaces))
            case .callback:
                self.pendingAmbiguousOptOut = nil
                CallTrace.event("optout.not", ["said": p + " " + later, "why": "a later time followed: a callback request"])
            case .wait: break
            }
        }
    }

    /// A yes line or script answer is a new request too: what the rep said before it doesn't make it stale.
    func markRequestStart() {
        repWordsAtLastAsk = repWordsInCall
        repTextSinceAsk = ""
    }

    /// The Next button: show the queued line now.
    func promoteNow() {
        guard !doNotCall, let p = pending else { return } // Fix 2
        ActivityLog.add("Coach: Next clicked, queued line shown")
        CallTrace.event("manual", ["action": "Next"], sug: p.id)
        show(p.suggestion, id: p.id, kind: .reply)
    }

    func show(_ s: Suggestion, id: Int, kind: Kind) {
        // After an opt-out, only the goodbye line may ever show (round 2 #3).
        if doNotCall, s.say != LiveCoach.optOutLine {
            CallTrace.event("suggestion.dropped", ["line": s.say, "why": "do not call", "kind": "\(kind)"], sug: id)
            return
        }
        if status == .live, !s.say.isEmpty {
            let ms = lastHeardThemAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            ActivityLog.add("Coach line shown (\(kind)\(ms.map { ", \($0) ms after their last words" } ?? "")): \(s.say)")
        }
        var s = s
        s.say = fillTags(s.say, for: calling) // [SDR], {first name} and other slots Claude copied from the script
        // Still an unfilled slot ([Day], [Firm] we don't know): never show it. Keep the current line (script rule).
        if status == .live, kind == .reply, TokenFill.hasOpenSlot(s.say) {
            CallTrace.event("suggestion.dropped", ["line": s.say, "why": "a [slot] couldn't be filled"], sug: id)
            ActivityLog.add("Coach: a line had a blank to fill (\(s.say)); kept the current line")
            showToast("No line with a blank in it. Say it your way, or press space for a fresh one.")
            return
        }
        if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
        if let old = pending, old.id != id {
            ActivityLog.add("Coach #\(old.id): queued line discarded (newer one shown)")
            CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer line was shown"], sug: old.id)
        }
        if status == .live, kind == .reply || kind == .opener, !s.say.isEmpty {
            CoachPrompt.shownLines.append(s.say)
            // Model test: only lines the call's model wrote (not the instant opener, script answers or a space-bar
            // Sonnet line), and a line replaced before it could be read doesn't count as ignored.
            if testLineCounted, !lineDelivered, Date().timeIntervalSince(shownAt) < 2 { callLinesShown -= 1 }
            testLineCounted = kind == .reply && !s.nudge && s.say != LiveCoach.optOutLine && !freshLineIDs.contains(id)
                && !s.cue.hasPrefix("From your script") && !s.cue.hasPrefix("Two no")
            if testLineCounted { callLinesShown += 1 }
        }
        if status == .live {
            CallTrace.event("suggestion.shown", ["line": s.say, "cue": s.cue, "stage": s.stage, "move": s.move, "label": LineLook.label(move: s.move, exact: s.rowTag != nil), "key_part": LineLook.emphasis(s.say)?.key ?? "", "kind": "\(kind)",
                                                 "replaced": suggestion.say, "replaced_delivered": lineDelivered], sug: id)
        }
        pending = nil
        lineSuperseded = false
        if kind == .reply { repTextSinceAsk = ""; repWordsAtLastAsk = repWordsInCall } // round 2 #9
        priorLineOfferedTime = !suggestion.offered.isEmpty || GoalEvidence.mentionsTime(suggestion.say)
        // The old line: partly said in the rep's own words? Then it isn't "never said" (H1).
        if status == .live, !suggestion.say.isEmpty, !lineDelivered,
           Delivery.likelyCovered(line: suggestion.say, spoken: repSaidSinceShown),
           !CoachPrompt.likelyCoveredLines.contains(suggestion.say) {
            CoachPrompt.likelyCoveredLines.append(suggestion.say)
            CallTrace.event("delivery.likely", ["line": suggestion.say, "said": repSaidSinceShown,
                                                "confidence": Delivery.confidence(line: suggestion.say, spoken: repSaidSinceShown)], sug: shownID)
        }
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
        // A closing line on screen is only a pending goal; the prospect's words confirm it (N4).
        if s.stage == "Goal reached", !goalHit {
            goalPending = true
            goalPendingTurns = 2
            // They often agree first ("Tuesday works") and the closing line follows: check their last words too.
            if let last = turns.last(where: { $0.speaker == .prospect }) { confirmGoalIfAgreed(last.text, checkingEarlierTurn: true) }
        }
        if s.stage == "Voicemail" { sawVoicemail = true }
    }

    func scheduleStillWithMe() {
        stillWithMeTask?.cancel()
        guard let last = turns.last, last.speaker == .rep,
              RepQuestion.asQuestion(last.text).hasSuffix("?") || !QuestionTracker.questions(in: last.text).isEmpty,
              turns.contains(where: { $0.speaker == .prospect }),
              !voicemailActive, !screenerActive, !phoneTreeActive, !badNumberThisCall else { return }
        let askedAt = lastWordsAt
        stillWithMeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall, !self.thinking, self.pending == nil,
                  self.lineDelivered, // only after a line was said, then real silence (never over the rep's own thought)
                  self.lastWordsAt == askedAt,
                  self.turns.last?.speaker == .rep, !self.voicemailActive,
                  (self.interim[.prospect] ?? "").isEmpty, // they're mid-answer
                  !self.signals().repSpeaking, (self.interim[.rep] ?? "").isEmpty,
                  CoachMachine.canReplace({ var x = self.signals(); x.queuedIsForNewTopic = true; return x }()) else { return } // never over the rep (C6)
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
