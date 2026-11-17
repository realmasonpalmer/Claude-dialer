import Foundation

/// The voicemail drop's timing settings. Start with safe defaults; the app tunes them itself
/// every 20 voicemails by replaying the saved greetings (see VoicemailTuner).
struct VMTuning: Codable, Equatable {
    var toneRatio = 0.45        // how much of a slice must be one pitch to count as a beep
    var minToneFrames = 6       // shortest beep, in 20 ms slices
    var voiceFactor = 8.0       // how far above the line's hiss counts as a voice
    var quietWithEnding = 3.0   // silence needed after ending words ("after the tone")
    var quietNoEnding = 4.5     // silence needed without them
    var afterBeep = 0.5         // wait after the beep ends

    private static let key = "vmTuning"
    static var current: VMTuning {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(VMTuning.self, from: $0) } ?? VMTuning() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    var summary: String {
        String(format: "beep %.2f/%d slices, voice x%.0f, quiet %.1f s (ending words) or %.1f s, %.1f s after beep",
               toneRatio, minToneFrames, voiceFactor, quietWithEnding, quietNoEnding, afterBeep)
    }
}

/// One 20 ms slice of audio, measured once: how loud, and how much of it is one pitch.
struct SliceStats { let level: Double; let ratio: Double; let freq: Double }

enum SliceMeter {
    static let rate = 16_000.0
    static let frame = 320
    private static let freqs: [Double] = stride(from: 400.0, through: 2_000.0, by: 25.0).map { $0 }

    static func measure(_ x: ArraySlice<Float>) -> SliceStats {
        var energy = 0.0
        for v in x { energy += Double(v * v) }
        let level = energy / Double(frame)
        guard level > 1e-5 else { return SliceStats(level: level, ratio: 0, freq: 0) }
        var best = 0.0, peak = 0.0
        for f in freqs { // Goertzel: how much of the sound sits at this one pitch
            let k = 2 * cos(2 * Double.pi * f / rate)
            var s1 = 0.0, s2 = 0.0
            for v in x { let s0 = Double(v) + k * s1 - s2; s2 = s1; s1 = s0 }
            let p = s1 * s1 + s2 * s2 - k * s1 * s2
            if p > best { best = p; peak = f }
        }
        return SliceStats(level: level, ratio: best / (energy * Double(frame) / 2), freq: peak)
    }
}

/// Saves the other side of the line from just before a voicemail is spotted until a few seconds
/// after the drop: the greeting and the beep only, never a conversation. Up to 50 kept, oldest removed.
final class VoicemailSamples: @unchecked Sendable {
    static let shared = VoicemailSamples()
    static let keep = 50
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clarity Live Coach/Voicemail samples", isDirectory: true)
    }()

    struct Meta: Codable {
        var date: Date
        var detectedAt: Double   // seconds into the sample when the voicemail was spotted
        var droppedAt: Double?   // seconds into the sample when the drop was clicked
        var how: String
        var transcript: String
    }

    private let lock = NSLock()
    private var preRoll = Data()       // the last 12 s, always
    private var recording: Data?
    private var detectedOffset = 0.0
    private var startedAt = Date()
    private let bytesPerSecond = 32_000

    func feed(_ pcm: Data) {
        lock.lock(); defer { lock.unlock() }
        if recording != nil {
            if recording!.count < bytesPerSecond * 75 { recording!.append(pcm) }
        } else {
            preRoll.append(pcm)
            if preRoll.count > bytesPerSecond * 12 { preRoll.removeFirst(preRoll.count - bytesPerSecond * 12) }
        }
    }

    /// The voicemail was just spotted.
    func start() {
        lock.lock(); defer { lock.unlock() }
        recording = preRoll
        detectedOffset = Double(preRoll.count) / Double(bytesPerSecond)
        startedAt = Date()
    }

    /// Seconds into the sample right now.
    var now: Double {
        lock.lock(); defer { lock.unlock() }
        return detectedOffset + Date().timeIntervalSince(startedAt)
    }

    /// Stops and saves. Returns how many samples have been saved in all.
    @discardableResult
    func finish(droppedAt: Double?, how: String, transcript: String) -> Int {
        lock.lock()
        let pcm = recording
        recording = nil
        preRoll = Data()
        let offset = detectedOffset
        lock.unlock()
        guard let pcm, pcm.count > bytesPerSecond * 2 else { return 0 }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = f.string(from: Date())
        try? Self.wav(pcm).write(to: Self.folder.appendingPathComponent(name + ".wav"))
        let meta = Meta(date: Date(), detectedAt: offset, droppedAt: droppedAt, how: how, transcript: transcript)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? enc.encode(meta).write(to: Self.folder.appendingPathComponent(name + ".json"))
        // Keep the newest 50.
        let wavs = ((try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in wavs.dropLast(Self.keep) {
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: old.deletingPathExtension().appendingPathExtension("json"))
        }
        let total = UserDefaults.standard.integer(forKey: "vmSamplesTotal") + 1
        UserDefaults.standard.set(total, forKey: "vmSamplesTotal")
        return total
    }

    private static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// Reads a saved sample's audio back as floats.
    static func samples(_ url: URL) -> [Float] {
        guard let d = try? Data(contentsOf: url), d.count > 44 else { return [] }
        return d.dropFirst(44).withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
    }
}

/// Every 20 voicemails: replays the saved greetings, finds where each beep (or the end of the
/// greeting) really was, and picks the settings that would have dropped right after it: never early
/// first, then as soon as possible. Applies them only if they beat the current ones.
enum VoicemailTuner {
    struct Result { let samples: Int; let earlyBefore: Int; let earlyAfter: Int; let waitBefore: Double; let waitAfter: Double; let applied: Bool; let tuning: VMTuning }

