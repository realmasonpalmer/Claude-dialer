import Foundation

/// Hears the voicemail beep: one pure tone (400 to 2,000 Hz) lasting 0.15 to 1.5 seconds.
/// Speech never looks like that (many pitches, always changing). Fed the prospect's side
/// (16 kHz, 16-bit mono) in 20 ms slices. Thread-safe.
final class BeepDetector: @unchecked Sendable {
    static let shared = BeepDetector()

    private let lock = NSLock()
    private var buffer: [Float] = []
    private var toneFrames = 0
    private var toneFreq = 0.0
    private var _lastBeepEnd: Date?
    private var _lastBeepFreq = 0.0
    private var _lastSoundAt: Date?
    private var _lastFrameAt: Date?
    private var _voicedFrames = 0
    private var noiseFloor = 1e-3
    private var tuning = VMTuning.current

    private let rate = 16_000.0
    private let frame = 320 // 20 ms
    private let freqs: [Double] = stride(from: 400.0, through: 2_000.0, by: 25.0).map { $0 }

    /// When the latest beep finished, if one was heard.
    var lastBeepEnd: Date? { lock.lock(); defer { lock.unlock() }; return _lastBeepEnd }

    /// The pitch of the last beep, for the log.
    var lastBeepFreq: Double { lock.lock(); defer { lock.unlock() }; return _lastBeepFreq }
    /// Last time the other side made real sound (a voice, music), from the audio itself, not the transcript.
    var lastSoundAt: Date? { lock.lock(); defer { lock.unlock() }; return _lastSoundAt }
    /// Seconds of real sound heard since the call started.
    var voicedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(_voicedFrames) * 0.02 }
    /// Audio is arriving right now (a slice in the last second).
    var hearing: Bool { lock.lock(); defer { lock.unlock() }; return _lastFrameAt.map { Date().timeIntervalSince($0) < 1 } ?? false }

    /// A new call: forget the last call's beep and sound.
    func reset() {
        lock.lock()
        buffer = []; toneFrames = 0; _lastBeepEnd = nil; _lastSoundAt = nil; _lastFrameAt = nil; _voicedFrames = 0
        noiseFloor = 1e-3
        tuning = VMTuning.current // the latest tuned settings, each call
        lock.unlock()
    }

    func feed(_ pcm16: Data) {
        lock.lock(); defer { lock.unlock() }
        pcm16.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { buffer.append(Float(s) / 32768) }
        }
        while buffer.count >= frame {
            let chunk = Array(buffer.prefix(frame))
            buffer.removeFirst(frame)
            step(chunk)
        }
    }

    private func step(_ x: [Float]) {
        _lastFrameAt = Date()
        let p = tuning
        let m = SliceMeter.measure(x[...])
        // The line's own hiss, learned per call: drops to the quietest slice fast, creeps up slowly.
        if m.level < noiseFloor { noiseFloor = max(m.level, 1e-9) } else { noiseFloor *= 1.003 }
        let isTone = m.ratio > p.toneRatio
        if !isTone, m.level > max(noiseFloor * p.voiceFactor, 2e-6) { _lastSoundAt = Date(); _voicedFrames += 1 } // a voice, not hiss or the beep
        if isTone, toneFrames == 0 || abs(m.freq - toneFreq) <= 75 {
            if toneFrames == 0 { toneFreq = m.freq }
            toneFrames += 1
        } else {
            if (p.minToneFrames...75).contains(toneFrames) { _lastBeepEnd = Date(); _lastBeepFreq = toneFreq }
            toneFrames = isTone ? 1 : 0
            toneFreq = m.freq
        }
    }
}
