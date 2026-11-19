import AppKit
import ApplicationServices

/// The space bar asks for a fresh line during a live call, even while Chrome (Salesforce, LinkedIn) is in front.
/// - Only while a call is live. Otherwise Space works normally everywhere.
/// - In Chrome, a space typed into a text box (a note, a search, a message) still types a space: the app checks
///   a few times a second whether the cursor is in a text box, and lets the space through when it is.
/// - Any other app is never touched. When this app is in front, its own key monitor handles Space.
/// - Needs macOS Accessibility permission (asked once). Without it, Space only works with this app in front.
enum SpaceKey {
    /// Set by the coach: a call is live right now.
    static var callLive = false { didSet { callLive ? startWatchingChrome() : stopWatchingChrome() } }
    /// What to do on a space press that's ours.
    static var onFresh: (() -> Void)?

    private static var tap: CFMachPort?
    private static var chromeEditable = true // safest default: let spaces through until we know
    private static var watcher: Timer?
    private static let queue = DispatchQueue(label: "clarity.space-key")
    private static var asked = false
    private static var checking = false // one Chrome check at a time: no backlog when Chrome is slow

    /// Called when a call starts. Asks for Accessibility once; installs the key tap when allowed.
    static func install() {
        guard tap == nil else { return }
        if !AXIsProcessTrusted() {
            if !asked {
                asked = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                ActivityLog.add("Space bar in Chrome: allow Clarity Live Coach in System Settings > Privacy > Accessibility")
            }
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: spaceCallback, userInfo: nil) else {
            ActivityLog.problem("Space bar in Chrome: couldn't watch the keyboard")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        ActivityLog.add("Space bar in Chrome: on during calls")
    }

    /// Decides one key press. Return nil to keep it (we used it), or the event to let it through.
    fileprivate static func decide(_ event: CGEvent) -> CGEvent? {
        guard callLive,
              event.getIntegerValueField(.keyboardEventKeycode) == 49, // space
              event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.google.Chrome") == true,
              !chromeEditable else { return event }
        DispatchQueue.main.async { onFresh?() }
        return nil
    }

    static func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    // MARK: Is the cursor in a text box in Chrome? (checked about 3 times a second during calls)

    private static func startWatchingChrome() {
        DispatchQueue.main.async {
            watcher?.invalidate()
            chromeEditable = true
            watcher = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                guard !checking, NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.google.Chrome") == true else { return }
                checking = true
                queue.async {
                    let js = "var e=document.activeElement;(e&&(e.isContentEditable||/^(input|textarea|select)$/i.test(e.tagName)))?'1':'0'"
                    let script = "tell application \"Google Chrome\" to execute active tab of front window javascript \"\(js)\""
                    let r = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue
                    let editable = r != "0" // unknown counts as a text box: never steal a space we can't check
                    DispatchQueue.main.async { chromeEditable = editable; checking = false }
                }
            }
        }
    }

    private static func stopWatchingChrome() {
        DispatchQueue.main.async { watcher?.invalidate(); watcher = nil; chromeEditable = true }
    }
}

private func spaceCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // macOS turns a slow tap off: turn it back on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { SpaceKey.reenable(); return Unmanaged.passUnretained(event) }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    return SpaceKey.decide(event).map { Unmanaged.passUnretained($0) }
}
