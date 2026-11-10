import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Voicemail, the text and LinkedIn card, and the follow-up plan.
extension CoachModel {
    func followUpChanged() {
        let done = followUp?.textDone == true
        defer { textWasDone = done }
        guard waitingForText, status == .ready else { return }
        // Text just sent, or the card was closed: on to the next person.
        if (done && !textWasDone) || followUp == nil {
            waitingForText = false
            startNextSequence()
        }
    }

    /// Instant voicemail card: the script written before the call, or "mailbox full, move on".
    func showVoicemail(mailboxFull: Bool) {
        voicemailActive = true
        sawVoicemail = true
        screenerActive = false
        coachTask?.cancel()
        thinking = false
        specTimer?.cancel()
        holdTask?.cancel()
        pending = nil
        specBasis = nil
        uncoached = ""
        seq += 1
        startFollowUp()
        if mailboxFull {
            mailboxFullShown = true
            show(Suggestion(say: currentAttempts < maxAttempts ? "Mailbox is full. Hang up and click Redial." : "Mailbox is full. Hang up. The next call starts by itself.",
                            cue: "No message possible.",
                            stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
        } else if let step = currentAttemptKey.flatMap(Cadence.step(for:)), !step.leaveVoicemail {
            // Not a voicemail day in the 21-day plan.
            show(Suggestion(say: currentAttempts < maxAttempts ? "No voicemail today. Hang up. The redial starts by itself."
                                                     : "No voicemail today. Hang up and move on.",
                            cue: "The plan leaves one voicemail, on day 1. Today is day \(Cadence.callDays[step.index]).",
                            stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
        } else if var script = voicemailScript, voicemailFor == calling {
            if currentAttempts < maxAttempts {
                script.cue = "1st try: hang up and click Redial. Leave this message on the 2nd try."
            } else if let step = currentAttemptKey.flatMap(Cadence.step(for:)) {
                script.cue = "Day \(step.planDay) voicemail (the only one in the plan). Wait for the beep."
            }
            show(script, id: seq, kind: .voicemail)
        } else {
            // Not written yet: ask now. The beep usually gives a few seconds.
            show(Suggestion(say: "Writing your voicemail...", cue: "Wait for the beep.", stage: "Voicemail", sayComplete: true),
                 id: seq, kind: .voicemail)
            ask(.voicemail, user: CoachPrompt.voicemail(calling: calling, details: recordDetails,
                                                         earlierTexts: recordKey().map(DialHistory.sentTexts) ?? [],
                                                         earlierMessages: recordKey().map(DialHistory.sentLinkedInMessages) ?? [],
                                                         history: recordKey().map(DialHistory.historySummary) ?? ""))
        }
    }

    /// Sets up the follow-up card for this prospect, filled from the pre-written voicemail if ready.
    func startFollowUp() {
        let name = Screener.fullName(calling)
        // A fresh card for every voicemail, so nothing (like an old error) carries over.
        // Same person as last time (2nd try): keep what was already sent, so they don't get it twice.
        let lead = leads.isActive ? leads.details : nil
        let key = recordKey()
        let earlier = followUp?.key != nil && followUp?.key == key ? followUp : nil
        followUpThisCall = true
        followUp = FollowUp(key: key,
                            prospect: lead?.name ?? name,
                            text: earlier?.text ?? "",
                            linkedin: earlier?.linkedin ?? "",
                            textDone: earlier?.textDone ?? key.map(DialHistory.textedToday) ?? false,
                            linkedinDone: earlier?.linkedinDone ?? key.map(DialHistory.linkedInToday) ?? false,
                            phone: lead?.textNumber ?? Aircall.phone(in: recordDetails) ?? (leads.isActive ? nil : SalesforceChrome.mobileNumber()) ?? "",
                            linkedinURL: lead?.linkedIn ?? Self.linkedInProfile(details: recordDetails),
                            linkedinMessage: earlier?.linkedinMessage ?? "",
                            linkedinMessageDone: earlier?.linkedinMessageDone ?? key.map(DialHistory.linkedInMessageToday) ?? false)
        if followUp?.textDone == true, earlier == nil { followUp?.textStatus = "Already texted today" }
        applyPlan()
        // The script's own messages show right away, no waiting on Claude.
        if var f = followUp {
            var s = Suggestion()
            applyScriptMessages(&s, for: calling)
            if f.text.isEmpty { f.text = s.textMessage }
            if f.linkedin.isEmpty { f.linkedin = s.linkedin }
            if f.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
            followUp = f
        }
        if let script = voicemailScript, voicemailFor == calling { fillFollowUp(from: script) }
        else if detailsTried || leads.isActive, voicemailTask == nil || voicemailFor != calling {
            prepareVoicemail() // it fills the card when done (in Chrome mode, only once the page is read)
        }
        watchFollowUp()
    }

    /// The card must never sit on "Writing..." forever (Claude failed, timed out, or answered for
    /// someone else). After 12 s with nothing: ask Claude again. After 20 s: fill the empty boxes
    /// with the ready-made text and notes (with their name). Claude's version replaces them if it
    /// comes in later, as long as nothing was sent yet.
    func watchFollowUp() {
        followUpWatchdog?.cancel()
        let who = calling
        let key = followUp?.key
        func stillEmpty(_ m: CoachModel) -> Bool {
            guard m.calling == who, let f = m.followUp, f.key == key else { return false }
            return f.text.isEmpty || f.linkedin.isEmpty || f.linkedinMessage.isEmpty
        }
        followUpWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, stillEmpty(self) else { return }
            if self.voicemailTask == nil, self.voicemailScript == nil, self.status == .ready {
                ActivityLog.problem("Follow-ups still writing for \(who ?? "?") after 12 s: asking Claude again")
                self.prepareVoicemail()
            }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, stillEmpty(self), var f = self.followUp else { return }
            let s = self.instantVoicemail(for: who)
            if f.text.isEmpty { f.text = s.textMessage }
            if f.linkedin.isEmpty { f.linkedin = s.linkedin }
            if f.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
            self.followUp = f
            ActivityLog.problem("Used the ready-made text and LinkedIn notes for \(who ?? "?"). Claude: \(self.lastVoicemailError ?? "no answer in 20 s")")
        }
    }

    /// Today's checklist for this person, from the 21-day plan: each step and whether it's done.
    func todaySteps(for key: String?) -> [(title: String, done: Bool)] {
        guard let key else { return [] }
        let p = DialHistory.person(key)
        guard let step = Cadence.step(for: key), p.pickups == 0 else { return [] }
        let dialsToday = p.dials.filter { Calendar.current.isDateInToday($0) }.count
        var steps: [(String, Bool)] = [("2 dials (\(min(dialsToday, 2)) of 2)", dialsToday >= 2)]
        if step.leaveVoicemail {
            steps.append(("Voicemail on the 2nd dial", p.voicemails.contains { Calendar.current.isDateInToday($0) }))
        }
        if step.textToday {
            let wa = followUp.map { Cadence.isWashington($0.phone) } ?? false
            if !wa { steps.append(("Text", DialHistory.textedToday(key))) }
        }
        if step.linkedInConnect {
            steps.append(("LinkedIn request", DialHistory.linkedInToday(key)))
            steps.append(("LinkedIn message", DialHistory.linkedInMessageToday(key)))
        }
        return steps
    }

    /// Today's 21-day plan step decides which follow-ups show: text only on the 2nd call day
    /// (never to Washington numbers), LinkedIn note on the 1st, LinkedIn message on the last.
    func applyPlan() {
        guard var f = followUp else { return }
        guard let key = f.key else {
            // Don't know who this is: show nothing rather than risk over-contacting.
            f.textDue = false; f.linkedInDue = false; followUp = f; return
        }
        let step = Cadence.step(for: key)
        let washington = Cadence.isWashington(f.phone)
        f.textDue = (step?.textToday ?? false) && !washington
        if washington, step?.textToday == true, !f.textDone { f.textStatus = "No text: Washington number (texts need consent there)." }
        f.linkedInDue = (step?.linkedInConnect ?? false) || (step?.linkedInMessage ?? false)
        f.linkedInMessageFirst = step?.linkedInMessage ?? false
        followUp = f
    }

    /// Fills in the text and LinkedIn note. The rep sends each one with a button.
    /// - Parameter replace: a better version (written from their Salesforce page) replaces
    ///   anything not sent yet.
    func fillFollowUp(from written: Suggestion, replace: Bool = false) {
        // Only into the card of the person this voicemail was written for.
        guard var f = followUp, f.key == nil || voicemailKey == nil || f.key == voicemailKey else { return }
        var s = written
        applyScriptMessages(&s, for: calling)
        if (f.text.isEmpty || (replace && !f.textDone && !f.textEdited)), !s.textMessage.isEmpty { f.text = s.textMessage }
        if (f.linkedin.isEmpty || (replace && !f.linkedinDone)), !s.linkedin.isEmpty { f.linkedin = s.linkedin }
        if (f.linkedinMessage.isEmpty || (replace && !f.linkedinMessageDone)), !s.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
        followUp = f
    }

    /// Sends the follow-up text through Aircall and checks it off.
    func sendFollowUpText() {
        guard let f = followUp, !f.text.isEmpty, !f.sending else { return }
        if let key = f.key, DialHistory.textedToday(key) {
            followUp?.textStatus = "Already texted today. Not sent again."
            followUp?.textDone = true
            return
        }
        if let key = f.key, DialHistory.alreadySent(f.text, to: key) {
            followUp?.textStatus = "You already sent them these exact words. Edit the text, or wait a moment for a new one."
            ActivityLog.add("Text blocked: same words as an earlier text to \(f.prospect ?? "?")")
            return
        }
        followUp?.textStatus = "Sending..."
        followUp?.sending = true
        Task { [weak self] in
            do {
                try await Aircall.sendText(to: f.phone, body: f.text)
                self?.touchpoints.log(.text)
                if let key = f.key { DialHistory.logText(key, body: f.text) }
                ActivityLog.add("Text sent to \(f.prospect ?? "?") at \(f.phone)")
                // Only mark the card it was sent from (not a newer person's card).
                guard self?.followUp?.key == f.key else { return }
                self?.followUp?.textStatus = nil
                self?.followUp?.sending = false
                self?.followUp?.textDone = true
            } catch {
                ActivityLog.problem("Text failed: \(error.localizedDescription)")
                guard self?.followUp?.key == f.key else { return }
                self?.followUp?.textStatus = error.localizedDescription
                self?.followUp?.sending = false
            }
        }
    }

    /// Opens their LinkedIn profile (from the Salesforce record), with the note already copied.
    /// Falls back to a name + company search only when the record has no LinkedIn link.
    /// - Parameter message: true = copy the direct message (already connected), false = the connection note.
    func openLinkedIn(message: Bool = false) {
        guard let f = followUp else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message ? f.linkedinMessage : f.linkedin, forType: .string)
        // The message only gets copied: the profile is already open from the note button.
        if message {
            if followUp?.linkedinMessageDone != true, !(f.key.map(DialHistory.linkedInMessageToday) ?? false) {
                touchpoints.log(.linkedinMessage)
                if let key = f.key { DialHistory.logLinkedInMessage(key, body: f.linkedinMessage) }
            }
            followUp?.linkedinMessageDone = true
            return
        }
        if let profile = f.linkedinURL ?? (leads.isActive ? nil : Self.linkedInProfile(details: recordDetails)) {
            NSWorkspace.shared.open(profile)
        } else {
            let query = [f.prospect, recordCompany].compactMap { $0 }.joined(separator: " ")
            if let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://www.linkedin.com/search/results/people/?keywords=\(q)") {
                NSWorkspace.shared.open(url)
            }
        }
        // Count once per person per day.
        if followUp?.linkedinDone != true, !(f.key.map(DialHistory.linkedInToday) ?? false) {
            touchpoints.log(.linkedin)
            if let key = f.key { DialHistory.logLinkedIn(key) }
        }
        followUp?.linkedinDone = true
    }

    /// The profile link from the record: the LinkedIn field's link on the page, or the URL in the page text.
    static func linkedInProfile(details: String?) -> URL? {
        var raw = SalesforceChrome.linkedInProfile()
        if raw == nil, let details,
           let r = details.range(of: #"linkedin\.com/in/[A-Za-z0-9\-_%]+"#, options: .regularExpression) {
            raw = "https://www." + details[r]
        }
        guard var link = raw else { return nil }
        if link.hasPrefix("http://") { link = "https://" + link.dropFirst("http://".count) }
        return URL(string: link)
    }

    /// Writes this prospect's voicemail in the background, so it's instant when needed.
    func prepareVoicemail() {
        voicemailTask?.cancel()
        voicemailScript = nil
        let forWho = calling
        let usedDetails = detailsTried
        lastVoicemailTry = Date()
        voicemailFor = forWho
        voicemailKey = recordKey()
        guard let key = Keychain.read(.anthropic) else { return }
        let client = CoachSpeed.fastest.client(apiKey: key) // voicemails always use Haiku: fast
        let system = self.system
        let user = CoachPrompt.voicemail(calling: calling, details: recordDetails,
                                         earlierTexts: recordKey().map(DialHistory.sentTexts) ?? [],
                                         earlierMessages: recordKey().map(DialHistory.sentLinkedInMessages) ?? [],
                                         history: recordKey().map(DialHistory.historySummary) ?? "")
        voicemailTask = Task { [weak self] in
            var text = ""
            do {
                try await client.stream(system: system, user: user) { text = $0 }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    ActivityLog.problem("Voicemail failed for \(forWho ?? "?"): \(error.localizedDescription)")
                    self?.lastVoicemailError = error.localizedDescription
                    // Let the next try (or the voicemail card) write it again.
                    if self?.calling == forWho { self?.voicemailTask = nil; self?.voicemailFor = nil }
                }
                return
            }
            var s = Suggestion.parse(text)
            s.sayComplete = true
            s.stage = "Voicemail"
            self?.applyScriptVoicemail(&s, for: forWho)
            if !Task.isCancelled, !s.say.isEmpty, self?.calling == forWho {
                ActivityLog.add("Voicemail ready for \(forWho ?? "?") (from page: \(usedDetails))")
                self?.voicemailUsedDetails = usedDetails
                self?.voicemailScript = s
                self?.fillFollowUp(from: s, replace: usedDetails) // the card is always up for the person on screen
            }
            if !Task.isCancelled { self?.voicemailTask = nil }
        }
    }

