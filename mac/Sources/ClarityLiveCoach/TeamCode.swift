import AppKit
import Foundation

/// Hands the team's keys to a new teammate without putting them on GitHub (the code is public).
/// A rep copies a one-line setup command from Settings and sends it in a private message.
/// The new Mac installs the app with the keys already saved in its Keychain.
/// The same text can also be pasted into Setup on a Mac that already has the app.
@MainActor
enum TeamCode {
    /// Shared by the whole team. Personal sign-ins (Salesforce tokens, the Aircall user) stay out.
    private static let sharedKeys: [Keychain.Key] = [
        .anthropic, .deepgram, .aircallID, .aircallToken, .sfClientID, .calendarFeed, .bugWebhook,
    ]
    private static let numberKey = "aircallNumberID"
    private static let hostKey = "sfLoginHost"
    private static let prefix = "CLC1-"
    /// get.sh saves the code here before the app opens; the app moves it into the Keychain at launch.
    static let pendingKey = "pendingTeamCode"
    private static let calendarLabel = "booking calendar"

    /// The team code from this Mac's saved keys, or nil if nothing is saved yet.
    static func make() -> String? {
        var all: [String: String] = [:]
        for key in sharedKeys {
            if let value = Keychain.read(key), !value.isEmpty { all[key.rawValue] = value }
        }
        if let number = Aircall.numberID { all[numberKey] = String(number) }
        if let host = UserDefaults.standard.string(forKey: hostKey), !host.isEmpty { all[hostKey] = host }
        guard !all.isEmpty, let data = try? JSONEncoder().encode(all) else { return nil }
        return prefix + data.base64EncodedString()
    }

    /// The Terminal command that installs the app with these keys in it.
    static func installCommand(code: String) -> String {
        let script = "https://raw.githubusercontent.com/\(Updater.repo)/\(Updater.branch)/mac/scripts/get.sh"
        // No quote marks anywhere: Slack, Notes and Messages turn them into curly quotes, and then the command fails.
        return "CLARITY_TEAM_CODE=\(code) bash <(curl -fsSL \(script))"
    }

    /// Pulls the code out of whatever was pasted: just the code, or the whole setup command.
    /// Reads base64 letters and stops at the first space, quote or other character, or after the "=" padding.
    private static func extractCode(_ text: String) -> String? {
        guard let start = text.range(of: prefix) else { return nil }
        let letters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var body = ""
        var padding = 0
        for ch in text[start.upperBound...] {
            if ch == "=" {
                body.append(ch); padding += 1
                if padding == 2 { break }
            } else if padding == 0, letters.contains(ch) {
                body.append(ch)
            } else {
                break
            }
        }
        return body.isEmpty ? nil : body
    }

    /// What's inside the code, in plain words (for the message after copying).
    static func contents() -> [String] {
        var parts: [String] = []
        if Keychain.read(.anthropic) != nil || Keychain.read(.deepgram) != nil { parts.append("AI keys") }
        if Keychain.read(.aircallID) != nil { parts.append("Aircall keys and number") }
        if Keychain.read(.sfClientID) != nil { parts.append("Salesforce Consumer Key") }
        if Keychain.read(.calendarFeed) != nil { parts.append("booking calendar") }
        if Keychain.read(.bugWebhook) != nil { parts.append("bug reports") }
        return parts
    }

    /// Saves the keys from a code (or from a whole setup command).
    /// Returns what was added, in plain words, or nil if the text isn't a team code.
    @discardableResult
    static func apply(_ text: String) -> [String]? {
        guard let body = extractCode(text),
              let data = Data(base64Encoded: body),
              let all = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }

        var added: [String] = []
        func note(_ label: String) { if !added.contains(label) { added.append(label) } }
        for key in sharedKeys {
            guard let value = all[key.rawValue]?.trimmed, !value.isEmpty else { continue }
            Keychain.save(value, for: key)
            switch key {
            case .anthropic, .deepgram: note("AI keys")
            case .aircallID, .aircallToken: note("Aircall keys")
            case .sfClientID: note("Salesforce Consumer Key")
            case .calendarFeed: note(calendarLabel)
            case .bugWebhook: note("bug reports")
            default: break
            }
        }
        if let number = all[numberKey].flatMap({ Int($0) }), number != 0 {
            UserDefaults.standard.set(number, forKey: numberKey)
            note("Aircall number")
        }
        if let host = all[hostKey], !host.isEmpty {
            UserDefaults.standard.set(host, forKey: hostKey)
        }
        ActivityLog.add("Team code added: \(added.joined(separator: ", "))")
        return added
    }

    /// Loads the booking calendar right away if the code had one (the app read it at launch).
    static func loadCalendar(_ added: [String], into availability: Availability) {
        guard added.contains(calendarLabel), let feed = Keychain.read(.calendarFeed) else { return }
        Task { await availability.useFeed(feed) }
    }

    /// Runs once at launch, before anything reads the keys.
    static func applyPending() {
        let defaults = UserDefaults.standard
        guard let code = defaults.string(forKey: pendingKey) else { return }
        defaults.removeObject(forKey: pendingKey)
        if apply(code) == nil { ActivityLog.add("The team code from the setup command didn't look right.") }
    }

    /// Copies the setup command. Returns the message to show.
    static func copyInstallCommand() -> String {
        guard let code = make() else { return "No keys saved yet. Finish your own Setup first." }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand(code: code), forType: .string)
        let what = contents().joined(separator: ", ")
        return "Copied. It holds your \(what). Send it in a private Slack DM, never a channel. They paste it in Terminal and press Enter."
    }
}
