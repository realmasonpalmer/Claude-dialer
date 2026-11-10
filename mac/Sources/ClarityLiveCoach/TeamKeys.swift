import AppKit
import CommonCrypto
import CryptoKit
import SwiftUI

/// One locked file with every team key, so a new rep imports it instead of doing 8 setup steps.
/// The file is AES-GCM encrypted with a key made from a passcode (PBKDF2-SHA256, 200,000 rounds,
/// random salt). Without the passcode it's unreadable. It's shared privately (Slack DM, Drive),
/// never through GitHub, and the keys go straight into the Mac's Keychain.
enum TeamKeys {
    /// Team-wide keys. Never anyone's personal Salesforce session unless the exporter chooses to share it.
    static let keys: [Keychain.Key] = [.deepgram, .anthropic, .calendarFeed, .aircallID, .aircallToken, .sfClientID, .bugWebhook]
    /// The exporter's Salesforce sign-in. Clarity shares one login, so it can be included.
    static let salesforceSession: [Keychain.Key] = [.sfAccess, .sfRefresh, .sfInstance]
    /// Team settings that go with the keys (the shared Aircall number, booking hours, Salesforce address).
    static let numberPrefs = [PrefKey.aircallNumberID, PrefKey.bookingStartHour, PrefKey.bookingEndHour, PrefKey.bookingMinutes]
    static let textPrefs = [PrefKey.sfLoginHost]

    struct Contents: Codable {
        var keys: [String: String] = [:]
        var numbers: [String: Int] = [:]
        var texts: [String: String] = [:]
        var from = ""
        var made = Date()
    }

    /// The file on disk: what's needed to unlock it, and the locked box.
    private struct File: Codable {
        var format = "clarity-team-keys"
        var version = 1
        var rounds: Int
        var salt: String
        var box: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let fileExtension = "claritykeys"
    private static let rounds = 200_000

    // MARK: Export

    /// Everything to share, locked with the passcode.
    static func export(passcode: String, includeSalesforceSignIn: Bool) throws -> Data {
        var c = Contents()
        for key in keys + (includeSalesforceSignIn ? salesforceSession : []) {
            if let value = Keychain.read(key) { c.keys[key.rawValue] = value }
        }
        let d = UserDefaults.standard
        for name in numberPrefs { if let n = d.object(forKey: name) as? Int, n != 0 { c.numbers[name] = n } }
        for name in textPrefs { if let s = d.string(forKey: name), !s.isEmpty { c.texts[name] = s } }
        c.from = Prefs.repName
        guard !c.keys.isEmpty else { throw Failure(message: "This Mac has no keys to share yet.") }

        let salt = randomBytes(16)
        let key = try deriveKey(passcode, salt: salt, rounds: rounds)
        let plain = try JSONEncoder().encode(c)
        guard let box = try AES.GCM.seal(plain, using: key).combined else { throw Failure(message: "Couldn't lock the file.") }
        let file = File(rounds: rounds, salt: salt.base64EncodedString(), box: box.base64EncodedString())
        return try JSONEncoder().encode(file)
    }

    // MARK: Import

    /// Unlocks the file and saves everything on this Mac. Returns what was imported.
    @discardableResult
    static func importFile(_ data: Data, passcode: String) throws -> Contents {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == "clarity-team-keys",
              let salt = Data(base64Encoded: file.salt), let boxed = Data(base64Encoded: file.box) else {
            throw Failure(message: "That isn't a team keys file.")
        }
        let key = try deriveKey(passcode, salt: salt, rounds: file.rounds)
        guard let box = try? AES.GCM.SealedBox(combined: boxed), let plain = try? AES.GCM.open(box, using: key),
              let c = try? JSONDecoder().decode(Contents.self, from: plain) else {
            throw Failure(message: "That passcode doesn't match. Check it and try again.")
        }
        for (name, value) in c.keys {
            if let k = Keychain.Key(rawValue: name), keys.contains(k) || salesforceSession.contains(k) {
                Keychain.save(value, for: k)
            }
        }
        let d = UserDefaults.standard
        for (name, n) in c.numbers where numberPrefs.contains(name) { d.set(n, forKey: name) }
        for (name, s) in c.texts where textPrefs.contains(name) { d.set(s, forKey: name) }
        ActivityLog.add("Team keys imported (\(c.keys.count) keys, from \(c.from.isEmpty ? "a teammate" : c.from))")
        return c
    }

