import Foundation

/// One day of the outreach sequence: what happens on that day's call.
struct Step: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var day: Int                 // 1, 3, 5: spacing between steps comes from the difference
    var status: String           // set on the first call of this day
    var voicemail: String?       // Aircall voicemail-drop name; nil = don't leave one
    var text: String?            // sent if they don't pick up; nil = no text
    var linkedInNote: String?    // connection request note; nil = no LinkedIn today
}

/// The whole sequence. Data, not code: change it in Settings > Sequence.
struct Cadence: Codable, Equatable, Sendable {
    var steps: [Step]

    static let standard = Cadence(steps: [
        Step(day: 1, status: "1st Contact", voicemail: "Voicemail 1",
             text: "Hi {{FirstName}}, it's {{Rep}} with Clarity. Just tried you by phone. Curious, do you use Claude or other AI tools in your business? Want to trade notes?",
             linkedInNote: "Curious, do you use Claude or other AI tools in your business? Want to trade notes?"),
        Step(day: 3, status: "2nd Contact", voicemail: "Voicemail 2",
             text: "Hi {{FirstName}}, {{Rep}} again. Tried you a couple of days ago. Is there a good time this week for a quick chat?"),
        Step(day: 5, status: "3rd Contact"),
    ])

    /// "New" then each step's status: the order statuses only ever move forward in.
    var ladder: [String] { ["New"] + steps.map(\.status) }
}

/// Where one person is in the sequence today.
enum Plan: Equatable, Sendable {
    case due(step: Int, overdueDays: Int)   // call today (overdueDays > 0 = late)
    case calledToday(step: Int)             // today's step already started
    case notYet(step: Int, inDays: Int)     // next step isn't due yet
    case done                               // every step done

    var step: Int? {
        switch self {
        case .due(let s, _), .calledToday(let s), .notYet(let s, _): return s
        case .done: return nil
        }
    }
}

extension Cadence {
    /// Pure: the plan for someone, from the days they were called.
    /// Each step is due `step.day - previous.day` days after the previous call day (so a late
    /// Day 3 pushes Day 5 back too, keeping the rhythm), and only one step happens per day.
    func plan(callDates: [Date], now: Date = Date(), calendar cal: Calendar = .current) -> Plan {
        guard !steps.isEmpty else { return .done }
        let today = cal.startOfDay(for: now)
        let before = Set(callDates.map { cal.startOfDay(for: $0) }).filter { $0 < today }.sorted()
        let n = before.count
        if callDates.contains(where: { cal.isDate($0, inSameDayAs: now) }) {
            return n < steps.count ? .calledToday(step: n) : .done
        }
        guard n < steps.count else { return .done }
        guard n > 0, let last = before.last else { return .due(step: 0, overdueDays: 0) }
        let gap = max(1, steps[n].day - steps[n - 1].day)
        let due = cal.date(byAdding: .day, value: gap, to: last)!
        let diff = cal.dateComponents([.day], from: due, to: today).day ?? 0
        return diff >= 0 ? .due(step: n, overdueDays: diff) : .notYet(step: n, inDays: -diff)
    }

    /// The status to set for today's step, or nil to leave it. Only moves forward along the
    /// ladder, never sideways off it (a "Qualified" lead stays Qualified), and only to a value
    /// the org has, matched ignoring case.
    func status(forStep i: Int, current: String, options: [String]) -> String? {
        guard steps.indices.contains(i) else { return nil }
        let target = steps[i].status
        let cur = current.trimmed.isEmpty ? "New" : current
        guard let at = ladder.firstIndex(where: { $0.caseInsensitiveCompare(cur) == .orderedSame }),
              at < i + 1 else { return nil }
        return options.first { $0.caseInsensitiveCompare(target) == .orderedSame }
    }
}
