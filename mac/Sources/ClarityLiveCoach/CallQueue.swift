import Foundation

/// Who to call next, best first:
/// 1. Follow-ups due today or late. The most days late go first, so a list that fell behind catches up.
/// 2. People never called.
/// Inside each group: East Coast first when that's on, then by last name, A to Z.
/// Everyone else (called today, resting until their next day, done, taken off) goes last.
/// Uses this Mac's calls plus the team's calls from Salesforce (`CallHistory`).
enum CallQueue {
    /// Sorts smallest first. `passedOver` = the rep moved past them today without calling: after everyone else.
    static func key(id: String, name: String, passedOver: Bool = false) -> (Int, Int, Int, Int, String, String) {
        let tier: Int
        var late = 0
        if !CalledToday.isCallable(id) {
            tier = 2
        } else if Cadence.callDates(id).isEmpty {
            tier = 1
        } else {
            tier = 0
            late = Cadence.daysLate(id) ?? 0
        }
        let zone = TimeZoneFilter.eastCoastFirst ? TimeZoneFilter.eastRank(id) : 0
        let lower = name.lowercased()
        return (passedOver ? 1 : 0, tier, zone, -late, lastName(lower), lower)
    }

    /// The word to sort by: the last name, skipping endings like Jr., III, CPA.
    static func lastName(_ name: String) -> String {
        let endings: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "phd", "ph.d.", "cpa", "mba", "md", "m.d.", "esq", "esq."]
        let words = name.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        return words.last(where: { !endings.contains($0) }) ?? ""
    }

    /// The list in call order. Ties keep the list's own order.
    static func ordered<T>(_ items: [T], id: (T) -> String, name: (T) -> String) -> [T] {
        let keyed = items.enumerated().map { (key: key(id: id($0.element), name: name($0.element)), offset: $0.offset, item: $0.element) }
        return keyed.sorted { a, b in
            if a.key != b.key { return a.key < b.key }
            return a.offset < b.offset
        }.map { $0.item }
    }

    /// "Today: 3 late · 12 follow-ups due · 30 new · 8 resting" for the top of the coach.
    static func summary(_ ids: [String]) -> String? {
        var late = 0, due = 0, new = 0, resting = 0
        for id in ids {
            if CalledToday.isCallable(id) {
                if Cadence.callDates(id).isEmpty { new += 1 }
                else if (Cadence.daysLate(id) ?? 0) > 0 { late += 1 }
                else { due += 1 }
            } else if Cadence.comesBackLater(id) {
                resting += 1
            }
        }
        var parts: [String] = []
        if late > 0 { parts.append("\(late) late") }
        if due > 0 { parts.append("\(due) follow-up\(due == 1 ? "" : "s") due") }
        if new > 0 { parts.append("\(new) new") }
        if resting > 0 { parts.append("\(resting) resting") }
        return parts.isEmpty ? nil : "Today: " + parts.joined(separator: " · ")
    }
}
