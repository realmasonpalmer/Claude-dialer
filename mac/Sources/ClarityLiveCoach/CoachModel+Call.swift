import AppKit
import CoachCore
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// A call from start to end: the tick, starting and ending calls, auto redial and auto next.
extension CoachModel {
    /// Whoever is up has a phone number outside the US and Canada: skip them, whatever loaded them.
    /// Checked every half second, so no path (first lead, Back, reload, auto next) can miss it.
    private func skipForeignLead() {
        MobileOnly.campaignID = campaign.id
        callList.pin(object: campaign.listObject, view: campaign.listViewID) // only the menu's list
        if leads.isActive, let d = leads.details { MobileOnly.record(d.id, mobile: d.mobile) }
        // Mobile numbers only: no Mobile on file, skip them for this call list.
        if MobileOnly.on, status == .ready, !dialing, let key = recordKey(), MobileOnly.excluded(key), mobileSkippedID != key {
            mobileSkippedID = key
            ActivityLog.add("\(calling ?? key) has no Mobile (Mobile numbers only is on): skipping")
            problem = "No Mobile number. Skipped (Mobile numbers only)."
            skipNext(why: "no Mobile number (Mobile numbers only is on)")
            return
        }
        // The Chrome list: someone off the list (non-US number, removed) is on screen: move on.
        if !leads.isActive, status == .ready, !dialing, let key = recordKey(), RemovedList.contains(key),
           foreignSkippedID != key {
            foreignSkippedID = key
            ActivityLog.add("\(calling ?? key) is off the list (non-US number or removed): skipping")
            problem = "Off your list. Skipped, on to the next person."
            skipNext(why: "off the list")
            return
        }
        guard status == .ready, !dialing, leads.isActive, let d = leads.details, !d.doNotCall,
              let n = d.foreignNumber, foreignSkippedID != d.id else { return }
        foreignSkippedID = d.id // once per person, so Back can still show them
        ActivityLog.add("\(d.name) isn't a US or Canada number (\(n)): skipping and removing from the list")
        RemovedList.add(d.id)
        problem = "Not a US or Canada number. Skipped, on to the next person."
        skipNext(why: "not a US or Canada number")
    }

    func tick() {
        guard active else { return }
        if !attemptsReconciled {
            attemptsReconciled = true
            for a in CallAttemptStore.shared.orphans() {
                ActivityLog.add("Call record recovered after the app quit: \(a.outcome?.rawValue ?? "?") (\(a.classificationSource))")
                applyOutcome(a, live: false)
            }
        }
        checkBlock()
        // Midnight: yesterday's "called today" clears, so people due today come back on the list.
        let day = Calendar.current.component(.day, from: Date())
        if day != lastTickDay {
            if lastTickDay != 0 {
                callList.resetCalledIfNewDay()
                callList.refreshUpNext()
                leads.resetIfNewDay()
                ActivityLog.add("New day: called-today list cleared")
            }
            lastTickDay = day
        }
        skipForeignLead()
        promotePendingIfReady()
        if status == .live {
            let next = CoachMachine.state(signals())
            if next != coachState {
                ActivityLog.add("Coach state: \(coachState.rawValue) -> \(next.rawValue)")
                CallTrace.event("state", ["from": coachState.rawValue, "to": next.rawValue, "signals": signals().trace])
                coachState = next
            }
        } else if coachState != .idle { coachState = .idle }
        if phase != loggedPhase {
            ActivityLog.add("Phase: \(loggedPhase.rawValue) -> \(phase.rawValue)")
            loggedPhase = phase
        }
        let onCall = AudioProcess.anyCallApp(in: AudioProcess.others())
        // Between calls, notice which record is open so the opener uses their name.
        // Dialed from the app: start listening once the Aircall app picks up the call (or after 8 s).
        if let since = pendingDialSince, status == .ready {
            // Start listening almost right away, so a "straight to voicemail" greeting is heard from word one.
            if AudioProcess.aircallAppOnCall(in: AudioProcess.others()) || Date().timeIntervalSince(since) > 1 {
                pendingDialSince = nil
                waitingForNewCall = false
                startCall()
            }
            return
        }
        if status == .ready, !leads.isActive, !onCall || waitingForNewCall {
            tabTicks += 1
            if tabTicks % 2 == 0 {
                callList.captureIfListView()
                if openingID == nil { callList.refreshUpNext() }
                syncRecord()
            }
        }
        // In-app phone, call placed on the phone itself (not the Dial button): its red hang-up
        // button showing is the sign of a real call. Its open mic alone never is.
        if status == .ready, AircallPhone.isOn, pendingDialSince == nil { checkPhoneForNewCall() }
        switch status {
        case .ready where onCall:
            if waitingForNewCall || AircallPhone.isOn {
                // In-app phone: its own mic is held open all session, so sound alone never means a call.
                // Calls start from Dial, or when Aircall itself shows a new call.
                waitingForNewCall = true
                // Chrome is still holding the last call's mic/speaker: start only when Aircall shows a new call.
                checkAircallForNewCall()
            } else {
                startCall()
            }
        case .ready:
            waitingForNewCall = false // Chrome let go, so the next time it grabs the mic is a new call
        case .live:
            if onCall {
                heardCallAudio = true
                // Chrome's Aircall: call audio means the call was placed. (The in-app phone holds its mic open, so not there.)
                if !AircallPhone.isOn { markPlaced("call audio") }
            }
            // Safety net: nobody has said a word for 90 s = the call is over (no real call is that quiet).
            let silentFor = Date().timeIntervalSince(lastWordsAt ?? callStartedAt)
            if silentFor > 90, !startedByHand {
                ActivityLog.problem("Call ended: 90 s with no words")
                endCall(); return
            }
            // Only count quiet after the call's audio has shown up once, so a call that's
            // still ringing (we start listening right after dialing) isn't ended early.
            // In-app phone: its mic is held open all session, so "the call app went quiet" means nothing.
            // The phone's hang-up button and Aircall itself say when the call ends.
            if !startedByHand, !AircallPhone.isOn, heardCallAudio || Date().timeIntervalSince(callStartedAt) > 45 {
                quietTicks = onCall ? 0 : quietTicks + 1
                if quietTicks >= 6 { endCall(); return } // Chrome let go of the call for 3 seconds
            }
            // Rang 20 seconds and nobody spoke (no person, no recording): hang up for the rep, so the
            // redial or the next person starts by itself.
            if autoDial, AircallPhone.isOn, !startedByHand, !autoHungUpThisCall, !autoHangingUp,
               !phoneTreeActive, !phoneTreeThisCall, !sawVoicemail, !screenerActive, !voicemailDropStarted,
               !turns.contains(where: { $0.speaker == .prospect }),
               Date().timeIntervalSince(callStartedAt) > ringLimit {
                hangUpUnanswered()
            }
            if sawVoicemail || voicemailActive || kind == .voicemail { scheduleVoicemailDrop() } // whichever part spotted it
            checkAircallEveryFewSeconds()
            if aircallTicks % 2 == 0, Date().timeIntervalSince(callStartedAt) < 30 { followCallAudio() }
            if AudioProcess.doubleCall(in: AudioProcess.others()) {
                problem = "Two calls at once: Aircall is signed in here and in Salesforce. Log out of the Aircall panel in Salesforce."
            }
        default:
            break
        }
    }

