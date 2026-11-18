import AppKit
import CoachCore
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
        final class Ref: @unchecked Sendable { weak var stream: DeepgramStream? }
        let ref = Ref()
        let stream = DeepgramStream(apiKey: key, keyterms: useKeyterms ? DeepgramStream.defaultKeyterms : []) { [weak self] event in
            // When the words were spoken, on the wall clock both sides share (not when the text arrived).
            var spoken: (start: Date, end: Date)?
            if case .transcript(_, _, _, let start, let duration, _) = event, start > 0 || duration > 0,
               let s = ref.stream?.wallTime(audioSeconds: start) {
                spoken = (s, s.addingTimeInterval(duration))
            }
            Task { @MainActor in self?.handle(event, from: speaker, spoken: spoken) }
        }
        ref.stream = stream
        return stream
    }

    func handle(_ event: DeepgramStream.Event, from speaker: Speaker, spoken: (start: Date, end: Date)? = nil) {
        guard status == .live else { return }
        switch event {
        case .transcript(let text, let isFinal, let speechFinal, let audioStart, let audioDuration, let confidence):
            if !text.isEmpty {
                CallTrace.event(isFinal ? "transcript.final" : "transcript.partial", [
                    "speaker": speaker == .rep ? "rep" : "prospect", "text": text, "speech_final": speechFinal,
                    "audio_start": audioStart, "audio_end": audioStart + audioDuration, "confidence": confidence])
            }
            if speechFinal { CallTrace.event("turn.end", ["speaker": speaker == .rep ? "rep" : "prospect", "by": "speech_final"]) }
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
                          Voicemail.unavailableAfterScreen(recent) || Voicemail.numberCantTakeCall(recent) {
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
            if !text.isEmpty {
                let wasSpeaking = speaker == .rep ? repSpeaking : prospectSpeaking
                if !wasSpeaking {
                    ActivityLog.add("Speech start (\(speaker == .rep ? "Rep" : "Them"), transcript arrival)")
                    CallTrace.event("speech.start", ["speaker": speaker == .rep ? "rep" : "prospect",
                                                     "overlap": speaker == .rep ? prospectSpeaking : repSpeaking])
                }
                if speaker == .rep { lastRepSpeechAt = Date() } else { lastProspectSpeechAt = Date() }
                // Audio timeline: classify the turn from when words were spoken. No timestamps (rare):
                // fall back to arrival time, a short range ending now.
                let side: SpeechTimeline.Side = speaker == .rep ? .rep : .prospect
                let end = spoken?.end ?? Date()
                let start = spoken?.start ?? end.addingTimeInterval(-0.3)
                if let kind = timeline.update(side, start: start.timeIntervalSinceReferenceDate, end: end.timeIntervalSinceReferenceDate,
                                              text: text, isFinal: isFinal) {
                    CallTrace.event("turn.classified", ["speaker": side.rawValue, "kind": kind.rawValue, "text": text,
                                                        "spoken_start_ms": Int(start.timeIntervalSince1970 * 1000),
                                                        "spoken_end_ms": Int(end.timeIntervalSince1970 * 1000),
                                                        "lag_ms": Int(Date().timeIntervalSince(end) * 1000),
                                                        "timestamps": spoken == nil ? "arrival (fallback)" : "audio",
                                                        "final": isFinal])
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
            CallTrace.event("turn.end", ["speaker": speaker == .rep ? "rep" : "prospect", "by": "utterance_end"])
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
        defer { if speaker == .rep { prepareWhileRepTalks(text); prepareYesBranch(text) } } // runs after the turn is recorded
        if speaker == .rep {
            let count = text.split(separator: " ").count
            repWordsSinceShown += count
            repWordsInCall += count
            lastRepFinal = text
            lastRepFinalAt = Date()
        }
        if speaker == .prospect, firstProspectAt == nil { firstProspectAt = Date() }
        ActivityLog.add("Heard \(speaker == .rep ? "Rep" : "Them") (final): \(text)")
        if speaker == .rep, pending != nil, text.contains("?") { repAskedSinceQueue = true }
        if speaker == .rep, status == .live, !suggestion.say.isEmpty {
            repSaidSinceShown += " " + text
            if !lineDelivered, Delivery.delivered(line: suggestion.say, spoken: repSaidSinceShown) {
                lineDelivered = true
                let conf = Delivery.confidence(line: suggestion.say, spoken: repSaidSinceShown)
                ActivityLog.add(String(format: "Coach: line delivered (meaning %.0f%% said)", conf * 100))
                let ev = Delivery.evidence(line: suggestion.say, spoken: repSaidSinceShown)
                CallTrace.event("delivery", ["line": suggestion.say, "said": repSaidSinceShown, "confidence": conf,
                                             "rule": Delivery.rule(line: suggestion.say, spoken: repSaidSinceShown) ?? "none",
                                             "matched_words": ev.matched, "missing_words": ev.missing,
                                             "how": "overall: half the line's key words said; question: 60% of its question's key words"], sug: shownID)
            }
        }
        if speaker == .prospect, lineDelivered, !answeredAfterDelivery {
            answeredAfterDelivery = true
            ActivityLog.add("Coach: they answered the delivered line (resolved)")
            CallTrace.event("resolution", ["answer": text, "how": "prospect spoke after the line was delivered"], sug: shownID)
        }
        if speaker == .prospect { lastHeardThemAt = Date() }
        if turns.last?.speaker != speaker { CallTrace.turn += 1 }
        // Cut off = this side really came in over the other in audio time (not just answered quickly).
        let kindNow = timeline.segments[speaker == .rep ? .rep : .prospect]?.last?.kind
        let overlapped = kindNow == .interruption || kindNow == .overlap
        for change in questionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, overlapped: overlapped) {
            switch change {
            case .asked(let q): CallTrace.event("question.asked", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
            case .answered(let q): CallTrace.event("question.answered", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "answer": q.answer])
            case .interrupted(let q): CallTrace.event("question.interrupted", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "cut_off_by": text])
            case .abandoned(let q): CallTrace.event("question.abandoned", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
            }
        }
        CoachPrompt.questionFacts = questionTracker.promptText // current before the next prompt is built
        for c in objectionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, turn: CallTrace.turn) {
            let o = c.objection
            CallTrace.event("objection.\(o.status.rawValue)", [
                "id": o.id, "kind": o.kind, "from": c.from?.rawValue ?? "none", "to": o.status.rawValue, "why": c.why,
                "raised": ["turn": o.raisedTurn, "text": o.raisedText],
                "addressed": ["turn": o.addressedTurn, "text": o.addressedText],
                "evidence": ["turn": o.evidenceTurn, "text": o.evidenceText]])
            ActivityLog.add("Objection \(o.kind): \(c.from?.rawValue ?? "new") -> \(o.status.rawValue)")
        }
        CoachPrompt.objectionFacts = objectionTracker.promptText
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
