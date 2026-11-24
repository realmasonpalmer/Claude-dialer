import CoreAudio
import Foundation

/// Keeps Bluetooth headphones in one mode while the app is open.
///
/// Bluetooth headphones have two modes: music (high quality, 44.1/48 kHz, output only) and
/// headset/call (16 kHz, with mic). They switch to call mode the moment *anything* on the Mac
/// opens their microphone and back when it's released; each switch changes the sample rate
/// mid-call, which is the "voices jumping octaves" glitch.
///
/// So while the app runs, the headphones' mic is never the Mac's input: if the system input is
/// a Bluetooth device (macOS picks it automatically when headphones connect), it's moved to the
/// Mac's built-in mic, and put back when the app quits. The Aircall phone is also pinned to the
/// built-in mic. Result: one codec, one sample rate, for the whole session. Every change to the
/// output's sample rate is written to the debug log.
@MainActor
final class AudioRoute {
    static let shared = AudioRoute()
    private var originalInput: AudioDeviceID?
    private var watchedOutput: AudioDeviceID?

    func start() {
        keepInputOffBluetooth(reason: "app opened")
        watchOutputRate()
        // Headphones connecting (or macOS switching input) → move the input back off them.
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            Task { @MainActor in AudioRoute.shared.keepInputOffBluetooth(reason: "input device changed") }
        }
        var out = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &out, .main) { _, _ in
            Task { @MainActor in AudioRoute.shared.watchOutputRate() }
        }
    }

    /// Put the Mac's input back the way it was (the app is quitting).
    func stop() {
        guard let original = originalInput, Self.exists(original) else { return }
        Self.setDefaultInput(original)
        Log.add("audio", "restored the Mac's input to \(Self.name(original))")
    }

    private func keepInputOffBluetooth(reason: String) {
        guard let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return }
        guard Self.isBluetooth(input) else {
            Log.add("audio", "\(reason): input is \(Self.name(input)) (not Bluetooth) — headphones stay in one mode")
            return
        }
        guard let builtIn = Self.builtInMic() else {
            Log.add("audio", "\(reason): input is Bluetooth (\(Self.name(input))) and there's no built-in mic to use instead")
            return
        }
        if originalInput == nil { originalInput = input }
        Self.setDefaultInput(builtIn)
        Log.add("audio", "\(reason): moved the Mac's input from \(Self.name(input)) to \(Self.name(builtIn)) so the headphones never switch into call mode")
    }

    private func watchOutputRate() {
        guard let out = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice), out != watchedOutput else { return }
        watchedOutput = out
        Log.add("audio", "output: \(Self.name(out)) at \(Int(Self.sampleRate(out))) Hz\(Self.isBluetooth(out) ? " (Bluetooth)" : "")")
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(out, &addr, .main) { _, _ in
            Task { @MainActor in
                Log.add("audio", "⚠︎ output sample rate changed: \(AudioRoute.name(out)) now \(Int(AudioRoute.sampleRate(out))) Hz (something opened or released the headphones' mic)")
            }
        }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        return ok && id != 0 ? id : nil
    }

    private static func setDefaultInput(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var dev = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func exists(_ id: AudioDeviceID) -> Bool { allDevices().contains(id) }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transport(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func builtInMic() -> AudioDeviceID? {
        allDevices().first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "device \(id)" }
        return n.takeRetainedValue() as String
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }
}
