import Foundation

/// Spots automated call screeners (iPhone, Google Call Screen, carrier screening) and
/// "who's calling?" gatekeepers from the prospect's words, instantly and without Claude.
enum Screener {
    private static let phrases = [
        "screening service", "call screen", "screening this call", "being screened", "screening calls",
        "the person you're calling", "the person you are calling", "person you're trying to reach",
        "say your name", "state your name", "record your name", "speak your name",
        "your name and why", "your name and the reason", "reason for your call", "reason for calling",
        "why you're calling", "why you are calling", "what you're calling about", "what this call is about",
        "google assistant", "stay on the line", "before i connect you", "see if this person is available",
        "may i ask who's calling", "may i ask who is calling", "who's calling please", "who is calling please",
        "may i tell them who's calling", "and your name",
    ]

    static func detects(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return phrases.contains { t.contains($0) }
    }

    /// "This is Mason calling for Jane."
    static func line(calling: String?) -> String {
        let rep = UserDefaults.standard.string(forKey: "repName")?.trimmed ?? ""
        return "This is \(rep.isEmpty ? "[your name]" : rep) calling for \(firstName(calling) ?? "[their name]")."
    }

    /// First name from a record like: Lead "Jane Doe". People only, not companies.
    static func firstName(_ calling: String?) -> String? {
        guard let calling,
              ["Lead", "Contact", "Person Account"].contains(where: { calling.hasPrefix($0) }),
              let open = calling.firstIndex(of: "\""),
              let name = calling[calling.index(after: open)...].split(separator: " ").first else { return nil }
        let first = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return first.isEmpty ? nil : first
    }
}
