import AppKit

/// Reads the title of the active Chrome tab to learn which Salesforce record is open,
/// e.g. "Jane Doe | Lead | Salesforce" -> "Lead \"Jane Doe\"".
/// This is not a Salesforce integration: it only reads the tab title, with your permission.
enum SalesforceTab {
    /// Runs on the main thread. Returns nil if Chrome isn't open or no record is showing.
    /// Reads the Salesforce tab even when another tab (like LinkedIn) is in front.
    @MainActor
    static func currentRecord() -> String? {
        SalesforceChrome.title().flatMap(parse)
    }

    /// The visible text of the open Salesforce record (title, company, notes...), trimmed.
    /// Needs Chrome's View > Developer > "Allow JavaScript from Apple Events". Returns nil without it.
    @MainActor
    static func pageText() -> String? {
        guard let raw = SalesforceChrome.javascript("document.body.innerText.slice(0, 12000)"), !raw.isEmpty else { return nil }
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
