import CryptoKit
import Foundation

/// The text and LinkedIn templates written in a campaign script, found by Claude reading the
/// whole script (so any heading, layout or wording works). Read once per version of the script,
/// then saved on this Mac. Copied word for word: placeholders like [Name] stay as written.
@MainActor
final class ScriptTemplates {
    static let shared = ScriptTemplates()

    struct Found: Codable, Equatable {
        /// Texts in the order they're sent: the missed call text first, then follow-ups.
        var texts: [String] = []
        var linkedinNote: String?
        var linkedinMessage: String?
    }

    private var cache: [String: Found]
    private var reading: Set<String> = []
    /// Scripts Claude couldn't read, and when: tried again after 10 minutes, not on every card.
    private var failed: [String: Date] = [:]
    private var waiting: [String: [() -> Void]] = [:]
    private static let storeKey = "scriptTemplates2" // 2: re-read scripts after the heading fix

    private init() {
        cache = UserDefaults.standard.data(forKey: Self.storeKey)
            .flatMap { try? JSONDecoder().decode([String: Found].self, from: $0) } ?? [:]
    }

    /// The templates for this script, if already read. If not, starts reading it and calls
    /// `onReady` once it's done (only if it found something).
    func templates(for script: String, onReady: (() -> Void)? = nil) -> Found? {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard script.count > 20 else { return nil }
        let key = Self.key(script)
        if let found = cache[key] { return found }
        if let onReady { waiting[key, default: []].append(onReady) }
        guard !reading.contains(key), failed[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true,
              let apiKey = Keychain.read(.anthropic) else { return nil }
        reading.insert(key)
        Task { [weak self] in
            let found = await Self.read(script, apiKey: apiKey)
            guard let self else { return }
            self.reading.remove(key)
            guard let found else { self.waiting[key] = nil; self.failed[key] = Date(); return }
            self.cache[key] = found
            if let data = try? JSONEncoder().encode(self.cache) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
            ActivityLog.add("Script templates: \(found.texts.count) text(s), LinkedIn note \(found.linkedinNote == nil ? "no" : "yes"), LinkedIn message \(found.linkedinMessage == nil ? "no" : "yes")")
            let calls = self.waiting[key] ?? []
            self.waiting[key] = nil
            calls.forEach { $0() }
        }
        return nil
    }

    /// Drops a heading or note in front of a quoted template, like
    /// `Connection request (under 200 characters) “Hi [Name], ...”` → `Hi [Name], ...`.
    /// Only when the words before the quote aren't the message itself (no greeting in them).
    static func cleanTemplate(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = t.firstIndex(where: { "“\"".contains($0) }), q != t.startIndex {
            let before = t[..<q].lowercased()
            let greeting = ["hi ", "hey ", "hello ", "good morning", "good afternoon"].contains { before.contains($0) }
            if !greeting, before.count < 160 { t = String(t[q...]) }
        }
        // The quote marks around it, and a closing quote with nothing after it.
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"“”*_"))
        if let close = t.firstIndex(of: "”"), t[t.index(after: close)...].trimmingCharacters(in: .whitespaces).count < 3 {
            t = String(t[..<close])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ script: String, apiKey: String) async -> Found? {
        let client = CoachSpeed.balanced.client(apiKey: apiKey)
        let system = "You pull message templates out of sales scripts. You copy, you never write. Answer with JSON only."
        let user = """
        Below is a cold calling campaign and its script. Find the messages the rep sends by text (SMS) or on LinkedIn.
        Headings can be anything ("Text after a missed call", "If no reply in 2 days", "LinkedIn connection
        request", "DM", and so on), or there may be no heading at all. Read for meaning.

        Return exactly this JSON and nothing else:
        {"texts": ["...", "..."], "linkedinNote": "..." or null, "linkedinMessage": "..." or null}

        - texts: every text message template, in the order they're sent. The first one is the text after a missed
          call or voicemail; then follow-ups ("if no reply", "day 3", and so on). If the script gives two versions
          of the same message, keep only the first. Empty list if there are none.
        - linkedinNote: the LinkedIn connection request / connection note template, or null.
        - linkedinMessage: the LinkedIn direct message template (for people already connected), or null.
          If one template is labeled as both ("LinkedIn message/connection request"), put it in both.
        - Copy each one exactly: same words, same placeholders ([Name], {first name}, [Your Name]). Drop only
          the quote marks around it. Never include the heading, label or notes before or after it, like
          "Connection request (under 200 characters, so it fits any account)". Start at the message's first word.
        - Don't use voicemail scripts, call openers or email templates. Don't write anything that isn't in the script.

        Campaign and script:
        \(script)
        """
        var text = ""
        do {
            try await client.stream(system: system, user: user) { text = $0 }
        } catch {
            ActivityLog.problem("Script templates: couldn't read the script: \(error.localizedDescription)")
            return nil
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ActivityLog.problem("Script templates: Claude's answer wasn't readable")
            return nil
        }
        func clean(_ v: Any?) -> String? {
            guard let raw = v as? String else { return nil }
            let s = cleanTemplate(raw)
            guard s.count >= 10 else { return nil }
            return s
        }
        return Found(texts: ((json["texts"] as? [Any]) ?? []).compactMap(clean),
                     linkedinNote: clean(json["linkedinNote"]),
                     linkedinMessage: clean(json["linkedinMessage"]))
    }
}
