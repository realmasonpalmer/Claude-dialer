import Foundation

/// The 21-day plan for each person:
/// - Day 1: 2 dials, voicemail, text, LinkedIn connection request.
/// - Day 2: 2 dials, text.
/// - Day 5: 2 dials. Day 8: 2 dials.
/// - Day 16: 2 dials, text.
/// Texts never go to Washington numbers (consent law). Stops when they pick up, when they're
/// marked off the list, or after day 16.
enum Cadence {
    static let callDays = [1, 2, 5, 8, 16]

    struct Step {
        let index: Int // 0...4
        var planDay: Int { Cadence.callDays[index] }
        var leaveVoicemail: Bool { index == 0 }
        var voicemailNumber: Int { 1 }
        var textToday: Bool { index == 0 || index == 1 || index == 4 }
        var linkedInConnect: Bool { index == 0 }
        var linkedInMessage: Bool { false }
        var isLast: Bool { index == Cadence.callDays.count - 1 }
    }

    private static var cal: Calendar { .current }

    /// The days they were called on, oldest first.
    static func callDates(_ id: String) -> [Date] {
        var seen = Set<Date>()
        var out: [Date] = []
        for d in DialHistory.person(id).dials {
            let day = cal.startOfDay(for: d)
            if seen.insert(day).inserted { out.append(day) }
        }
        return out
    }

    /// Today's step for them (today counts as the same step for the redial). nil = plan done.
    static func step(for id: String) -> Step? {
        let today = cal.startOfDay(for: Date())
        let before = callDates(id).filter { $0 < today }.count
        return before < callDays.count ? Step(index: before) : nil
    }

    /// Day of the plan today (day 1 = their first call day).
    static func day(for id: String) -> Int {
        guard let first = callDates(id).first else { return 1 }
        return (cal.dateComponents([.day], from: first, to: cal.startOfDay(for: Date())).day ?? 0) + 1
    }

    /// Should they be called today? New people yes; after a pickup or the last call day, no.
    static func isDue(_ id: String) -> Bool {
        if DialHistory.person(id).pickups > 0 { return false }
        guard let s = step(for: id) else { return false }
        return s.index == 0 || day(for: id) >= s.planDay
    }

    /// All 5 call days used.
    static func isFinished(_ id: String) -> Bool { step(for: id) == nil }

    /// "Day 5 · call 3 of 5 · no voicemail" for the card.
    static func label(for id: String) -> String {
        let p = DialHistory.person(id)
        if p.pickups > 0 { return "Picked up before" }
        guard let s = step(for: id) else { return "Plan done" }
        var parts = ["Day \(day(for: id))", "call \(s.index + 1) of \(callDays.count)"]
        parts.append(s.leaveVoicemail ? "voicemail #\(s.voicemailNumber)" : "no voicemail")
        if s.textToday { parts.append("text") }
        return parts.joined(separator: " · ")
    }

    /// Washington requires consent for sales texts ($500 per message): never text these area codes.
    static let washingtonAreaCodes: Set<String> = ["206", "253", "360", "425", "509", "564"]

    static func isWashington(_ phone: String) -> Bool {
        var digits = phone.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
        return digits.count == 10 && washingtonAreaCodes.contains(String(digits.prefix(3)))
    }
}