    /// The End call button: hangs up the phone for real (Aircall's own button), then resets the app.
    func hangUpAndEnd() {
        guard status != .ready else { return }
        autoHungUpThisCall = true
        // Reset right now, don't wait for Aircall: the hang-up click happens in the background.
        if AircallPhone.isOn { Task { _ = await AircallPhone.shared.hangUp() } }
        endCall()
    }

    /// How long to let it ring: 20 s only on the first dial when "Call twice" is on (a redial follows).
    /// Any other dial rings until their voicemail answers, so the drop can wait for the end of the greeting.
    var ringLimit: TimeInterval {
        currentAttempts < maxAttempts ? 20 : .infinity
    }

    /// 20 seconds of ringing and nobody spoke: hang up, then the normal flow (redial, or the next person).
    func hangUpUnanswered() {
        autoHungUpThisCall = true
        ActivityLog.add("Rang 20 s with no answer for \(calling ?? "?"): hanging up")
        Task { [weak self] in
            guard let self, self.status == .live else { return }
            let done = await AircallPhone.shared.hangUp()
            guard done else { ActivityLog.problem("Ringing hang-up: couldn't find Aircall's hang-up button"); return }
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1))
                if await Aircall.lineIsOnCall() == false { break }
            }
            if self.status == .live { self.endCall() }
        }
    }

    /// A short note at the top that fades by itself.
    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// The rep clicked End call (or Aircall/Chrome says it's over): reset for the next call.
    func endCall() {
        guard status != .ready else { return }
        callEndedAt = Date() // the real hang-up time (not when the app finishes resetting)
        SpaceKey.callLive = false
        // A possible opt-out still waiting when the call ends is an opt-out: write it now, for this lead (Fix 1b).
        if let p = pendingAmbiguousOptOut, !doNotCall {
            pendingAmbiguousOptOut = nil
            pendingOptOutTask?.cancel()
            // Include words still in progress ("...until Tuesday" not final yet when they hung up).
            let later = (uncoached + " " + (interim[.prospect] ?? "")).trimmingCharacters(in: .whitespaces)
            if PendingOptOut.resolve(pending: p, later: later, utteranceEnded: false, callEnded: true, secondsWaited: 0) == .optOut {
                CallTrace.event("optout.flushed", ["said": p, "why": "the call ended before the full pause"])
                handleOptOut((p + " " + later).trimmingCharacters(in: .whitespaces))
            }
        }
        CallTrace.endCall(["lead": calling ?? "?", "seconds": Int(Date().timeIntervalSince(callStartedAt)),
                           "voicemail": sawVoicemail, "they_spoke": turns.contains { $0.speaker == .prospect },
                           "turns": turns.count, "last_line": suggestion.say])
        let hadVoicemail = sawVoicemail // for the log
        if hadVoicemail, !(currentAttempts < maxAttempts && autoDial), !autoHungUpThisCall, repWordsInCall >= 8,
           let key = currentAttemptKey,
           Cadence.leavesVoicemail(for: key),
           let said = voicemailScript?.say, voicemailFor == calling {
            DialHistory.logVoicemail(key, body: said)
        }
        // Didn't connect: over in under 12 seconds, nobody talked, no voicemail. That's a bad
        // number's beeping tone or a dropped call, not a person who didn't pick up (that rings 20+ s).
        let quickFail = !badNumberThisCall && !startedByHand && !sawVoicemail
            && Date().timeIntervalSince(callStartedAt) < 12
            && !turns.contains { $0.speaker == .prospect }
        ActivityLog.add("Call ended: \(calling ?? "?") after \(Int(Date().timeIntervalSince(callStartedAt))) s. voicemail=\(sawVoicemail) theySpoke=\(turns.contains(where: { $0.speaker == .prospect })) bad=\(badNumberThisCall)")
        if !turns.isEmpty {
            let words = turns.map { "\($0.speaker == .rep ? "Rep" : "Them"): \($0.text)" }.joined(separator: " | ")
            ActivityLog.add("Transcript: \(words.prefix(6000))")
        }
        if quickFail { attempt?.badNumberDetected() }
        if quickFail, let key = currentAttemptKey {
            outcomeSaved.insert(String(key.prefix(15))) // nothing to rate
            let fails = DialHistory.logFailedConnect(key)
            if fails >= 2 { markNotQualityProspect(key, reason: "didn't connect twice") }
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true // no redial
            problem = fails >= 2 ? "Didn't connect again. Bad number: taken off your list." : "Didn't connect (bad number or network). Moving on."
            afterHangUp { [weak self] in self?.startNextSequence() }
            return
        }
        if badNumberThisCall {
            // Number doesn't work: no voicemail, no text, no redial. Off the list, on to the next.
            badNumberThisCall = false
            if let key = currentAttemptKey { outcomeSaved.insert(String(key.prefix(15))) }
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true
            problem = phoneTreeThisCall ? "Phone tree. Disqualified and taken off your list." : "Bad number. Taken off your list."
            afterHangUp { [weak self] in self?.startNextSequence() }
            return
        }
        // 2nd try went to voicemail: they've had both calls. Move on by itself.
        let moveOn = sawVoicemail && currentAttempts >= maxAttempts
        nextCall()
        waitingForNewCall = true
        endedAt = Date()
        // Didn't reach them (no answer or voicemail): the text and LinkedIn card shows after
        // every such call, even when the voicemail greeting wasn't caught.
        if !lastCallAnswered, followUp == nil || followUp?.key != currentAttemptKey {
            startFollowUp()
            ActivityLog.add("Follow-up card for \(calling ?? "?") (voicemail heard: \(hadVoicemail))")
        }
        if let key = currentAttemptKey, RemovedList.contains(key) {
            // Marked Unqualified (or Not Quality Prospect / Negative) during the call: no text, no redial.
            ActivityLog.add("Call ended for someone taken off the list: on to the next person")
            followUp = nil
            waitingForText = false
            afterHangUp { [weak self] in self?.startNextSequence() }
        } else if shouldOfferRedial, autoDial {
            // 1st try, no answer: "Calling Jane Doe again in 3", then redial the same person.
            startAutoRedial()
        } else if !shouldOfferRedial, !lastCallAnswered, let f = followUp {
            // Done with them for now (both dials): send the text, then the next call starts.
            // No wait when no text can go out: none due today, already sent, a phone tree, or no
            // Mobile (landline only). An empty phone box always means no Mobile, so the text is skipped.
            let noMobile = f.noMobile || f.phone.trimmingCharacters(in: .whitespaces).isEmpty
            if f.textDue, !f.textDone, noMobile {
                followUp?.noMobile = true
                applyPlan() // hides the text and says why
                ActivityLog.add("No Mobile for \(calling ?? "?"): text skipped, on to the next person")
            }
            if f.textDone || !f.textDue || noMobile || phoneTreeThisCall {
                afterHangUp { [weak self] in self?.startNextSequence() }
            } else if autoDial, Aircall.isSetUp, Prefs.autoText, !f.text.isEmpty {
                // The text goes out in the background while the next person loads. No waiting.
                sendTextInBackground(f)
                afterHangUp { [weak self] in self?.startNextSequence() }
            } else {
                waitingForText = true
                startTextCountdown() // waits for its words, then sends by itself in 5 seconds (or the rep sends it)
            }
        } else if lastCallAnswered, autoDial, currentAttemptKey != nil {
            // A real talk just ended: Claude fills "How did it go?" from the transcript (you can change it),
            // then 10 seconds, then the next person. Wait stops it.
            autoOutcome()
            afterHangUp { [weak self] in self?.startMoveOn(after: 10) }
        } else if moveOn {
            afterHangUp { [weak self] in self?.startNextSequence() }
        }
    }

    /// Reached a recording (100% sure: words only a machine says) and auto-dial is on:
    /// - 1st try: hang up, then redial in 1 s.
    /// - Last try on a no-voicemail day: hang up, then on to the next person (after the text, if one is due).
    /// Clicks Aircall's hang-up button and waits until Aircall says the line is free.
    /// If anything is off (no button, line still busy), it does nothing and the rep hangs up as usual.
    func autoHangUpForRedial(why: String = "beep words") {
        guard autoDial, AircallPhone.isOn, !autoHangingUp, !autoHungUpThisCall, !voicemailDropStarted, // the drop is playing
              !phoneTreeActive, !phoneTreeThisCall, // never hang up on a phone menu
              let key = currentAttemptKey, !RemovedList.contains(key) else { return }
        let redialNext = currentAttempts < maxAttempts && !DialHistory.isMaxed(key)
        let noVoicemailToday = !Cadence.leavesVoicemail(for: key)
        guard redialNext || noVoicemailToday else { return } // a voicemail day's last try: leave the message
        autoHangingUp = true
        autoHungUpThisCall = true
        ActivityLog.add(redialNext ? "Recording for sure (\(why)) on the 1st try for \(calling ?? "?"): hanging up to redial"
                                   : "Recording (\(why)) on the last try, no voicemail today, for \(calling ?? "?"): hanging up, on to the next person")
        Task { [weak self] in
            guard let self, self.status == .live else { self?.autoHangingUp = false; return }
            var done = await AircallPhone.shared.hangUp()
            if done {
                // Only end the call on our side once Aircall says the line is free (up to 5 s).
                done = false
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(1))
                    if await Aircall.lineIsOnCall() == false { done = true; break }
                }
            }
            self.autoHangingUp = false
            guard self.status == .live else { return }
            if done {
                self.redialRightAway = redialNext
                self.endCall() // last try: endCall moves on to the next person
            } else {
                ActivityLog.problem("Auto hang-up didn't finish: the rep hangs up, redial as usual")
            }
        }
    }

    /// Counts down 3 seconds (1 after an automatic hang-up), then calls the same person again. Wait stops it.
    func startAutoRedial() {
        autoNextTask?.cancel()
        autoNextName = Screener.fullName(calling).map { "\($0) again" }
        let countdown = redialRightAway ? 1 : 3
        redialRightAway = false
        autoNextTask = Task { [weak self] in
            for left in stride(from: countdown, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled, self.shouldOfferRedial else { return }
            self.autoNextIn = nil
            self.redial()
        }
    }

    /// Counts down 5 seconds, then loads the next lead (and calls them, if "Next calls right away" is on).
    func startAutoNext(seconds: Int = 1) {
        guard nextLeadName != nil else { return }
        autoNextTask?.cancel()
        autoNextTask = Task { [weak self] in
            for left in stride(from: seconds, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                // A call started some other way: stop counting.
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled else { return }
            self.nextLead()
        }
    }

    /// Counts down, then moves to the next person (and calls them). Used after a real talk and
    /// after "How did it go?" is saved. Wait stops it.
    /// Reads the call and picks "How did it go?" (Interested, Not now, Not a fit, or nothing if unclear).
    /// Saves after 4 s unless the rep picked one first. Uses Haiku: fast and cheap.
    func autoOutcome() {
        guard let key = currentAttemptKey, turns.contains(where: { $0.speaker == .prospect }) else { return }
        let object = key.hasPrefix("003") ? "Contact" : "Lead"
        let options = Outcomes.quick(object)
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Them"): \($0.text)" }.joined(separator: "\n")
        let who = calling
        Task { [weak self] in
            let system = """
            You read a finished cold call and pick how it went. Options: \(options.map(\.label).joined(separator: ", ")), or None.
            Interested: they agreed to a meeting or asked to hear more. Not now: bad timing, call back later, send an email.
            Not a fit: the right person said they're clearly not interested, wrong company, or no need. None: only a front desk, a hang-up, a wrong number or someone else answered, or too short to tell.
            If Not a fit, also pick the closest reason from: \(Salesforce.unqualifiedReasons.joined(separator: ", ")), or "".
            Return only JSON: {"outcome": "", "reason": "", "why": "one short sentence"}
            """
            guard let json = try? await CallLab.ask(system: system, user: transcript, effort: "low", model: "claude-haiku-5-5"),
                  let label = json["outcome"] as? String, let pick = options.first(where: { $0.label == label }) else {
                ActivityLog.add("How did it go: left for you (Claude wasn't sure for \(who ?? "?"))")
                return
            }
            let reason = (json["reason"] as? String).flatMap { Salesforce.unqualifiedReasons.contains($0) ? $0 : nil }
            guard let self else { return }
            ActivityLog.add("How did it go: Claude picked \(pick.label) for \(who ?? "?") (\((json["why"] as? String) ?? ""))")
            self.showToast("How did it go: \(pick.label). Saving in 4 s, click another to change.")
            try? await Task.sleep(for: .seconds(4))
            guard !self.outcomeSaved.contains(String(key.prefix(15))), self.statusRecordID?.prefix(15) == key.prefix(15), !self.savingStatus else { return }
            if pick.value == "Unqualified", object == "Lead", reason == nil { // Salesforce needs a reason
                ActivityLog.add("How did it go: Not a fit needs a reason, left for you")
                return
            }
            self.saveStatus(pick.value, unqualifiedReason: reason)
        }
    }

    func startMoveOn(after seconds: Int) {
        guard status == .ready else { return }
        autoNextTask?.cancel()
        autoNextName = nextLeadName
        autoNextTask = Task { [weak self] in
            for left in stride(from: seconds, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled else { return }
            self.autoNextIn = nil
            self.startNextSequence()
        }
    }

    /// Sends the text from a copy of the card, 3 seconds from now, while the next person loads. The
    /// card can change meanwhile. A failure shows a note and never holds up the dialing.
    func sendTextInBackground(_ f: FollowUp) {
        bgTextTask?.cancel()
        bgTextTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            ActivityLog.add("Text: sending in the background for \(f.prospect ?? "?")")
            self.sendText(f, background: true)
        }
    }

    /// A text is due: wait for its words, count down 5 seconds, then send it. Editing the text,
    /// Edit or Skip stops the countdown (the rep then sends it by hand).
    func startTextCountdown() {
        textTask?.cancel()
        guard autoDial, Aircall.isSetUp else { return }
        textTask = Task { [weak self] in
            var waited = 0
            while let self, !Task.isCancelled, self.waitingForText, self.followUp?.text.isEmpty ?? true, waited < 20 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            for left in stride(from: 5, through: 1, by: -1) {
                guard let self, !Task.isCancelled, self.waitingForText, self.status == .ready,
                      self.followUp?.textEdited != true else { self?.textSendIn = nil; return }
                self.textSendIn = left
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, self.waitingForText, self.status == .ready,
                  self.followUp?.textEdited != true else { self?.textSendIn = nil; return }
            self.textSendIn = nil
            ActivityLog.add("Text: sending by itself after the countdown")
            self.sendFollowUpText()
            // Failsafe: if nothing was sent (no text written, or it couldn't go), move on after 20 s.
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, self.waitingForText, self.status == .ready else { return }
            ActivityLog.problem("Text: nothing went out for \(self.followUp?.prospect ?? "?") after 25 s, moving on to the next person")
            self.waitingForText = false
            self.startNextSequence()
        }
    }

    func stopTextCountdown() {
        textTask?.cancel()
        textTask = nil
        textSendIn = nil
    }

    /// The rep clicked Wait (or moved on by hand).
    func cancelAutoNext() {
        stopTextCountdown()
        hangUpGen += 1
        waitingForText = false
        autoNextName = nil
        readyTask?.cancel()
        gettingReady = nil
        gettingReadyDetail = nil
        autoNextTask?.cancel()
        autoNextTask = nil
        autoNextIn = nil
    }

    func checkAircallForNewCall() {
        aircallTicks += 1
        guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
        aircallCheck = Task { [weak self] in
            let since = self?.endedAt ?? Date()
            let onCall = await Aircall.lineIsOnCall(since: since)
            guard let self else { return }
            self.aircallCheck = nil
            if onCall == true, self.status == .ready, self.waitingForNewCall {
                self.waitingForNewCall = false
                self.startCall()
            }
        }
    }

    /// Between calls: the hang-up button seen on 2 checks in a row (and not just the last call's
    /// button fading out) = a call started on the phone. Start listening.
    func checkPhoneForNewCall() {
        guard phoneButtonCheck == nil, Date().timeIntervalSince(endedAt) > 3 else { return }
        phoneButtonCheck = Task { [weak self] in
            let visible = await AircallPhone.shared.hangUpButtonVisible()
            guard let self else { return }
            self.phoneButtonCheck = nil
            guard self.status == .ready, self.pendingDialSince == nil else { return }
            self.phoneCallSeen = visible == true ? self.phoneCallSeen + 1 : 0
            if self.phoneCallSeen >= 2 {
                self.phoneCallSeen = 0
                self.waitingForNewCall = false
                ActivityLog.add("Call placed on the phone itself: listening")
                self.startCall()
            }
        }
    }

    /// A second, faster signal: the phone's red hang-up button disappears the moment the call ends.
    /// Only trusted after it has been seen once in this call, and gone for 3 checks in a row (about 1.5 s).
    func checkPhoneButton() {
        guard AircallPhone.isOn, phoneButtonCheck == nil else { return }
        phoneButtonCheck = Task { [weak self] in
            let visible = await AircallPhone.shared.hangUpButtonVisible()
            guard let self else { return }
            self.phoneButtonCheck = nil
            guard self.status == .live, let visible else { return }
            if visible { self.phoneSawHangUp = true; self.phoneButtonGone = 0; return }
            guard self.phoneSawHangUp else { return }
            self.phoneButtonGone += 1
            if self.phoneButtonGone >= 3 {
                ActivityLog.add("The phone's hang-up button is gone: the call is over")
                self.endCall()
            }
        }
    }

    func checkAircallEveryFewSeconds() {
        checkPhoneButton()
        aircallTicks += 1
        guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
        // Give Aircall a moment to register a brand-new call before trusting a "no".
        guard Date().timeIntervalSince(callStartedAt) > 5 else { return }
        aircallCheck = Task { [weak self] in
            let onCall = await Aircall.lineIsOnCall()
            guard let self else { return }
            self.aircallCheck = nil
            guard self.status == .live, let onCall else { return }
            if onCall { self.aircallSawCall = true; self.markPlaced("Aircall shows the call") }
            // Trust Aircall's "no call" once it has listed this call, or after 20 s if it never
            // lists it (some setups don't). But never while people are still talking.
            let age = Date().timeIntervalSince(self.callStartedAt)
            let talking = self.lastWordsAt.map { Date().timeIntervalSince($0) < 8 } ?? false
            guard self.aircallSawCall || age > 20, !talking else { self.aircallSaysOver = 0; return }
            self.aircallSaysOver = onCall ? 0 : self.aircallSaysOver + 1
            if self.aircallSaysOver >= 2 {
                ActivityLog.add("Aircall says the call is over")
                self.endCall()
            }
        }
    }

    func startByHand() {
        waitingForNewCall = false
        startedByHand = true
        startCall()
    }

    // MARK: Block timer: 50 minutes of calling, then a 10 minute break

    /// The sprint's length, picked on the Call Sprint card (20, 30 or 50 minutes).
    static var blockLength: TimeInterval {
        let m = UserDefaults.standard.integer(forKey: "sprintMinutes")
        return TimeInterval((m > 0 ? m : 20) * 60)
    }
    /// The sprint starts by itself on the first dial unless the rep ended one by hand.
    static var sprintArmed: Bool {
        get { UserDefaults.standard.object(forKey: "sprintArmed") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sprintArmed") }
    }

    /// A dial started: begins the sprint if one is waiting for its first dial.
    func sprintSawDial() {
        guard blockStartedAt == nil, !sprintDone else { return }
        startBlock()
    }

    /// Sprint Complete → New Sprint: back to the setup, waiting for the next first dial.
    func newSprint() {
        blockStartedAt = nil
        sprintDone = false
        breakUntil = nil
    }
    static let breakLength: TimeInterval = 10 * 60

    func startBlock() {
        Self.sprintArmed = true
        blockStartedAt = Date()
        breakUntil = nil
        BlockLog.add(blockStartedAt!)
        ActivityLog.add("Sprint started on the first dial")
    }

    func stopBlock() {
        Self.sprintArmed = false // ended by hand: don't restart on the next dial
        if breakUntil != nil { autoDial = autoDialBeforeBreak }
        blockStartedAt = nil
        breakUntil = nil
    }

    /// The block ran out (and no call is on): break time. The break ran out: back to calling.
    func checkBlock() {
        if let until = breakUntil {
            if Date() >= until { endBreak() }
            return
        }
        // Time's up: mark it complete. Never touches a call or auto dial; the rep keeps calling.
        guard let start = blockStartedAt, !sprintDone,
              Date().timeIntervalSince(start) >= Self.blockLength else { return }
        sprintDone = true
        NSSound(named: "Glass")?.play()
        ActivityLog.add("Sprint complete")
    }

    /// Skip break, or the break is over: auto dial back on, new block, next call.
    func endBreak() {
        autoDial = autoDialBeforeBreak
        breakUntil = nil
        blockStartedAt = Date()
        BlockLog.add(blockStartedAt!)
        ActivityLog.add("Block: break over, calling again")
        if autoDial { startNextSequence() }
    }

    /// Skip to the next person, but never run away: 3 skips in a row with no call stops auto dial
    /// and says why, instead of flipping through the list opening and closing pages.
    func skipNext(why: String) {
        skipsInARow += 1
        if skipsInARow >= 3 {
            ActivityLog.problem("Skipped \(skipsInARow) people in a row (last: \(why)). Auto dial stopped so the app doesn't flip through your list.")
            problem = "Skipped \(skipsInARow) people in a row: \(why). Auto dial stopped. Check the call list settings, then press Next."
            Prefs.autoDial = false
            skipsInARow = 0
            return
        }
        nextLead(dial: Prefs.autoDial)
    }

    func startCall() {
        skipsInARow = 0
        problem = nil
        redialRightAway = false
        autoHungUpThisCall = false
        phoneTreeThisCall = false
        phoneTreeActive = false
        phoneTreeTask?.cancel()
        keysMessage = nil
        guard startAudio() else { return }
        if !leads.isActive { callList.markCurrentCalled() } // so Next skips them today (Chrome list)
        if let key = recordKey() {
            currentAttemptKey = key
            attempts[key, default: 0] += 1
        }
        // The dial is counted when the call ends, and only if the phone confirmed it was placed.
        attempt = CallAttempt(leadID: currentAttemptKey, campaign: touchpoints.currentCampaign)
        callEndedAt = nil
        if AudioProcess.aircallAppOnCall(in: AudioProcess.others()) || !Aircall.isSetUp { markPlaced(Aircall.isSetUp ? "Aircall app on a call" : "no Aircall check available") }
        if let a = attempt { CallAttemptStore.shared.upsert(a) }
        callMessage = nil
        pendingDialSince = nil // this dial is now the live call
        BeepDetector.shared.reset()
        CallTrace.beginCall(lead: calling, attempt: currentAttempts)
        questionTracker = QuestionTracker()
        objectionTracker = ObjectionTracker()
        CoachPrompt.objectionFacts = ""
        CoachPrompt.shownLines = []
        CoachPrompt.saidLines = []
        CoachPrompt.likelyCoveredLines = []
        recentRepChunks = []
        CoachPrompt.lastSaidStage = ""
        repEndpointed = false
        lastEarlyBasis = nil
        earlyDraftsThisTurn = 0
        repWordsAtLastAsk = 0
        repLedIDs = []
        yesBranch = nil
        yesBranchTask?.cancel()
        loggedSystemHash = ""
        logSystemIfChanged() // the full static instructions + script Claude gets this call
        phoneSawHangUp = false
        holdLine = false
        pending = nil
        phoneButtonGone = 0
        CoachPrompt.liveSummary = ""
        CoachPrompt.summaryCoversTurns = 0
        summaryInFlight = false // a summary left from the last call never blocks this one
        screenerRetries = 0
        prospectNos = 0
        callClosed = false
        callLinesShown = 0
        callLinesUsed = 0
        prospectTurnsAfterFirstNo = 0
        closedOnSecondNo = false
        followsThisStretch = 0
        frozenShownID = -1
        installSpaceKey()
        SpaceKey.onFresh = { [weak self] in self?.freshLine() }
        SpaceKey.install()
        SpaceKey.callLive = true // Space in Chrome = fresh line, during this call only
        CoachPrompt.questionFacts = "" // never carry the last call's questions into this one
        CoachPrompt.answeredQuestions = []
        CoachPrompt.recentText = ""
        doNotCall = false
        timeline = SpeechTimeline()
        CoachPrompt.blockerHints = BlockerBook.hints(campaign.id)
        ActivityLog.add("Call started: \(calling ?? "?") (try \(currentAttempts))")
        // Haiku vs Sonnet test: each call alternates; the redial of the same person keeps the same model.
        if currentAttempts <= 1 { LiveCoach.callModel = LiveCoach.pickModelForNextCall() }
        CallTrace.event("ab.model", ["live_model": LiveCoach.callModel, "why": "calls alternate Haiku and Sonnet to compare them"])
        ActivityLog.add("Models this call: live lines \(ClaudeClient.displayName(LiveCoach.client("").model)), "
            + "opener \(ClaudeClient.displayName(CoachSpeed.current.client(apiKey: "").model)) (speed: \(CoachSpeed.current.label)), "
            + "voicemail \(ClaudeClient.displayName(CoachSpeed.fastest.client(apiKey: "").model)), "
            + "fixes in code, then one retry on the live model")
        attempt?.liveModel = LiveCoach.callModel
        // Calling someone new: the last person's follow-up card goes away.
        if let f = followUp, f.key != nil, f.key != currentAttemptKey { followUp = nil }
        status = .live
        streak = Date().timeIntervalSince(lastDialAt) < 180 ? streak + 1 : 1
        lastDialAt = Date()
        voicemailDropStarted = false
        dropWhyLogged = false
        if let key = currentAttemptKey { outcomeSaved.remove(String(key.prefix(15))) } // a new call: rate it again
        prewarmNext() // get the next person ready while this call rings
        quietTicks = 0
        availability.refresh() // fresh free times for this call
        callOpener = kind == .opener ? openerStyle : nil
        goalHit = false
        goalPending = false
        meetingThisWeek = nil
        sawVoicemail = false
        stagesSeen = []
        callStartedAt = Date()
        heardCallAudio = false
        retargets = 0
        aircallSaysOver = 0
        aircallSawCall = false
        aircallTicks = 0
        journeyStep = 0
        history = Array(history.suffix(1)) // keep the opener as the first line
        historyIndex = nil
        repWordsInCall = 0
        repWordsSinceShown = 0
        offeredTimes = []
        codeByDate = [:]
        nextOffer = []
        screenerActive = false
        openerBeforeScreener = nil
        voicemailActive = false
        badNumberThisCall = false
        mailboxFullShown = false
        followUpThisCall = false
        cancelAutoNext()
        if voicemailScript == nil { prepareVoicemail() }
        firstProspectAt = nil
        lastWordsAt = nil
    }

    /// Stages that only happen with the actual prospect, not a front desk or assistant.
    static let prospectStages: Set<String> = ["Discovery", "Value", "Objection", "Closing", "Goal reached"]

    /// The phone confirmed the call was placed: it counts as a dial.
    func markPlaced(_ why: String) {
        guard var a = attempt, a.placedAt == nil, !a.finalized else { return }
        a.placed()
        attempt = a
        CallAttemptStore.shared.upsert(a)
        CallTrace.event("call.placed", ["why": why])
    }

    /// Decides how the call ended (once), saves it, and counts it. Returns: a real person answered.
    @discardableResult
    func finalizeAttempt() -> Bool {
        guard var a = attempt else { return false }
        attempt = nil
        // finalize() only works once: a second call (any path) counts nothing again.
        guard a.finalize(endedAt: callEndedAt ?? Date()) else { return a.outcome?.humanAnswered ?? false }
        callEndedAt = nil
        CallAttemptStore.shared.upsert(a)
        CallTrace.event("call.outcome", ["outcome": a.outcome?.rawValue ?? "?", "why": a.classificationSource,
                                         "placed": a.placedAt != nil, "conversation": a.conversation,
                                         "model_stages": a.modelStages, "live_model": a.liveModel ?? ""])
        ActivityLog.add("Call outcome for \(calling ?? a.leadID ?? "?"): \(a.outcome?.rawValue ?? "?") (\(a.classificationSource))")
        applyOutcome(a, live: true)
        return a.outcome?.humanAnswered ?? false
    }

    /// Counts one finished call everywhere from its record: My numbers, the call plan, Salesforce.
    func applyOutcome(_ a: CallAttempt, live: Bool) {
        PickedUpSync.flush() // anything still waiting from an earlier call
        guard let o = a.outcome, a.placedAt != nil else { return } // never placed: not a dial
        touchpoints.log(.dial, at: a.startedAt, campaign: a.campaign, lead: a.leadID)
        if let key = a.leadID { DialHistory.logDial(key) }
        if o == .voicemail, !(a.leadID.map { CallAttemptStore.shared.voicemailCountedToday(lead: $0, except: a.attemptID) } ?? false) {
            touchpoints.log(.voicemail, at: a.startedAt, campaign: a.campaign, lead: a.leadID)
        }
        guard o.humanAnswered else { return }
        touchpoints.log(.pickup, at: a.startedAt, campaign: a.campaign, lead: a.leadID)
        if live { NSSound(named: "Tink")?.play() } // a soft sound: someone picked up
        if a.conversation { touchpoints.log(.conversation, at: a.startedAt, campaign: a.campaign, lead: a.leadID) }
        if live, goalHit { touchpoints.log(.meeting) }
        // A gatekeeper (or wrong number) answered: they stay on the plan, no checkbox.
        guard o.prospectReached, let key = a.leadID else {
            if o == .humanGatekeeper { ActivityLog.add("Gatekeeper only for \(a.leadID ?? "?") (\(a.classificationSource)): stays on the plan") }
            return
        }
        DialHistory.logPickup(key) // the prospect picked up: the call plan stops for them
        // A real conversation with the prospect: check "Picked Up Cold Call" in Salesforce (same rule as before).
        guard a.conversation else {
            ActivityLog.add("Short pickup for \(key): Picked Up Cold Call not checked")
            return
        }
        PickedUpSync.mark(key)
    }

    /// Clears everything about this prospect and gets the next opener ready.
    func nextCall() {
        SpaceKey.callLive = false // Space is normal again everywhere
        yesShowTask?.cancel()
        openerWaitTask?.cancel()
        testLineCounted = false
        followPausedUntilQuiet = false
        // The call is over: the next person starts clean, before their opener is prepared below (round 3).
        doNotCall = false
        pendingAmbiguousOptOut = nil
        pendingOptOutTask?.cancel()
        if status != .ready {
            // Reached a person = they spoke, and it wasn't a voicemail or only a screener.
            lastCallAnswered = finalizeAttempt()
        }
        history = []
        historyIndex = nil
        journeyStep = 0
        scoreOpener()
        stopAudio()
        coachTask?.cancel()
        holdTask?.cancel()
        startedByHand = false
        turns = []
        interim = [:]
        uncoached = ""
        latestProspect = ""
        latency = nil
        status = .ready
        if leads.isActive {
            applyLead()
        } else {
            // The call is over: the voicemail (or any mid-call line) goes away and a fresh
            // "when they pick up" opener shows right away, ready for the redial.
            prepareOpener()
            // Read Chrome a moment later, not while Aircall plays the hang-up tone.
            afterHangUp { [weak self] in self?.syncRecord() } // same person: keep their ready voicemail
        }
    }

    /// Runs work 2 seconds after a call ends. Doing it all at the hang-up moment
    /// (Chrome reads, saving, loading the next person) makes Aircall's hang-up tone skip.
    func afterHangUp(_ work: @escaping () -> Void) {
        let gen = hangUpGen
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            // Skip it if the rep already moved on by hand (Next, Redial, Call).
            guard let self, self.status == .ready, self.hangUpGen == gen else { return }
            work()
        }
    }

    /// Scores the call if a real person answered (not voicemail): credits the opener,
    /// then saves it to the Script Lab.
    func scoreOpener() {
        defer { callOpener = nil }
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        // Skip voicemails, no-answers, and calls where only a screener ever talked.
        guard status != .ready, !sawVoicemail, !screenerActive, prospectTurns > 0, let start = firstProspectAt else { return }
        let talk = max(0, (lastWordsAt ?? start).timeIntervalSince(start))
        let score = CallScore.compute(talkSeconds: talk, stages: stagesSeen, goal: goalHit)
        let usedOpener = callOpener.flatMap { $0 == openers.current ? $0 : nil }
        if usedOpener != nil {
            openers.record(score: score, kept: prospectTurns >= 3, goal: goalHit)
        }
        if let key = currentAttemptKey { DialHistory.logTalked(key) }
        let record = CallRecord(
            campaignID: campaign.id, campaignVersion: campaign.version, openerID: usedOpener?.id,
            talkSeconds: talk, prospectTurns: prospectTurns, stages: Array(stagesSeen).sorted(),
            goal: goalHit, score: score, liveModel: LiveCoach.callModel,
            linesShown: callLinesShown, linesUsed: callLinesUsed,
            hadNo: prospectNos > 0, pastFirstNo: prospectNos > 0 && prospectTurnsAfterFirstNo >= 2 && !closedOnSecondNo
        )
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        lab.add(record, campaign: campaign, transcript: transcript, person: calling)
        ActivityLog.add(lab.modelComparison())
    }

    func togglePause() {
        if status == .paused {
            if startAudio() { status = .live }
        } else if status == .live {
            stopAudio()
            coachTask?.cancel()
            status = .paused
        }
    }
}
