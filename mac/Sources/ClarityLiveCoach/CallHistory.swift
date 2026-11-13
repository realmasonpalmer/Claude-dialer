import Foundation

/// Calls the whole team made, from Salesforce: Aircall logs every outbound call as a Task
/// (Type "Call", Call Type "Outbound") on the Lead or Contact. Plus the Picked Up Cold Call box.
/// Merged with this Mac's own calls, so the 5 day plan is right on a new install and when
/// teammates call the same list. Saved on this Mac, and refreshed when a list loads.
enum CallHistory {
    private static var d: UserDefaults { .standard }
    private static let lock = NSLock()
    private static var loaded = false
    /// Record Id (first 15 characters) -> the days anyone called them, start of each day here.
    private static var days: [String: [Date]] = [:]
    /// Record Ids with Picked Up Cold Call checked.
    private static var picked: Set<String> = []
    /// When each person was last looked up while the app has been open.
    private static var checkedAt: [String: Date] = [:]

    /// How far back to read calls. The plan takes 16 days; this is plenty, and keeps queries small.
    private static let lookBackDays = 120
    /// Ask Salesforce about the same person at most this often.
    private static let refreshEvery: TimeInterval = 600

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func key(_ id: String) -> String { String(id.prefix(15)) }

    private static func loadSaved() {
        guard !loaded else { return }
        loaded = true
        let saved = (d.dictionary(forKey: PrefKey.sfCallDays) as? [String: [String]]) ?? [:]
        days = saved.mapValues { $0.compactMap { dayFormat.date(from: $0) } }
        picked = Set(d.stringArray(forKey: PrefKey.sfPickedUp) ?? [])
    }

    /// The days anyone on the team called them (from Salesforce), oldest first.
    static func callDays(_ id: String) -> [Date] {
        lock.withLock {
            loadSaved()
            return days[key(id)] ?? []
        }
    }

    /// Picked Up Cold Call is checked on their record.
    static func pickedUp(_ id: String) -> Bool {
        lock.withLock {
            loadSaved()
            return picked.contains(key(id))
        }
    }

    /// Reads call days and the Picked Up Cold Call box for everyone on a list (100 at a time).
    static func load(ids: [String], object: String) async {
        guard Salesforce.isConnected, ["Lead", "Contact"].contains(object) else { return }
        let now = Date()
        let todo: [String] = lock.withLock {
            loadSaved()
            return ids.filter { id in
                id.allSatisfy { $0.isLetter || $0.isNumber }
                    && now.timeIntervalSince(checkedAt[key(id)] ?? .distantPast) > refreshEvery
            }
        }
        guard !todo.isEmpty else { return }
        var found: [String: Set<String>] = [:]
        var pickedNow: Set<String> = []
        var checked: [String] = []
        for start in stride(from: 0, to: todo.count, by: 100) {
            let chunk = Array(todo[start..<min(start + 100, todo.count)])
            let list = chunk.map { "'\($0)'" }.joined(separator: ",")
            do {
                // One row per person per day called (any rep). Fathom notes are also "Call" Tasks,
                // so only Aircall's outbound calls count.
                let calls = try await Salesforce.query(
                    "SELECT WhoId, DAY_ONLY(convertTimezone(CreatedDate)) callDay FROM Task "
                    + "WHERE WhoId IN (\(list)) AND Type = 'Call' AND CallType = 'Outbound' "
                    + "AND CreatedDate = LAST_N_DAYS:\(lookBackDays) "
                    + "GROUP BY WhoId, DAY_ONLY(convertTimezone(CreatedDate))")
                for r in calls {
                    guard let who = r["WhoId"] as? String, let day = r["callDay"] as? String else { continue }
                    found[key(who), default: []].insert(day)
                }
                let boxes = try await Salesforce.query(
                    "SELECT Id, Picked_Up_Cold_Call__c FROM \(object) WHERE Id IN (\(list))")
                for r in boxes where (r["Picked_Up_Cold_Call__c"] as? Bool) == true {
                    if let id = r["Id"] as? String { pickedNow.insert(key(id)) }
                }
                checked += chunk.map { key($0) }
            } catch {
                ActivityLog.problem("Call history: couldn't read calls from Salesforce: \(error.localizedDescription)")
            }
        }
        guard !checked.isEmpty else { return }
        let saved: (days: [String: [String]], picked: [String]) = lock.withLock {
            for k in checked {
                checkedAt[k] = now
                let list = (found[k] ?? []).sorted().compactMap { dayFormat.date(from: $0) }
                days[k] = list.isEmpty ? nil : list
                if pickedNow.contains(k) { picked.insert(k) } else { picked.remove(k) }
            }
            return (days.mapValues { $0.map { dayFormat.string(from: $0) } }, Array(picked))
        }
        d.set(saved.days, forKey: PrefKey.sfCallDays)
        d.set(saved.picked, forKey: PrefKey.sfPickedUp)
        let withCalls = checked.filter { found[$0] != nil }.count
        ActivityLog.add("Call history: read \(checked.count) people from Salesforce (\(withCalls) called before, \(checked.filter { pickedNow.contains($0) }.count) picked up)")
    }
}
