import AppKit
import Foundation
import Observation

/// The debug log: every decision the dialer makes, with the reason, timestamped.
/// Written to ~/Library/Logs/ClarityDialer.log and shown in Settings > Debug log, where
/// "Copy for support" puts the recent log and the current settings on the clipboard.
@Observable @MainActor
final class Log {
    static let shared = Log()
    private(set) var lines: [String] = []
    private let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClarityDialer.log")
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// `area`: call, beep, vm, redial, linkedin, aircall, salesforce, review, update...
    static func add(_ area: String, _ text: String) {
        shared.write("[\(area)] \(text)")
    }

    private func write(_ entry: String) {
        let line = "\(stamp.string(from: Date()))  \(entry)"
        lines.append(line)
        if lines.count > 1500 { lines.removeFirst(lines.count - 1500) }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    func copyForSupport(settings: OutboundSettings) {
        let s = settings
        let header = """
        Clarity Dialer debug log — \(Date().formatted())
        Settings: autoDial=\(s.autoDial) countdown=\(s.countdown) callTwice=\(s.callTwice) mobileOnly=\(s.mobileOnly) \
        voicemailDrop=\(s.voicemailDrop) hours=\(s.startHour)-\(s.endHour) \
        aircallUser=\(s.aircallUserID.map(String.init) ?? "-") from=\(s.fromNumberID.map(String.init) ?? "-") \
        linkedInBot=\(LinkedInBot.isOn) chromeProblem=\(LinkedInBot.chromeProblem ?? "none") \
        sequence=\(s.cadence.steps.map { "D\($0.day):vm=\($0.voicemail ?? "-")" }.joined(separator: ","))
        Version: \(UserDefaults.standard.string(forKey: "installedSHA")?.prefix(7) ?? "?")

        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + lines.suffix(400).joined(separator: "\n"), forType: .string)
    }

    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
