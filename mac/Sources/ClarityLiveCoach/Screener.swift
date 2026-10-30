import Foundation

/// Spots automated call screeners (iPhone, Google Call Screen, carrier screening) and
/// "who's calling?" gatekeepers from the prospect's words, instantly and without Claude.
enum Screener {
    private static let phrases = [
        "screening service", "call screen", "screening this call", "being screened", "screening calls",
        "person you're trying to reach",
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

/// Spots voicemail greetings and full mailboxes from the prospect's words, instantly.
/// Only strong phrases count, so a gatekeeper saying "she's not available" doesn't trigger it.
enum Voicemail {
    private static let phrases = [
        "leave a message", "leave your message", "leave me a message", "leave a voicemail", "leave a brief message",
        "after the tone", "after the beep", "at the tone", "at the beep", "voicemail", "voice mail", "mailbox",
        "record your message", "please leave", "can't take your call", "cannot take your call",
        "not available to take your call", "can't come to the phone", "cannot come to the phone",
        "away from my desk", "get back to you as soon as",
    ]
    private static let fullPhrases = [
        "mailbox is full", "mailbox full", "cannot accept any messages", "not accepting messages",
        "has not been set up", "hasn't been set up", "not set up yet",
    ]

    static func detects(_ text: String) -> Bool { contains(text, phrases) || mailboxFull(text) }
    static func mailboxFull(_ text: String) -> Bool { contains(text, fullPhrases) }

    private static func contains(_ text: String, _ list: [String]) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return list.contains { t.contains($0) }
    }
}
