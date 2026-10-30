import AppKit

/// Reads the title of the active Chrome tab to learn which Salesforce record is open,
/// e.g. "Jane Doe | Lead | Salesforce" -> "Lead \"Jane Doe\"".
/// This is not a Salesforce integration: it only reads the tab title, with your permission.
enum SalesforceTab {
    private static let script = NSAppleScript(source: """
    tell application "Google Chrome"
        if (count of windows) is 0 then return ""
        return title of active tab of front window
    end tell
    """)

    /// Runs on the main thread. Returns nil if Chrome isn't open or no record is showing.
    @MainActor
    static func currentRecord() -> String? {
        // Never launch Chrome just to read a title.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty == false,
              let title = script?.executeAndReturnError(nil).stringValue else { return nil }
        return parse(title)
    }

    private static let pageScript = NSAppleScript(source: """
    tell application "Google Chrome"
        if (count of windows) is 0 then return ""
        return execute active tab of front window javascript "document.body.innerText.slice(0, 12000)"
    end tell
    """)

    /// The visible text of the open Salesforce record (title, company, notes...), trimmed.
    /// Needs Chrome's View > Developer > "Allow JavaScript from Apple Events". Returns nil without it.
    @MainActor
    static func pageText() -> String? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty == false,
              let raw = pageScript?.executeAndReturnError(nil).stringValue, !raw.isEmpty else { return nil }
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(4000))
    }

    static func parse(_ title: String) -> String? {
        let parts = title.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.last?.hasPrefix("Salesforce") == true, let name = parts.first, !name.isEmpty else {
            return nil
        }
        let kind = parts.count >= 3 ? parts[1] : ""
        let known = ["Lead", "Contact", "Account", "Person Account", "Opportunity"]
        guard known.contains(kind) else { return nil } // skip list views, home, reports
        return "\(kind) \"\(name)\""
    }
}
