import Foundation
import Observation
import Security

/// Everything saved on this Mac, in ~/Library/Application Support/ClarityDialer:
/// - config.json: outbound settings and scripts
/// - attempts.jsonl: one line per attempt change, append-only (last line per id wins), so a crash loses nothing.
@Observable @MainActor
final class Store {
    var settings = OutboundSettings() { didSet { saveConfig() } }
    var scripts: [Script] = [] { didSet { saveConfig() } }
    var selectedScriptID: UUID? { didSet { saveConfig() } }
    private(set) var attempts: [Attempt] = []

    var script: Script? { scripts.first { $0.id == selectedScriptID } ?? scripts.first }

    private let folder: URL
    private var loading = true

    private struct Config: Codable {
        var settings: OutboundSettings
        var scripts: [Script]
        var selectedScriptID: UUID?
    }

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClarityDialer", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: data) {
            settings = c.settings
            scripts = c.scripts
            selectedScriptID = c.selectedScriptID
        }
        if scripts.isEmpty {
            scripts = [Script(name: "My script", body: """
            Hi {{FirstName}}, it's {{Rep}}. Did I catch you at a bad time?

            (Paste your script here: Settings > Script. Merge fields like {{FirstName}} and {{Company}} fill in for each person.)
            """)]
        }
        attempts = Self.readAttempts(attemptsURL)
        loading = false
    }

    // MARK: Attempts

    /// Adds or replaces an attempt (by id) and appends it to the log.
    func save(_ a: Attempt) {
        if let i = attempts.firstIndex(where: { $0.id == a.id }) { attempts[i] = a } else { attempts.append(a) }
        guard var line = try? Self.encoder.encode(a) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: attemptsURL) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: attemptsURL)
        }
    }

    func attempts(for leadID: String) -> [Attempt] {
        let k = History.key(leadID)
        return attempts.filter { History.key($0.leadID) == k }
    }

    /// Logged but not yet in Salesforce (offline, or Salesforce said no). Retried on launch.
    var unsynced: [Attempt] { attempts.filter(\.needsSync) }

    // MARK: Files

    private var configURL: URL { folder.appendingPathComponent("config.json") }
    private var attemptsURL: URL { folder.appendingPathComponent("attempts.jsonl") }
    var folderURL: URL { folder }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static func readAttempts(_ url: URL) -> [Attempt] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var byID: [UUID: Attempt] = [:]
        var order: [UUID] = []
        for line in text.split(separator: "\n") {
            guard let a = try? d.decode(Attempt.self, from: Data(line.utf8)) else { continue }
            if byID[a.id] == nil { order.append(a.id) }
            byID[a.id] = a
        }
        return order.compactMap { byID[$0] }
    }

    private func saveConfig() {
        guard !loading else { return }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(Config(settings: settings, scripts: scripts, selectedScriptID: selectedScriptID)) {
            try? data.write(to: configURL, options: .atomic)
        }
    }
}

/// API keys and sign-in tokens, in the macOS Keychain (one item, so macOS asks at most once).
enum Keychain {
    enum Key: String { case aircallID, aircallToken, sfClientID, sfAccess, sfRefresh, sfInstance }

    private static let service = "io.clarityconsulting.dialer"
    private static let account = "keys"
    private static let lock = NSLock()
    private static var cache: [String: String]?

    static func read(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        return all()[key.rawValue]
    }

    static func save(_ value: String?, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        var a = all()
        a[key.rawValue] = value
        cache = a
        guard let data = try? JSONEncoder().encode(a) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) != errSecSuccess {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func all() -> [String: String] {
        if let cache { return cache }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let found = SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
        let a = found ? ((item as? Data).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]) : [:]
        cache = a
        return a
    }
}
