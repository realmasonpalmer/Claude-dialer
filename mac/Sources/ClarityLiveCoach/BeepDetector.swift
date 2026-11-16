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

    private let rate = 16_000.0
    private let frame = 320 // 20 ms
    private let freqs: [Double] = stride(from: 400.0, through: 2_000.0, by: 25.0).map { $0 }

    /// When the latest beep finished, if one was heard.
    var lastBeepEnd: Date? { lock.lock(); defer { lock.unlock() }; return _lastBeepEnd }

    func reset() { lock.lock(); buffer = []; toneFrames = 0; _lastBeepEnd = nil; lock.unlock() }

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
        var energy = 0.0
        for v in x { energy += Double(v * v) }
        var isTone = false
        var peakFreq = 0.0
        if energy / Double(frame) > 1e-5 { // not silence
            var best = 0.0
            for f in freqs { // Goertzel: how much of the sound sits at this one pitch
                let k = 2 * cos(2 * Double.pi * f / rate)
                var s1 = 0.0, s2 = 0.0
                for v in x { let s0 = Double(v) + k * s1 - s2; s2 = s1; s1 = s0 }
                let p = s1 * s1 + s2 * s2 - k * s1 * s2
                if p > best { best = p; peakFreq = f }
            }
            isTone = best / (energy * Double(frame) / 2) > 0.6 // most of the sound is one pitch
        }
        if isTone, toneFrames == 0 || abs(peakFreq - toneFreq) <= 75 {
            if toneFrames == 0 { toneFreq = peakFreq }
            toneFrames += 1
        } else {
            if (8...75).contains(toneFrames) { _lastBeepEnd = Date() } // 0.16 to 1.5 s: a beep
            toneFrames = isTone ? 1 : 0
            toneFreq = peakFreq
        }
    }
}
