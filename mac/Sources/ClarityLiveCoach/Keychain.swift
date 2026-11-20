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
        case aircallID, aircallToken // Aircall API keys, for texts and placing calls
        case sfClientID, sfAccess, sfRefresh, sfInstance // Salesforce sign-in
        case bugWebhook // Slack Incoming Webhook for bug reports
    }

    private static var cache: [String: String]?
    private static let lock = NSLock()
    /// macOS wants the rep's OK before giving this copy of the app its saved keys (after an update
    /// changed the app's signature). Reads never wait for that prompt: the app opens without the keys
    /// and shows an "Allow" button, which asks with the window on screen.
    private(set) static var needsUnlock = false

    /// Asks macOS for the saved keys, showing its password prompt. True when the keys came back.
    @discardableResult
    static func unlock() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let (data, _) = readItem(bundleAccount, allowUI: true)
        guard let data, let all = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        cache = all
        needsUnlock = false
        return true
    }

    static func read(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadAll()[key.rawValue]
    }

    @discardableResult
    static func save(_ value: String, for key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if needsUnlock { lock.unlock(); unlock(); lock.lock() } // never overwrite keys we couldn't read
        if needsUnlock { return false }
        var all = loadAll()
        all[key.rawValue] = value
        return store(all)
    }

    static func delete(_ key: Key) {
        lock.lock(); defer { lock.unlock() }
        if needsUnlock { return }
        var all = loadAll()
        all[key.rawValue] = nil
        store(all)
    }

    // MARK: Storage

    /// Reads everything once per launch. The first time after this change, it also moves the
    /// keys saved one-by-one by older versions into the single item.
    private static func loadAll() -> [String: String] {
        if let cache { return cache }
        let (data, denied) = readItem(bundleAccount, allowUI: false)
        if denied {
            // Saved keys exist, but macOS wants permission first. Don't wait on its hidden prompt.
            needsUnlock = true
            cache = [:]
            return [:]
        }
        if let data, let all = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = all
            return all
        }
        var migrated: [String: String] = [:]
        for key in Key.allCases {
            if let data = readItem(key.rawValue, allowUI: false).0, let value = String(data: data, encoding: .utf8) {
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

    /// The item's data, and whether macOS refused because it wanted to ask first.
    private static func readItem(_ account: String, allowUI: Bool) -> (Data?, denied: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowUI { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { return (nil, true) }
        guard status == errSecSuccess else { return (nil, false) }
        return (item as? Data, false)
    }
}
