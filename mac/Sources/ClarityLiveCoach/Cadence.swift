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

    /// The days they were called on, oldest first: this Mac's calls plus the team's calls in Salesforce.
    static func callDates(_ id: String) -> [Date] {
        var seen = Set<Date>()
        for d in DialHistory.person(id).dials { seen.insert(cal.startOfDay(for: d)) }
        for d in CallHistory.callDays(id) { seen.insert(cal.startOfDay(for: d)) }
        return seen.sorted()
    }

    /// They picked up before: on this Mac, or Picked Up Cold Call is checked in Salesforce.
    static func pickedUp(_ id: String) -> Bool {
        DialHistory.person(id).pickups > 0 || CallHistory.pickedUp(id)
    }

    /// Days to wait after the last call day before each step: 1 day (to day 2), 3 (to day 5),
    /// 3 (to day 8), 8 (to day 16).
    static func gap(before index: Int) -> Int {
        index <= 0 ? 0 : callDays[index] - callDays[index - 1]
    }

    /// Whole days since their last call day before today. nil = never called before today.
    static func daysSinceLastCall(_ id: String) -> Int? {
        let today = cal.startOfDay(for: Date())
        guard let last = callDates(id).last(where: { $0 < today }) else { return nil }
        return cal.dateComponents([.day], from: last, to: today).day
    }

    /// How many days past due their next call is. 0 = due today. nil = not due yet, or new.
    static func daysLate(_ id: String) -> Int? {
        guard let s = step(for: id), s.index > 0, let since = daysSinceLastCall(id) else { return nil }
        let late = since - gap(before: s.index)
        return late >= 0 ? late : nil
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
    /// Spacing counts from their last call, so someone who fell behind gets their next step now,
    /// then waits the normal gap. Never several days in a row to catch up.
    static func isDue(_ id: String) -> Bool {
        if pickedUp(id) { return false }
        guard let s = step(for: id) else { return false }
        if s.index == 0 { return true }
        guard let since = daysSinceLastCall(id) else { return true }
        return since >= gap(before: s.index)
    }

    /// All 5 call days used.
    static func isFinished(_ id: String) -> Bool { step(for: id) == nil }

    /// The most dials per person per day.
    static let dialsPerDay = 2

    /// Called on an earlier day: a follow-up (day 2, 5, 8 or 16), not a brand new person.
    /// Follow-ups go to the top of the list: they've already heard the rep's voicemail.
    static func isFollowUp(_ id: String) -> Bool {
        let today = cal.startOfDay(for: Date())
        return callDates(id).contains { $0 < today }
    }

    /// Why the plan says not to call them right now, in plain words. nil = OK to call.
    static func whyNotNow(_ id: String) -> String? {
        if RemovedList.contains(id) { return "They're off your list." }
        if let zone = TimeZoneFilter.why(id) { return zone }
        let p = DialHistory.person(id)
        if pickedUp(id) { return "They picked up before, so the plan is done for them." }
        if p.badNumber || p.failedConnects >= 2 { return "Their number didn't work." }
        let dialsToday = p.dials.filter { cal.isDateInToday($0) }.count
        if dialsToday >= dialsPerDay { return "Already called \(dialsToday) times today. The plan is \(dialsPerDay)." }
        if dialsToday > 0 { return nil } // the 2nd dial today
        guard let s = step(for: id) else { return "All \(callDays.count) call days are done." }
        if s.index > 0, !isDue(id), let since = daysSinceLastCall(id) {
            let wait = gap(before: s.index) - since
            return "Not due today. Their next call is in \(wait) day\(wait == 1 ? "" : "s")."
        }
        return nil
    }

    /// Still on the plan, just not due today (resting between call days, or already called today).
    static func comesBackLater(_ id: String) -> Bool {
        guard !RemovedList.contains(id), !DialHistory.isMaxed(id), !pickedUp(id),
              !CalledToday.isCallable(id, anyTimeZone: true), let s = step(for: id) else { return false }
        // Called today on their last call day: done for good after today.
        let calledToday = DialHistory.person(id).dials.contains { cal.isDateInToday($0) }
        return !(s.isLast && calledToday)
    }

    /// "Day 5 · call 3 of 5 · no voicemail" for the card.
    static func label(for id: String) -> String {
        if pickedUp(id) { return "Picked up before" }
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
