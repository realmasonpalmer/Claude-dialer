import AVFoundation
import Foundation
import Speech

/// Writes down both sides of the call as it happens ("Rep: ..." / "Them: ..." lines), so the
/// Help me button can hand the whole conversation to the coach.
///
/// Uses Apple's speech recognizer on this Mac (on-device when available), one recognizer per
/// side. Kept in memory for the current call only; nothing is saved. Words go to Claude only
/// when the rep presses Help me.
@MainActor
final class LiveTranscript {
    static let shared = LiveTranscript()

    enum Side: String { case rep = "Rep", them = "Them" }

    struct Line {
        let side: Side
        let at: Date
        var text: String
    }

    /// Finished lines, in the order they were said.
    private(set) var lines: [Line] = []
    private var sides: [Side: Listener] = [:]
    private var ticker: Timer?

    /// A new call: forget the last one.
    func reset() {
        stop()
        lines = []
    }

    /// Stop listening (the call ended). Lines are kept until the next call.
    func stop() {
        for l in sides.values { l.stop() }
        sides = [:]
        ticker?.invalidate()
        ticker = nil
    }

    /// One side's audio started.
    func begin(_ side: Side) {
        sides[side]?.stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        let l = Listener(side: side) { [weak self] line in self?.lines.append(line) }
        sides[side] = l
        l.start()
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                Task { @MainActor in LiveTranscript.shared.tick() }
            }
        }
    }

    /// 16 kHz mono 16-bit samples of one side.
    func feed(_ pcm16: Data, from side: Side) {
        sides[side]?.feed(pcm16)
    }

    private func tick() {
        for l in sides.values { l.tick() }
    }

    /// The whole call so far as "Rep: ..." / "Them: ..." lines, including words still coming in.
    /// Back-to-back lines from the same side are joined.
    var text: String {
        var all = lines
        for l in sides.values { if let p = l.pending { all.append(p) } }
        all.sort { $0.at < $1.at }
        var merged: [Line] = []
        for l in all {
            if let last = merged.last, last.side == l.side { merged[merged.count - 1].text += " " + l.text } else { merged.append(l) }
        }
        return merged.map { "\($0.side.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    /// Listens to one side. Splits what it hears into lines at pauses, and starts a fresh
    /// recognizer every 50 seconds (Apple's recognizer is made for short requests).
    @MainActor
    private final class Listener {
        let side: Side
        private let commit: (Line) -> Void
        private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var task: SFSpeechRecognitionTask?
        private var startedAt = Date()
        private var generation = 0
        private var stopped = false
        /// Words in the current recognizer's result, and how many are already in a line.
        private var words: [String] = []
        private var committed = 0
        private var pendingAt: Date?
        private var changedAt = Date.distantPast
        private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

        init(side: Side, commit: @escaping (Line) -> Void) {
            self.side = side
            self.commit = commit
        }

        /// Words heard but not yet in a line (the person is still talking).
        var pending: Line? {
            guard committed < words.count, let at = pendingAt else { return nil }
            return Line(side: side, at: at, text: words[committed...].joined(separator: " "))
        }

        func start() {
            guard !stopped, let recognizer, recognizer.isAvailable else { return }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            startedAt = Date()
            words = []
            committed = 0
            generation += 1
            let gen = generation
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in self?.heard(text, done: done, gen: gen) }
            }
        }

        func feed(_ pcm16: Data) {
            guard !stopped else { return }
            if request == nil {
                // The last recognizer stopped by itself: start a new one (at most every 2 s).
                guard Date().timeIntervalSince(startedAt) > 2 else { return }
                start()
            } else if Date().timeIntervalSince(startedAt) > 50 {
                restart()
            }
            guard let request else { return }
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

        /// A pause of about a second ends a line.
        func tick() {
            if pendingAt != nil, Date().timeIntervalSince(changedAt) > 0.9 { flush() }
        }

        func stop() {
            flush()
            stopped = true
            end()
        }

        private func heard(_ text: String?, done: Bool, gen: Int) {
            guard gen == generation, !stopped else { return }
            if let text {
                let w = text.split(whereSeparator: \.isWhitespace).map(String.init)
                if w != words {
                    words = w
                    committed = min(committed, w.count)
                    if committed < w.count {
                        if pendingAt == nil { pendingAt = Date() }
                        changedAt = Date()
                    }
                }
            }
            // The recognizer gave up or finished (long silence, an error): the next audio starts a new one.
            if done {
                flush()
                end()
            }
        }

        private func flush() {
            if let p = pending { commit(p) }
            committed = words.count
            pendingAt = nil
        }

        private func restart() {
            flush()
            end()
            start()
        }

        private func end() {
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
        }
    }
}
