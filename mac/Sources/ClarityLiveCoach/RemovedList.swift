import Foundation

/// People taken off the call list from the app (Relationship Status set to
/// "Not Quality Prospect" or "Negative"). Next skips them for good, in both list kinds.
enum RemovedList {
    private static let key = "removedFromList"

    static func contains(_ id: String) -> Bool {
        ids.contains(String(id.prefix(15)))
    }

    static func add(_ id: String) {
        var all = ids
        all.insert(String(id.prefix(15)))
        UserDefaults.standard.set(Array(all), forKey: key)
    }

    static func remove(_ id: String) {
        var all = ids
        all.remove(String(id.prefix(15)))
        UserDefaults.standard.set(Array(all), forKey: key)
    }

    private static var ids: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
}
