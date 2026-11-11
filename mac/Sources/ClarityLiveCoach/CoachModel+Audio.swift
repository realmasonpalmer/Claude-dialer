import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Listening: audio capture, the two transcription streams, and what each word means.
extension CoachModel {
    func startAudio() -> Bool {
        pendingStop?.cancel() // a new call: keep the old tap from being removed later
        pendingStop = nil
        guard let deepgramKey = Keychain.read(.deepgram) else {
            problem = "Add your Deepgram key: gear > Setup > AI keys."
            return false
        }
        streams.set(rep: openStream(.rep, key: deepgramKey), prospect: openStream(.prospect, key: deepgramKey))

        // The Aircall phone inside the coach hands over the call audio itself: no Core Audio tap,
        // so nothing glitches (like the hang-up tone). If it doesn't within 4 s, use the tap.
        if AircallPhone.isOn {
            let streams = self.streams
            let phone = AircallPhone.shared
            phone.onAudio = { isRep, pcm in streams.send(pcm, isRep: isRep) }
            directAudio = true
            ActivityLog.add("Listening straight from the Aircall phone")
            let startedAt = Date()
            directCheck?.cancel()
            directCheck = Task { [weak self] in
                // Check at 4 s and again at 8 s: the other side must have real sound by then
                // (ringback or a voicemail greeting), or the phone isn't sharing the call: use the tap.
                for checkAt in [4.0, 8.0] {
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
                    if phone.lastRemoteAudio > startedAt { break }
                    if checkAt < 8 { continue }
                    phone.onAudio = nil
                    self.directAudio = false
                    ActivityLog.problem("No sound from the Aircall phone after 8 s; using the audio tap")
                    if !self.startTap() { self.stopAudio() }
                    return
                }
                guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
                if phone.lastLocalAudio < startedAt {
                    // The other side comes through, the rep's mic doesn't: add the Mac's mic.
                    phone.onAudio = { isRep, pcm in if !isRep { streams.send(pcm, isRep: false) } }
                    do {
                        try self.capture.startMicOnly { isRep, speech in
                            guard let samples = speech.int16ChannelData?[0] else { return }
                            streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: true)
                        }
                        ActivityLog.add("Rep's side: Mac mic (the phone didn't share it)")
                    } catch {
                        ActivityLog.problem("Mic failed: \(error.localizedDescription)")
                    }
                } else {
                    ActivityLog.add("Hearing both sides straight from the Aircall phone")
                }
            }
            return true
        }
        return startTap()
    }

    /// The old way: a Core Audio tap on the call app's sound, plus the mic.
    func startTap() -> Bool {
        let chrome = AudioProcess.callAudioTargets(in: AudioProcess.others())
        guard !chrome.isEmpty else {
            callMessage = "Can't hear the call yet. Open the Aircall app (or Aircall in Chrome) and start the call."
            ActivityLog.problem("Listening failed: no Aircall or Chrome audio found")
            return false
        }
        do {
            let streams = self.streams
            try capture.start(processes: chrome) { isRep, speech in
                guard let samples = speech.int16ChannelData?[0] else { return }
                streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: isRep)
            }
            ActivityLog.add("Listening to: \(Self.names(of: chrome))")
            return true
        } catch {
            streams.closeAll()
            callMessage = "The coach couldn't start listening: \(error.localizedDescription). The call still works; coaching is off for it."
            ActivityLog.problem("Listening failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Process names for the log.
    static func names(of ids: [AudioObjectID]) -> String {
        let all = AudioProcess.others()
        let names = ids.compactMap { id in all.first { $0.id == id }?.name }
        return names.isEmpty ? "\(ids.count) process(es)" : Set(names).sorted().joined(separator: ", ")
    }

    /// Listening starts a second after dialing, sometimes before Aircall's call audio exists.
    /// Once Aircall is clearly on the call, make sure that's what the app listens to.
    func followCallAudio() {
        guard !directAudio else { return } // the phone hands over its audio itself
        let processes = AudioProcess.others()
        guard AudioProcess.aircallAppOnCall(in: processes) || AudioProcess.chromeOnCall(in: processes) else { return }
        let targets = AudioProcess.callAudioTargets(in: processes)
        // Only add missing call audio (never drop what's working), and at most twice a call.
        guard retargets < 2, !targets.isEmpty, !Set(targets).isSubset(of: Set(capture.tapTargets)) else { return }
        retargets += 1
        do {
            try capture.retargetTap(processes: targets)
            ActivityLog.add("Switched listening to: \(Self.names(of: targets))")
        } catch {
            ActivityLog.add("Couldn't switch listening: \(error.localizedDescription)")
        }
    }

    /// Stops listening. Transcription stops right away, but the audio tap is removed a few
    /// seconds later: tearing it down while Aircall plays the hang-up tone makes that tone
    /// stutter and repeat.
    func stopAudio() {
        AircallPhone.shared.onAudio = nil
        directCheck?.cancel()
        directAudio = false
        streams.closeAll()
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.pendingStop = nil
            self.capture.stop()
        }
    }

    /// One line about what the app is doing, for bug reports.
    func debugSummary() -> String {
        "status=\(status) person=\(calling ?? "none") page=\(SalesforceTab.currentRecord() ?? "none") " +
        "waitingFor=\(gettingReady == nil ? "-" : waitingFor()) voicemailFor=\(voicemailFor ?? "none") " +
        "followUp=\(followUp?.prospect ?? "none") autoDial=\(autoDial) attempts=\(currentAttempts) " +
        "salesforce=\(Salesforce.isConnected) aircall=\(Aircall.canPlaceCalls)"
    }

    func openStream(_ speaker: Speaker, key: String) -> DeepgramStream {
        DeepgramStream(apiKey: key, keyterms: useKeyterms ? DeepgramStream.defaultKeyterms : []) { [weak self] event in
            Task { @MainActor in self?.handle(event, from: speaker) }
        }
    }

    func handle(_ event: DeepgramStream.Event, from speaker: Speaker) {
        guard status == .live else { return }
        switch event {
        case .transcript(let text, let isFinal, let speechFinal):
            if speaker == .prospect {
                // Check the recent words together, so a phrase split across chunks still matches.
                let recent = String(((turns.last { $0.speaker == .prospect }?.text ?? "") + " " + text).suffix(400))
                let early = repWordsInCall < 3 && Date().timeIntervalSince(firstProspectAt ?? Date()) < 15
                let firstWords = turns.contains { $0.speaker == .rep } ? "" : (prospectSoFar + " " + text)
                if BadNumber.detects(recent) {
                    if !badNumberThisCall { markBadNumber() }
                } else if phoneTreeActive {
                    // In a phone menu: no voicemail card, no auto hang-up. Only a real mailbox ends it.
                    if Voicemail.recordingPrompt(recent) {
                        phoneTreeActive = false
                        phoneTreeTask?.cancel()
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                } else if !badNumberThisCall, !phoneTreeThisCall, repWordsInCall < 5,
                          !Voicemail.recordingPrompt(recent), PhoneTree.detects(prospectSoFar + " " + text) {
                    // Work through it by default. Old behavior (disqualify + hang up) behind a setting.
                    if Prefs.hangUpPhoneTrees { markPhoneTree() } else { enterPhoneTree() }
                } else if !voicemailActive, screenerActive || stagesSeen.contains("Screener") || Screener.detects(prospectSoFar),
                          Voicemail.unavailableAfterScreen(recent) {
                    // The call screener says they won't take it: same as no answer. Hang up (redial on the
                    // 1st try, next person on a no-voicemail day). A voicemail day's last try waits for the beep.
                    ActivityLog.add("Screener said not available for \(calling ?? "?")")
                    showVoicemail(mailboxFull: false)
                    autoHangUpForRedial(why: "screener said not available")
                } else if Voicemail.detects(recent, earlyInCall: early)
                    || (!screenerActive && !Screener.detects(firstWords) && Voicemail.longGreeting(firstWords, earlyInCall: early)) {
                    if !voicemailActive || (Voicemail.mailboxFull(recent) && !mailboxFullShown) {
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                    // Surely a recording, and the rep hasn't started talking: hang up now, before the beep
                    // (redial on the 1st try; on to the next person on a no-voicemail day's last try).
                    if repWordsInCall < 3, !screenerActive, !autoHungUpThisCall,
                       let why = Voicemail.hangUpReason(recent, firstWords: firstWords, earlyInCall: early) {
                        autoHangUpForRedial(why: why)
                    }
                } else if !voicemailActive, !screenerActive, !stagesSeen.contains("Screener"), Screener.detects(recent) {
                    showScreenerLine()
                }
            }
            if isFinal {
                reconnects = 0
                interim[speaker] = nil
                if !text.isEmpty { addFinal(text, from: speaker) }
                if speechFinal && speaker == .prospect { prospectFinished() }
            } else {
                interim[speaker] = text
                if speaker == .prospect { scheduleEarlyStart() }
            }
        case .utteranceEnd:
            if speaker == .prospect { prospectFinished() }
        case .failed(let message):
            // Keep the call and the last tip; just reconnect this side.
            guard reconnects < 3, let key = Keychain.read(.deepgram) else {
                problem = "Transcription stopped: \(message)"
                return
            }
            reconnects += 1
            useKeyterms = false // reconnect with the plainest settings
            streams.replace(speaker, with: openStream(speaker, key: key))
        }
    }

    /// The rep clicked "Voicemail": the app missed it, so show the message now.
    func markVoicemail() {
        guard status == .live, !voicemailActive else { return }
        showVoicemail(mailboxFull: false)
    }

    func addFinal(_ text: String, from speaker: Speaker) {
        lastWordsAt = Date()
        defer { scheduleStillWithMe() }
        if speaker == .rep {
            let count = text.split(separator: " ").count
            repWordsSinceShown += count
            repWordsInCall += count
        }
        if speaker == .prospect, firstProspectAt == nil { firstProspectAt = Date() }
        if let last = turns.last, last.speaker == speaker {
            turns[turns.count - 1].text += " " + text
        } else {
            turns.append(Turn(speaker: speaker, text: text))
        }
        if speaker == .prospect {
            uncoached += (uncoached.isEmpty ? "" : " ") + text
        }
    }
}