    static func run() async -> Result? {
        await Task.detached(priority: .utility) { tune() }.value
    }

    private static func tune() -> Result? {
        let fm = FileManager.default
        let wavs = ((try? fm.contentsOfDirectory(at: VoicemailSamples.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var cases: [(stats: [SliceStats], detected: Double, ending: Bool)] = []
        for w in wavs {
            let x = VoicemailSamples.samples(w)
            guard x.count > SliceMeter.frame * 50 else { continue }
            let meta = (try? Data(contentsOf: w.deletingPathExtension().appendingPathExtension("json")))
                .flatMap { try? dec.decode(VoicemailSamples.Meta.self, from: $0) }
            var stats: [SliceStats] = []
            var i = 0
            while i + SliceMeter.frame <= x.count { stats.append(SliceMeter.measure(x[i..<(i + SliceMeter.frame)])); i += SliceMeter.frame }
            let t = (meta?.transcript ?? "").lowercased()
            let ending = ["message", "tone", "beep", "record", "options", "after the"].contains { t.contains($0) }
            cases.append((stats, meta?.detectedAt ?? 0, ending))
        }
        guard cases.count >= 10 else { return nil }

        // Where the drop should have happened, using the whole recording (hindsight).
        func truth(_ s: [SliceStats]) -> Double? {
            let floor = noiseFloors(s)
            var lastVoice = -1, voiced = 0
            var tone = 0, toneFreq = 0.0
            var beepEnds: [Int] = []
            for (i, f) in s.enumerated() {
                let isTone = f.ratio > 0.35
                if !isTone, f.level > max(floor[i] * 8, 2e-6) { lastVoice = i; voiced += 1 }
                if isTone, tone == 0 || abs(f.freq - toneFreq) <= 75 { if tone == 0 { toneFreq = f.freq }; tone += 1 }
                else { if (5...100).contains(tone), voiced >= 100 { beepEnds.append(i) }; tone = isTone ? 1 : 0; toneFreq = f.freq }
            }
            // The last beep with no voice after it.
            if let b = beepEnds.last(where: { b in lastVoice < b }) { return Double(b) * 0.02 }
            // No beep: the start of the long silence after the greeting.
            return voiced >= 100 && lastVoice < s.count - 100 ? Double(lastVoice + 1) * 0.02 : nil
        }

        // When the live rules (with these settings) would have dropped.
        func simulate(_ s: [SliceStats], detected: Double, ending: Bool, _ p: VMTuning) -> Double? {
            let floor = noiseFloors(s)
            var lastVoice = -1, voiced = 0, tone = 0, toneFreq = 0.0
            var beepEnd: Int?
            for (i, f) in s.enumerated() {
                let isTone = f.ratio > p.toneRatio
                if !isTone, f.level > max(floor[i] * p.voiceFactor, 2e-6) { lastVoice = i; voiced += 1 }
                if isTone, tone == 0 || abs(f.freq - toneFreq) <= 75 { if tone == 0 { toneFreq = f.freq }; tone += 1 }
                else { if (p.minToneFrames...75).contains(tone) { beepEnd = i }; tone = isTone ? 1 : 0; toneFreq = f.freq }
                let t = Double(i) * 0.02
                guard t >= detected else { continue }
                if let b = beepEnd, voiced >= 150, t - Double(b) * 0.02 >= p.afterBeep, lastVoice <= b + 10 { return t }
                let quiet = t - Double(lastVoice + 1) * 0.02
                if t - detected >= 5, voiced >= 150, quiet >= (ending ? p.quietWithEnding : p.quietNoEnding) { return t }
            }
            return nil
        }

        func score(_ p: VMTuning) -> (early: Int, wait: Double) {
            var early = 0, waits: [Double] = []
            for c in cases {
                guard let real = truth(c.stats) else { continue }
                guard let drop = simulate(c.stats, detected: c.detected, ending: c.ending, p) else { waits.append(8); continue }
                if drop < real - 0.15 { early += 1 } else { waits.append(drop - real) }
            }
            return (early, waits.isEmpty ? 0 : waits.reduce(0, +) / Double(waits.count))
        }

        let current = VMTuning.current
        let before = score(current)
        var best = current, bestScore = before
        for ratio in [0.35, 0.45, 0.55] { for minT in [5, 6, 8] { for vf in [5.0, 8.0, 12.0] {
            for qe in [2.0, 2.5, 3.0, 3.5] { for qn in [3.5, 4.5, 5.5] { for ab in [0.3, 0.5, 0.8] {
                let p = VMTuning(toneRatio: ratio, minToneFrames: minT, voiceFactor: vf, quietWithEnding: qe, quietNoEnding: qn, afterBeep: ab)
                let s = score(p)
                if s.early < bestScore.early || (s.early == bestScore.early && s.wait < bestScore.wait - 0.1) { best = p; bestScore = s }
            } } }
        } } }
        let applied = best != current
        if applied { VMTuning.current = best }
        return Result(samples: cases.count, earlyBefore: before.early, earlyAfter: bestScore.early,
                      waitBefore: before.wait, waitAfter: bestScore.wait, applied: applied, tuning: best)
    }

    private static func noiseFloors(_ s: [SliceStats]) -> [Double] {
        var floor = 1e-3
        return s.map { f in
            if f.level < floor { floor = max(f.level, 1e-9) } else { floor *= 1.003 }
            return floor
        }
    }
}
