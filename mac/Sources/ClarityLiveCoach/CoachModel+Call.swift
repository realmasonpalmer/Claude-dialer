import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// A call from start to end: the tick, starting and ending calls, auto redial and auto next.
extension CoachModel {
    func tick() {
        guard active else { return }
        checkBlock()
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
        switch status {
        case .ready where onCall:
            if waitingForNewCall {
                // Chrome is still holding the last call's mic/speaker: start only when Aircall shows a new call.
                checkAircallForNewCall()
            } else {
                startCall()
            }
        case .ready:
            waitingForNewCall = false // Chrome let go, so the next time it grabs the mic is a new call
        case .live:
            if onCall { heardCallAudio = true }
            // Safety net: nobody has said a word for 90 s = the call is over (no real call is that quiet).
            let silentFor = Date().timeIntervalSince(lastWordsAt ?? callStartedAt)
            if silentFor > 90, !startedByHand {
                ActivityLog.problem("Call ended: 90 s with no words")
                endCall(); return
            }
            // Only count quiet after the call's audio has shown up once, so a call that's
            // still ringing (we start listening right after dialing) isn't ended early.
            if !startedByHand, heardCallAudio || Date().timeIntervalSince(callStartedAt) > 45 {
                quietTicks = onCall ? 0 : quietTicks + 1
                if quietTicks >= 6 { endCall(); return } // Chrome let go of the call for 3 seconds
            }
            // Rang 30 seconds and nobody spoke (no person, no recording): hang up for the rep, so the
            // redial or the next person starts by itself.
            if autoDial, AircallPhone.isOn, !startedByHand, !autoHungUpThisCall, !autoHangingUp,
               !phoneTreeActive, !phoneTreeThisCall, !sawVoicemail, !screenerActive, !voicemailDropStarted,
               !turns.contains(where: { $0.speaker == .prospect }),
               Date().timeIntervalSince(callStartedAt) > 30 {
                hangUpUnanswered()
            }
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
        Task { [weak self] in
            if AircallPhone.isOn { _ = await AircallPhone.shared.hangUp() }
            self?.endCall()
        }
    }

    /// 30 seconds of ringing and nobody spoke: hang up, then the normal flow (redial, or the next person).
    func hangUpUnanswered() {
        autoHungUpThisCall = true
        ActivityLog.add("Rang 30 s with no answer for \(calling ?? "?"): hanging up")
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
        let hadVoicemail = sawVoicemail // for the log
        if hadVoicemail, !(currentAttempts < maxAttempts && autoDial), let key = currentAttemptKey,
           Cadence.step(for: key)?.leaveVoicemail ?? true,
           let said = voicemailScript?.say, voicemailFor == calling {
            DialHistory.logVoicemail(key, body: said)
        }
        // Didn't connect: over in under 12 seconds, nobody talked, no voicemail. That's a bad
        // number's beeping tone or a dropped call, not a person who didn't pick up (that rings 20+ s).
        let quickFail = !badNumberThisCall && !startedByHand && !sawVoicemail
            && Date().timeIntervalSince(callStartedAt) < 12
            && !turns.contains { $0.speaker == .prospect }
        ActivityLog.add("Call ended: \(calling ?? "?") after \(Int(Date().timeIntervalSince(callStartedAt))) s. voicemail=\(sawVoicemail) theySpoke=\(turns.contains(where: { $0.speaker == .prospect })) bad=\(badNumberThisCall)")
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
            // A real talk just ended: 10 seconds to save how it went, then the next person. Wait stops it.
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
        guard autoDial, AircallPhone.isOn, !autoHangingUp, !autoHungUpThisCall,
              !phoneTreeActive, !phoneTreeThisCall, // never hang up on a phone menu
              let key = currentAttemptKey, !RemovedList.contains(key) else { return }
        let redialNext = currentAttempts < maxAttempts && !DialHistory.isMaxed(key)
        let noVoicemailToday = Cadence.step(for: key)?.leaveVoicemail == false
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
    func startAutoNext(seconds: Int = 3) {
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

    func checkAircallEveryFewSeconds() {
        aircallTicks += 1
        guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
        // Give Aircall a moment to register a brand-new call before trusting a "no".
        guard Date().timeIntervalSince(callStartedAt) > 5 else { return }
        aircallCheck = Task { [weak self] in
            let onCall = await Aircall.lineIsOnCall()
            guard let self else { return }
            self.aircallCheck = nil
            guard self.status == .live, let onCall else { return }
            if onCall { self.aircallSawCall = true }
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

    static let blockLength: TimeInterval = 50 * 60
    static let breakLength: TimeInterval = 10 * 60

    func startBlock() {
        blockStartedAt = Date()
        breakUntil = nil
        ActivityLog.add("Block: 50 minutes started")
    }

    func stopBlock() {
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
        guard let start = blockStartedAt, status == .ready, !dialing,
              Date().timeIntervalSince(start) >= Self.blockLength else { return }
        autoDialBeforeBreak = autoDial
        autoDial = false
        cancelAutoNext()
        breakUntil = Date().addingTimeInterval(Self.breakLength)
        NSSound(named: "Glass")?.play()
        ActivityLog.add("Block: done. 10 minute break")
    }

    /// Skip break, or the break is over: auto dial back on, new block, next call.
    func endBreak() {
        autoDial = autoDialBeforeBreak
        breakUntil = nil
        blockStartedAt = Date()
        ActivityLog.add("Block: break over, calling again")
        if autoDial { startNextSequence() }
    }

    func startCall() {
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
        touchpoints.log(.dial)
        callMessage = nil
        pendingDialSince = nil // this dial is now the live call
        ActivityLog.add("Call started: \(calling ?? "?") (try \(currentAttempts))")
        if let key = currentAttemptKey { DialHistory.logDial(key) }
        // Calling someone new: the last person's follow-up card goes away.
        if let f = followUp, f.key != nil, f.key != currentAttemptKey { followUp = nil }
        status = .live
        streak = Date().timeIntervalSince(lastDialAt) < 180 ? streak + 1 : 1
        lastDialAt = Date()
        voicemailDropStarted = false
        if let key = currentAttemptKey { outcomeSaved.remove(String(key.prefix(15))) } // a new call: rate it again
        prewarmNext() // get the next person ready while this call rings
        quietTicks = 0
        availability.refresh() // fresh free times for this call
        callOpener = kind == .opener ? openerStyle : nil
        goalHit = false
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

    /// Counts the call that just ended. Picked up = a real person talked (not voicemail, not
    /// only a screener). Conversation = they kept talking: 3+ turns, or 45+ seconds after pickup.
    func logTouchpoints(answered: Bool) {
        if sawVoicemail { touchpoints.log(.voicemail) }
        guard answered else { return }
        touchpoints.log(.pickup)
        NSSound(named: "Tink")?.play() // a soft sound: someone picked up
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        let talked = firstProspectAt.map { Date().timeIntervalSince($0) } ?? 0
        let conversation = prospectTurns >= 3 || talked >= 45
        if conversation { touchpoints.log(.conversation) }
        if goalHit { touchpoints.log(.meeting) }
        // Only a front desk or assistant talked: not the prospect. Keep them on the plan, no checkbox.
        let gatekeeperOnly = stagesSeen.contains("Gatekeeper") && stagesSeen.isDisjoint(with: Self.prospectStages)
        guard let key = currentAttemptKey, !gatekeeperOnly else {
            if gatekeeperOnly { ActivityLog.add("Front desk only for \(calling ?? "?"): stays on the plan, Picked Up Cold Call not checked") }
            return
        }
        DialHistory.logPickup(key) // the prospect picked up: the call plan stops for them
        // A real conversation with the prospect: check "Picked Up Cold Call" in Salesforce.
        guard conversation else {
            ActivityLog.add("Short pickup for \(calling ?? key) (\(prospectTurns) turns, \(Int(talked)) s): Picked Up Cold Call not checked")
            return
        }
        guard Salesforce.objectFor(id: key) != nil else {
            ActivityLog.problem("Couldn't check Picked Up Cold Call for \(calling ?? key): no Salesforce record on screen")
            return
        }
        guard Salesforce.isConnected else {
            ActivityLog.problem("Couldn't check Picked Up Cold Call: Salesforce isn't connected")
            return
        }
        let who = calling ?? key
        Task {
            do {
                try await Salesforce.markPickedUp(key)
                ActivityLog.add("Picked Up Cold Call checked for \(who)")
            } catch {
                ActivityLog.problem("Couldn't check Picked Up Cold Call for \(who): \(error.localizedDescription)")
            }
        }
    }

    /// Clears everything about this prospect and gets the next opener ready.
    func nextCall() {
        if status != .ready {
            // Reached a person = they spoke, and it wasn't a voicemail or only a screener.
            let theySpoke = turns.contains { $0.speaker == .prospect }
            lastCallAnswered = theySpoke && !sawVoicemail && !screenerActive
            logTouchpoints(answered: lastCallAnswered)
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
        let record = CallRecord(
            campaignID: campaign.id, campaignVersion: campaign.version, openerID: usedOpener?.id,
            talkSeconds: talk, prospectTurns: prospectTurns, stages: Array(stagesSeen).sorted(),
            goal: goalHit, score: score
        )
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        lab.add(record, campaign: campaign, transcript: transcript)
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
