import AppKit
import Foundation

/// Sends bug reports to a private Slack channel (an Incoming Webhook link saved in Setup).
/// Automatic when something goes wrong, at most once per kind of problem every 10 minutes
/// and 20 a day. Each report: what went wrong, what the app was doing, the version, and the
/// last 80 log lines (phone numbers masked). Off until a webhook link is saved.
@MainActor
enum BugReporter {
    /// What the coach is doing right now (set by CoachModel).
    static var context: () -> String = { "" }

    private static var lastSent: [String: Date] = [:]
    private static var sentToday: (day: String, count: Int) = ("", 0)

    static var isOn: Bool { webhook != nil }
    static var webhook: URL? {
        Keychain.read(.bugWebhook).flatMap(URL.init(string:)).flatMap { $0.host?.hasSuffix("slack.com") == true ? $0 : nil }
    }

    /// Something went wrong: send a report (rate-limited).
    static func auto(_ problem: String) {
        guard isOn else { return }
        let kind = String(problem.prefix(40))
        if let last = lastSent[kind], Date().timeIntervalSince(last) < 600 { return }
        let today = Date().formatted(.iso8601.year().month().day())
        if sentToday.day != today { sentToday = (today, 0) }
        guard sentToday.count < 20 else { return }
        lastSent[kind] = Date()
        sentToday.count += 1
        send(title: "Auto report: \(problem)")
    }

    /// The rep clicked "Send bug report".
    static func manual(note: String = "") async -> String {
        guard isOn else { return "Bug reports are off. Turn them on in Setup (step 8)." }
        return await post(title: "Report from the rep" + (note.isEmpty ? "" : ": \(note)")) ? "Sent. Thanks!" : "Couldn't send it. Check the Slack link in Setup."
    }

    private static func send(title: String) {
        Task { _ = await post(title: title) }
    }

    private static func post(title: String) async -> Bool {
        guard let url = webhook else { return false }
        let rep = UserDefaults.standard.string(forKey: PrefKey.repName) ?? "?"
        let version = String((UserDefaults.standard.string(forKey: PrefKey.installedSHA) ?? "unknown").prefix(7))
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let text = """
        :rotating_light: *\(title)*
        Rep: \(rep) · Version: \(version) · macOS \(os)
        *Right now:* \(context())
        ```
        \(ActivityLog.recent(lines: 80).suffix(3500))
        ```
        """
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