    /// The opener template filled in with their first name, your name and your company. No waiting.
    /// A ready-made voicemail, text and LinkedIn notes with their name, for when Claude
    /// can't write them in time. Still the right person, just not personalized.
    func instantVoicemail(for calling: String?) -> Suggestion {
        let first = Screener.firstName(calling) ?? "there"
        let rep = Prefs.repName
        let me = rep.isEmpty ? "[your name]" : rep
        var s = Suggestion()
        let key = recordKey()
        let texted = key.map { !DialHistory.person($0).texts.isEmpty } ?? false
        let leftBefore = key.map { !DialHistory.person($0).voicemails.isEmpty } ?? false
        let onLinkedIn = key.map { !DialHistory.person($0).linkedIns.isEmpty || !DialHistory.person($0).linkedInMessages.isEmpty } ?? false
        let linkedInLine = onLinkedIn ? " I also reached out on LinkedIn." : ""
        s.say = leftBefore
            ? "Hi \(first), \(me) from \(shortCompany) again. Still happy to share how teams like yours cut down on retyping info between systems.\(linkedInLine) \(texted ? "You have my number from my text." : "I'll text you my number.")"
            : "Hi \(first), this is \(me) with \(shortCompany). I help teams cut the time they spend retyping info between systems.\(linkedInLine) \(texted ? "I sent you a text earlier, so you have my number." : "I'll send you a quick text so you have my number.")"
        s.cue = "Ready-made voicemail (Claude didn't answer in time)."
        s.stage = "Voicemail"
        s.sayComplete = true
        // Plain and neutral on purpose: no pitch of their own, so they never clash with the campaign's tone.
        let texts = [
            "Hi \(first), \(me) with \(shortCompany). Just tried you and left a voicemail. I'll try you again tomorrow if I don't hear back.",
            "Hi \(first), \(me) again from \(shortCompany). Tried you once more today. Is now a busy season for you?",
            "\(first), \(me) at \(shortCompany). Still hoping to connect. Is there a better time of day to reach you?",
            "Hi \(first), \(me) from \(shortCompany). Should I keep trying you, or is now not a good time?",
            "\(first), last note from me (\(me), \(shortCompany)). I won't keep calling. Reach out anytime.",
        ]
        let sentBefore = recordKey().map { DialHistory.sentTexts($0).count } ?? 0
        s.textMessage = texts[sentBefore % texts.count]
        s.linkedin = "Hi \(first), I just tried calling you and left a voicemail. Would be glad to connect."
        let messages = [
            "Hi \(first), I just tried calling you and left a voicemail. Is there a good time to reach you this week?",
            "Hi \(first), following up on my call. Is there a better time of day to catch you?",
            "\(first), tried you again today. Happy to keep it short whenever works for you.",
            "Hi \(first), one more try. Worth a quick chat sometime, or not a fit right now?",
            "\(first), I'll stop reaching out after this. If timing changes, I'm happy to help.",
        ]
        let messagesBefore = recordKey().map { DialHistory.sentLinkedInMessages($0).count } ?? 0
        s.linkedinMessage = messages[messagesBefore % messages.count]
        applyScriptMessages(&s, for: calling)
        applyScriptVoicemail(&s, for: calling)
        return s
    }
}
