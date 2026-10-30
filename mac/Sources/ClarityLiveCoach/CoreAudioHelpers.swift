import AppKit
import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let what: String
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, what: what) }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// Reads a fixed-size Core Audio property (UInt32, pid_t, AudioObjectID, AudioStreamBasicDescription...).
func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Read property \(selector)")
    return value
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Read string \(selector)")
    guard let value else { return "" }
    return value.takeRetainedValue() as String
}

func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "Size of list \(selector)")
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list), "Read list \(selector)")
    return list
}

/// One app (or helper process) that Core Audio knows about.
struct AudioProcess: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let isRunningInput: Bool   // using a microphone right now
    let isRunningOutput: Bool  // playing sound right now

    var isChrome: Bool { bundleID.hasPrefix("com.google.Chrome") }

    static func all() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids = try? readObjectList(system, kAudioHardwarePropertyProcessObjectList) else { return [] }
        return ids.compactMap { id in
            guard let pid = try? readProperty(id, kAudioProcessPropertyPID, pid_t(0)) else { return nil }
            let bundleID = (try? readString(id, kAudioProcessPropertyBundleID)) ?? ""
            let input = (try? readProperty(id, kAudioProcessPropertyIsRunningInput, UInt32(0))) ?? 0
            let output = (try? readProperty(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID
            return AudioProcess(
                id: id, pid: pid, bundleID: bundleID, name: name.isEmpty ? "PID \(pid)" : name,
                isRunningInput: input != 0, isRunningOutput: output != 0
            )
        }
    }
}

func defaultOutputDeviceUID() throws -> String {
    let device = try readProperty(
        AudioObjectID(kAudioObjectSystemObject),
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        AudioDeviceID(kAudioObjectUnknown)
    )
    return try readString(device, kAudioDevicePropertyDeviceUID)
}
