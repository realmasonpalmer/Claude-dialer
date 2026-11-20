import CoachCore
import Foundation

/// The live line: Haiku, fast and short, checked in code before it shows.
enum LiveCoach {
    /// This call's live-line model: calls alternate Haiku and Sonnet, to compare them on real calls.
    static var callModel = "claude-haiku-5-5"
    /// Haiku only: Sonnet was too slow for live lines (the Haiku vs Sonnet comparison is over).
    static let testModels = ["claude-haiku-5-5"]

    /// The next call's model (alternates, and remembers across app restarts).
    static func pickModelForNextCall() -> String {
        let n = UserDefaults.standard.integer(forKey: "abCallCount")
        UserDefaults.standard.set(n + 1, forKey: "abCallCount")
        return testModels[n % testModels.count]
    }

    static func client(_ key: String, model: String? = nil) -> ClaudeClient {
        let model = model ?? callModel
        var c = ClaudeClient(apiKey: key)
        c.model = model
        c.effort = "low"
        c.maxTokens = 120          // SAY + CUE + STAGE: a 1 to 2 sentence line
        c.idleTimeout = 8
        c.totalTimeout = 15
        if model.contains("haiku") {
            c.thinking = ["type": "disabled"] // this model takes no temperature setting
        } else {
            c.thinking = ["type": "between_tools"] // Sonnet with thinking off
        }
        return c
    }

    // MARK: Opt out, handled in code (no AI)

    static func isOptOut(_ text: String, isFinal: Bool = true) -> Bool { OptOut.matches(text, isFinal: isFinal) }

    static let optOutLine = "Understood. I'll take you off our list right now. Have a good day."

    /// Last resort when a line fails the check twice: smallest safe fix.
    static func sanitize(_ say: String) -> String {
        var s = say.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: ",")
        s = LineRepair.oneQuestion(s)
        return LineRepair.trimToFit(s, max: LineBudget.checkMax) // whole sentences, never a fragment (M7)
    }
}

/// Objections this rep keeps hitting, and the answers that kept the call going. Fed to the live coach
/// on every line, and written into the script's BLOCKERS section every 20 calls.
enum BlockerBook {
    struct Entry: Codable { var objection: String; var response: String; var worked: Bool; var date: Date }

    private static func key(_ campaign: UUID) -> String { "blockers-" + campaign.uuidString }

    static func all(_ campaign: UUID) -> [Entry] {
        (UserDefaults.standard.data(forKey: key(campaign))).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    static func add(_ new: [Entry], campaign: UUID) {
        guard !new.isEmpty else { return }
        let list = Array((all(campaign) + new).suffix(400))
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(campaign))
    }

    /// The top blockers, most common first, each with the answer that worked most often.
    static func top(_ campaign: UUID, limit: Int = 8) -> [(objection: String, count: Int, worked: Int, best: String?)] {
        let groups = Dictionary(grouping: all(campaign)) { $0.objection.lowercased().trimmingCharacters(in: .whitespaces) }
        return groups.map { (_, items) in
            let wins = items.filter(\.worked)
            let best = Dictionary(grouping: wins, by: \.response).max { $0.value.count < $1.value.count }?.key
            return (items[0].objection, items.count, wins.count, best)
        }
        .sorted { $0.count > $1.count }
        .prefix(limit).map { $0 }
    }

    /// For the live coach: what's worked on this call list's blockers so far.
    static func hints(_ campaign: UUID) -> String {
        let list = top(campaign).filter { $0.count >= 2 }
        guard !list.isEmpty else { return "" }
        return "Blockers this rep keeps hitting on this call list, and what kept the call going (use when it fits, in your own words):\n"
            + list.map { b in "- \"\(b.objection)\" (\(b.count) times\(b.best.map { "; worked: \"\($0)\"" } ?? "; nothing has worked yet, try a fresh angle"))" }
                .joined(separator: "\n")
    }

    /// The BLOCKERS section for the script.
    static func section(_ campaign: UUID) -> String? {
        let list = top(campaign, limit: 12).filter { $0.count >= 2 }
        guard !list.isEmpty else { return nil }
        var lines = ["BLOCKERS (learned from your calls, updated every 20 calls)", "ID | Sounds like | Say | Then"]
        for (i, b) in list.enumerated() {
            lines.append("BLK \(i + 1) | \(b.objection) (\(b.count) times, \(b.worked) kept going) | \(b.best ?? "(no winning answer yet)") | back to the last stage question")
        }
        return lines.joined(separator: "\n")
    }
}

extension Notification.Name {
    /// userInfo: "id" (UUID), "section" (String). The app writes it into that call list's script.
    static let blockersUpdated = Notification.Name("blockersUpdated")
}
