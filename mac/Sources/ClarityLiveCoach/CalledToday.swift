import Foundation

/// Who's been called today, by Salesforce Id. One record for both call lists (the Salesforce
/// list and the list open in Chrome), so a person called in one mode isn't called again in the other.
/// Starts fresh each day.
enum CalledToday {
    private static var day = ""
    private static var ids_: Set<String> = []
    private static var loaded = false

    static var ids: Set<String> { load(); return ids_ }

    static func add(_ id: String) {
        resetIfNewDay()
        ids_.insert(id)
        save()
    }

    static func clear() {
        load()
        ids_ = []
        save()
    }

    static func resetIfNewDay() {
        load()
        let today = Self.today
        guard day != today else { return }
        day = today
        ids_ = []
        save()
    }

    /// Can this person be called now? Not called today, not taken off the list, not out of tries,
    /// due today in the follow-up plan, and in the time zone being called (if one is picked).
    /// - Parameter anyTimeZone: true = ignore the time zone filter.
    static func isCallable(_ id: String, anyTimeZone: Bool = false) -> Bool {
        !ids.contains(id) && !RemovedList.contains(id) && !DialHistory.isMaxed(id) && Cadence.isDue(id)
            && (anyTimeZone || TimeZoneFilter.allows(id))
    }

    /// Why people on a list can't be called right now, for the "nobody left" message.
    /// Each person is counted once, in the first reason that fits.
    struct Breakdown {
        var total = 0
        var calledToday = 0
        var comeBackLater = 0
        var takenOff = 0
        var planDone = 0
    }

    static func breakdown(_ listIDs: [String]) -> Breakdown {
        var b = Breakdown()
        b.total = listIDs.count
        let called = ids
        for id in listIDs {
            if called.contains(id) { b.calledToday += 1 }
            else if RemovedList.contains(id) || DialHistory.isMaxed(id) { b.takenOff += 1 }
            else if DialHistory.person(id).pickups > 0 || Cadence.isFinished(id) { b.planDone += 1 }
            else if !Cadence.isDue(id) { b.comeBackLater += 1 }
        }
        return b
    }

    private static var today: String { Date().formatted(.iso8601.year().month().day()) }

    /// First use: today's calls from both old lists, so nothing is lost when they were merged.
    private static func load() {
        guard !loaded else { return }
        loaded = true
        let d = UserDefaults.standard
        let today = Self.today
        var all: Set<String> = []
        if d.string(forKey: PrefKey.calledDay) == today { all.formUnion(d.stringArray(forKey: PrefKey.calledToday) ?? []) }
        if d.string(forKey: PrefKey.sfCalledDay) == today { all.formUnion(d.stringArray(forKey: PrefKey.sfCalledToday) ?? []) }
        day = today
        ids_ = all
        d.removeObject(forKey: PrefKey.sfCalledDay)
        d.removeObject(forKey: PrefKey.sfCalledToday)
        save()
    }

    private static func save() {
        UserDefaults.standard.set(day, forKey: PrefKey.calledDay)
        UserDefaults.standard.set(Array(ids_), forKey: PrefKey.calledToday)
    }
}