    /// Picks this rep's own Aircall user (calls ring on their line), matched to the name on this Mac
    /// (or the first name they typed). Only when exactly one person matches. Their first name for
    /// openers then comes from that Aircall account.
    static func matchAircallUser() async {
        guard Aircall.isSetUp, let users = try? await Aircall.users() else { return }
        if let id = Aircall.userID {
            if let me = users.first(where: { $0.id == id }) { useFirstName(of: me) }
            return
        }
        func clean(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        let full = clean(NSFullUserName())
        let first = clean(Prefs.repName.isEmpty ? String(full.split(separator: " ").first ?? "") : Prefs.repName)
        var matches = users.filter { clean($0.name) == full }
        if matches.isEmpty, !first.isEmpty {
            matches = users.filter { clean($0.name).split(separator: " ").first.map(String.init) == first }
        }
        guard matches.count == 1, let user = matches.first else { return }
        UserDefaults.standard.set(user.id, forKey: PrefKey.aircallUserID)
        useFirstName(of: user)
        ActivityLog.add("Aircall: calls are made as \(user.name) (matched by name)")
    }

    /// Sets the rep's first name from their Aircall account, unless they already typed one.
    static func useFirstName(of user: Aircall.User) {
        guard Prefs.repName.isEmpty, let first = user.name.split(separator: " ").first else { return }
        UserDefaults.standard.set(String(first), forKey: PrefKey.repName)
    }

    // MARK: Crypto

    private static func deriveKey(_ passcode: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let pass = Array(passcode.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 passcode, pass.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                 &out, out.count)
        }
        guard status == kCCSuccess else { throw Failure(message: "Couldn't use that passcode.") }
        return SymmetricKey(data: out)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

/// Import team keys (new rep) or export them (whoever has everything set up).
struct TeamKeysView: View {
    enum Mode: String, Identifiable {
        case importKeys, exportKeys
        var id: String { rawValue }
    }
    let mode: Mode
    @EnvironmentObject var coach: CoachModel
    @Environment(\.dismiss) private var dismiss

    @State private var file: URL?
    @State private var passcode = ""
    @State private var confirm = ""
    @State private var includeSignIn = true
    @State private var working = false
    @State private var message: String?
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .importKeys ? "Import team keys" : "Export team keys").font(.title2.weight(.semibold))
            if mode == .importKeys { importForm } else { exportForm }
            if let message {
                Text(message).font(.callout)
                    .foregroundStyle(done ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(done ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(done ? .defaultAction : .cancelAction)
                if !done {
                    Button(mode == .importKeys ? "Import" : "Save file...") {
                        Task { mode == .importKeys ? await runImport() : runExport() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || working)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var ready: Bool {
        mode == .importKeys ? file != nil && !passcode.isEmpty : passcode.count >= 8 && passcode == confirm
    }

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your team lead sends you a keys file and a passcode. This sets up Claude, Deepgram, Salesforce, Aircall and the booking calendar in one step.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(file == nil ? "Choose the file..." : "Change file...") { chooseFile() }
                if let file { Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            SecureField("Passcode", text: $passcode).textFieldStyle(.roundedBorder)
        }
    }

    private var exportForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saves every key on this Mac into one locked file. Send the file and the passcode to your rep separately (for example, the file in Slack and the passcode by text). Never put it on GitHub.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Passcode (8 or more characters)", text: $passcode).textFieldStyle(.roundedBorder)
            SecureField("Type it again", text: $confirm).textFieldStyle(.roundedBorder)
            Toggle("Include my Salesforce sign-in", isOn: $includeSignIn)
            Text(includeSignIn ? "Reps won't need to sign in to Salesforce. Their status saves show as you."
                               : "Each rep signs in to Salesforce once, as themselves.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.level = .modalPanel // above the coach, which floats over Salesforce
        if panel.runModal() == .OK { file = panel.url }
    }

    private func runImport() async {
        guard let file else { return }
        working = true
        defer { working = false }
        do {
            let c = try TeamKeys.importFile(try Data(contentsOf: file), passcode: passcode)
            passcode = ""
            if let feed = c.keys[Keychain.Key.calendarFeed.rawValue] { await coach.availability.useFeed(feed) }
            await TeamKeys.matchAircallUser()
            Connections.shared.refresh()
            if Salesforce.isConnected { await coach.leads.start() }
            coach.refreshOpener()
            var left: [String] = []
            if !Salesforce.isConnected { left.append("sign in to Salesforce") }
            if Aircall.isSetUp && Aircall.userID == nil { left.append("pick yourself in Aircall") }
            else if Prefs.repName.isEmpty { left.append("type your first name") }
            message = "Imported \(c.keys.count) keys." + (left.isEmpty ? " You're set." : " Last step in Setup: " + left.joined(separator: " and ") + ".")
            done = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func runExport() {
        do {
            let data = try TeamKeys.export(passcode: passcode, includeSalesforceSignIn: includeSignIn)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Clarity Team Keys.\(TeamKeys.fileExtension)"
            panel.level = .modalPanel
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            passcode = ""; confirm = ""
            message = "Saved. Send the file and the passcode separately, never on GitHub."
            done = true
            ActivityLog.add("Team keys exported")
        } catch {
            message = error.localizedDescription
        }
    }
}
