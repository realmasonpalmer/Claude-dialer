import AVFoundation
import Foundation
import Speech

/// Recognizes call screeners (Google Call Screen, iPhone Call Screening, carrier screeners) from what
/// they say in the first seconds of a call: "If you record your name and reason for calling, I'll
/// see if this person is available", "Thanks. Please stay on the line". A screened call is never
/// treated as voicemail: the app waits for the person.
///
/// Uses Apple's speech recognizer on this Mac (on-device when available); only the other side of
/// the call, only the first 25 seconds, nothing stored or sent anywhere.
@MainActor
final class ScreenerListener {
    static let shared = ScreenerListener()
    var onScreener: ((_ heard: String) -> Void)?
    var onVoicemailGreeting: ((_ heard: String) -> Void)?
    private var firedVoicemail = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var started: Date?
    private var fired = false
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Phrases screeners say and voicemail greetings don't.
    nonisolated static let phrases = [
        "record your name", "reason for calling", "see if this person is available", "see if they're available",
        "stay on the line", "please hold while", "screening", "google assistant", "the person you're calling is using",
        "say your name", "state your name", "who's calling", "what are you calling about", "call screening",
    ]

    /// Voicemail greetings (said before the beep; screeners don't say these).
    nonisolated static let voicemailPhrases = [
        "leave a message", "leave your message", "after the tone", "after the beep", "not available",
        "unavailable", "voicemail", "voice mail", "mailbox", "record your message", "at the tone",
    ]

    nonisolated static func isVoicemailGreeting(_ text: String) -> Bool {
        let t = text.lowercased()
        return !isScreener(t) && voicemailPhrases.contains { t.contains($0) }
    }

    nonisolated static func isScreener(_ text: String) -> Bool {
        let t = text.lowercased()
        return phrases.contains { t.contains($0) }
    }

    nonisolated static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    func askPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in Log.add("screener", "speech recognition permission: \(status.rawValue == 3 ? "allowed" : "not allowed (\(status.rawValue))")") }
        }
    }

    /// A new call's audio started.
    func begin() {
        end()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        started = Date()
        fired = false
        firedVoicemail = false
        task = recognizer.recognitionTask(with: req) { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in ScreenerListener.shared.heard(text) }
        }
    }

    /// 16 kHz mono 16-bit samples of the other side.
    func feed(_ pcm16: Data) {
        guard let request, let started else { return }
        if Date().timeIntervalSince(started) > 25 { return end() }
        let n = pcm16.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<n { dst[i] = Float(src[i]) / 32768 }
        }
        request.append(buf)
    }

    func end() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        started = nil
    }

    private func heard(_ text: String) {
        if !firedVoicemail, !fired, Self.isVoicemailGreeting(text) {
            firedVoicemail = true
            Log.add("screener", "voicemail greeting: \"\(text.suffix(120))\"")
            onVoicemailGreeting?(text)
        }
        guard !fired, Self.isScreener(text) else { return }
        fired = true
        Log.add("screener", "call screener: \"\(text.suffix(120))\"")
        onScreener?(text)
    }
}
