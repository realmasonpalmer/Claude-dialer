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
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    try check(status, "Read property \(selector)")
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

    /// The Aircall desktop app (Aircall Workspace) or one of its helper processes,
    /// or the Aircall phone running inside this app (its sound plays in WebKit helper processes).
    var isAircallApp: Bool {
        bundleID.lowercased().contains("aircall") || name.lowercased().contains("aircall") || isAppPhone
    }

    /// A WebKit helper working for this app (the in-app Aircall phone), not for Safari.
    var isAppPhone: Bool {
        guard AircallPhone.isOn, bundleID.hasPrefix("com.apple.WebKit") else { return false }
        guard let responsible = Self.responsiblePID else { return true } // can't tell: assume it's ours
        return responsible(pid) == ProcessInfo.processInfo.processIdentifier
    }

    /// macOS's "which app is this helper working for" lookup, if available.
    private static let responsiblePID: ((pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias Fn = @convention(c) (pid_t) -> pid_t
        let fn = unsafeBitCast(sym, to: Fn.self)
        return { fn($0) }
    }()

    /// Chrome uses the mic and plays sound at the same time only while a call is live.
    static func chromeOnCall(in processes: [AudioProcess]) -> Bool {
        let chrome = processes.filter(\.isChrome)
        return chrome.contains(where: \.isRunningInput) && chrome.contains(where: \.isRunningOutput)
    }

    /// Same check for the Aircall desktop app.
    static func aircallAppOnCall(in processes: [AudioProcess]) -> Bool {
        let app = processes.filter(\.isAircallApp)
        return app.contains(where: \.isRunningInput) && app.contains(where: \.isRunningOutput)
    }

    /// A call is live in the Aircall desktop app or in Chrome (Aircall inside Salesforce).
    static func anyCallApp(in processes: [AudioProcess]) -> Bool {
        aircallAppOnCall(in: processes) || chromeOnCall(in: processes)
    }

    /// Which processes to listen to for the prospect: the Aircall app if it's on a call or open, else Chrome.
    static func callAudioTargets(in processes: [AudioProcess]) -> [AudioObjectID] {
        let aircall = processes.filter(\.isAircallApp)
        if aircallAppOnCall(in: processes) || (!aircall.isEmpty && !chromeOnCall(in: processes)) {
            return aircall.map(\.id)
        }
        return processes.filter(\.isChrome).map(\.id)
    }

    /// Every process except this app, sorted by name.
    static func others() -> [AudioProcess] {
        all().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }.sorted { $0.name < $1.name }
    }

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
