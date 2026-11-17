import AVFoundation
import CoreAudio
import Foundation

/// "Record audio for debugging": 60 seconds of everything the Mac plays (what you hear), plus the
/// call audio the app gets, as sound files, and a report of every audio device, its sample rate, and every change while recording.
/// Saved to ~/Documents/Clarity Audio Debug/<time>/. Nothing is sent anywhere.
final class AudioDebug: @unchecked Sendable {
    static let shared = AudioDebug()
    private let lock = NSLock()
    private var rep = Data(), them = Data()
    private var notes: [String] = []
    private var until: Date?
    private var started = Date()
    private var watchTimer: Timer?
    private var lastSnapshot = ""

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return until.map { Date() < $0 } ?? false }

    /// Called with every chunk the app hears (16 kHz, 16-bit mono).
    func feed(_ pcm: Data, isRep: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let until, Date() < until else { return }
        if !isRep { them.append(pcm) }
    }

    func note(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard until != nil else { return }
        notes.append(String(format: "%6.2fs  ", Date().timeIntervalSince(started)) + text)
    }

    /// Records for `seconds`, then saves and returns the folder.
    @MainActor
    func record(seconds: Double = 60) async -> URL? {
        lock.lock()
        rep = Data(); them = Data(); notes = []; started = Date(); until = Date().addingTimeInterval(seconds); lastSnapshot = ""
        lock.unlock()
        note("Recording started. Devices:\n" + Self.devices())
        // Everything the Mac plays, at its real speed (no conversion), so pitch problems show as they are.
        let dir0 = FileManager.default.temporaryDirectory.appendingPathComponent("clarity-output-\(UUID().uuidString).caf")
        let tap = ProcessTap()
        let fileBox = FileBox()
        do {
            try tap.start(processes: [], everything: true) { buffer in
                if fileBox.file == nil { fileBox.file = try? AVAudioFile(forWriting: dir0, settings: buffer.format.settings) }
                try? fileBox.file?.write(from: buffer)
                fileBox.rate = buffer.format.sampleRate
            }
        } catch {
            note("Couldn't record the Mac's sound output: \(error.localizedDescription)")
        }
        // Watch for device and sample rate changes every 200 ms.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let snap = Self.defaults()
            if snap != self.lastSnapshot { self.note("Default devices now: " + snap); self.lastSnapshot = snap }
        }
        try? await Task.sleep(for: .seconds(seconds))
        watchTimer?.invalidate()
        tap.stop()
        fileBox.file = nil
        note(String(format: "Mac sound output recorded at %.0f Hz", fileBox.rate))
        lock.lock()
        let r = rep, t = them, n = notes
        until = nil
        lock.unlock()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Clarity Audio Debug/\(f.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = r
        try? FileManager.default.moveItem(at: dir0, to: dir.appendingPathComponent("what-you-heard.caf"))
        try? Self.wav(t).write(to: dir.appendingPathComponent("call-audio-the-app-got.wav"))
        let report = (n + ["", String(format: "Call audio the app got: %.1f s.", Double(t.count) / 32000),
                           "", "Activity log, last 150 lines:", ActivityLog.recent(lines: 150, transcripts: false)]).joined(separator: "\n")
        try? report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        ActivityLog.add("Audio debug: saved to \(dir.path)")
        return dir
    }

    // MARK: Devices

    private static func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) } == noErr ? v : nil
    }

    private static func describe(_ id: AudioDeviceID) -> String {
        let name = (try? readString(id, kAudioObjectPropertyName)) ?? "?"
        let rate = prop(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
        let transport = prop(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        let kind: String = switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        default: "other"
        }
        return "\(name) (\(kind), \(Int(rate)) Hz)"
    }

    static func defaults() -> String {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let out = prop(sys, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)) ?? 0
        let inp = prop(sys, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)) ?? 0
        return "output \(describe(out)), input \(describe(inp))"
    }

    static func devices() -> String {
        let ids = (try? readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)) ?? []
        return ids.map { "  - " + describe($0) }.joined(separator: "\n") + "\n  Defaults: " + defaults()
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
}

/// Holds the output file while the tap writes to it (from the tap's own queue).
final class FileBox: @unchecked Sendable {
    var file: AVAudioFile?
    var rate = 0.0
}
