import Foundation

/// People whose text failed once: never texted again.
enum TextFailed {
    private static let key = "textFailedIDs"
    static func contains(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(String(id.prefix(15)))
    }
    static func add(_ id: String) {
        var list = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        list.insert(String(id.prefix(15)))
        UserDefaults.standard.set(Array(list), forKey: key)
    }
}
