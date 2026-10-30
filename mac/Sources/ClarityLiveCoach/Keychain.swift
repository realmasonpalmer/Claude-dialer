import Foundation
import Security

/// API keys live in the macOS Keychain, never in files or logs.
/// All keys are kept together in one Keychain item, so macOS asks for the
/// password at most once (and, with the app's stable signature, not after updates).
enum Keychain {
    private static let service = "io.clarityconsulting.livecoach"
    private static let bundleAccount = "all-keys"

    enum Key: String, CaseIterable {
        case deepgram, anthropic
        case calendarFeed // the booking calendar's address (can be a secret link)
        case aircallID, aircallToken // Aircall API keys, for sending follow-up texts
    }

    private static var cache: [String: String]?
    private static let lock = NSLock()

    static func read(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadAll()[key.rawValue]
    }

    @discardableResult
    static func save(_ value: String, for key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all = loadAll()
        all[key.rawValue] = value
        return store(all)
    }

    static func delete(_ key: Key) {
        lock.lock(); defer { lock.unlock() }
        var all = loadAll()
        all[key.rawValue] = nil
        store(all)
    }

    // MARK: Storage

    /// Reads everything once per launch. The first time after this change, it also moves the
    /// keys saved one-by-one by older versions into the single item.
    private static func loadAll() -> [String: String] {
        if let cache { return cache }
        if let data = readItem(bundleAccount),
           let all = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = all
            return all
        }
        var migrated: [String: String] = [:]
        for key in Key.allCases {
            if let data = readItem(key.rawValue), let value = String(data: data, encoding: .utf8) {
                migrated[key.rawValue] = value
            }
        }
        cache = migrated
        if !migrated.isEmpty { store(migrated) }
        return migrated
    }

    @discardableResult
    private static func store(_ all: [String: String]) -> Bool {
        cache = all
        guard let data = try? JSONEncoder().encode(all) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bundleAccount,
        ]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecAttrLabel as String] = "Clarity Live Coach keys"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func readItem(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
