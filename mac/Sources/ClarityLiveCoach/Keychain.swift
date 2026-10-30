import Foundation
import Security

/// API keys live in the macOS Keychain, never in files or logs.
enum Keychain {
    private static let service = "io.clarityconsulting.livecoach"

    enum Key: String {
        case deepgram, anthropic
        case calendarFeed // the booking calendar's iCal address (can be a secret link)
        case aircallID, aircallToken // Aircall API keys, for sending follow-up texts
    }

    /// Read each key once per launch. macOS may ask for the login password on a
    /// Keychain read after an app update, so we never want to ask mid-call.
    private static var cache: [Key: String] = [:]
    private static let lock = NSLock()

    static func read(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let value = readFromKeychain(key)
        if let value { cache[key] = value }
        return value
    }

    private static func readFromKeychain(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: Key) {
        lock.lock(); cache[key] = nil; lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    @discardableResult
    static func save(_ value: String, for key: Key) -> Bool {
        lock.lock(); cache[key] = value; lock.unlock()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
