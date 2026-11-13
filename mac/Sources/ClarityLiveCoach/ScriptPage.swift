import CryptoKit
import Foundation

/// The "My script" card: the campaign's script as one page a rep can read out loud.
/// Only spoken words, in call order (opener first). No tool rules, row IDs, texts or LinkedIn notes.
/// Claude writes the page once per version of the script and it's saved on this Mac. Until then
/// (or with no key), a quick local read of the script's "Say" lines stands in.
@MainActor
final class ScriptPage: ObservableObject {
    static let shared = ScriptPage()

    struct Section: Identifiable {
        let id: Int
        let title: String
        let lines: [String]
    }

    /// Bumped whenever a page is ready, so the card redraws.
    @Published private(set) var version = 0
    private var cache: [String: String]
    private var writing: Set<String> = []
    private var failed: [String: Date] = [:]
    private static let storeKey = "scriptPages1"

    private init() {
        cache = (UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String]) ?? [:]
    }

    private static func key(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The one page script, as sections. Starts Claude writing a better one if there isn't one yet.
    func sections(for script: String) -> [Section] {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard script.count > 20 else { return [] }
        let key = Self.key(script)
        if let page = cache[key] { return Self.split(page) }
        startWriting(script, key: key)
        return Self.quickRead(script)
    }

    /// True while Claude is still writing the page for this script.
    func isWriting(_ script: String) -> Bool {
        writing.contains(Self.key(script.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func startWriting(_ script: String, key: String) {
        guard !writing.contains(key), failed[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true,
              let apiKey = Keychain.read(.anthropic) else { return }
        writing.insert(key)
        Task { [weak self] in
            let page = await Self.write(script, apiKey: apiKey)
            guard let self else { return }
            self.writing.remove(key)
            if let page, !Self.split(page).isEmpty {
                self.cache[key] = page
                UserDefaults.standard.set(self.cache, forKey: Self.storeKey)
                ActivityLog.add("My script: one page version written (\(page.split(separator: " ").count) words)")
            } else {
                self.failed[key] = Date()
            }
            self.version += 1
        }
    }

    // MARK: Claude writes the page

    private static func write(_ script: String, apiKey: String) async -> String? {
        var client = CoachSpeed.balanced.client(apiKey: apiKey) // fast: Sonnet, no thinking
        client.maxTokens = 1500
        client.idleTimeout = 30
        client.totalTimeout = 90
        let system = """
        You turn a long cold call script (written for a software tool) into the one page script a sales rep
        reads out loud on a call. Return plain text only.

        Rules:
        - Only words the rep says to a person. No rules for the tool, no row IDs (S2, O4), no state names,
          no "sounds like" lists, no notes about what to track, no texts, no LinkedIn notes, no emails.
        - Use the script's own lines, word for word where you can. Never invent facts, numbers or offers.
        - Keep slots like [Name], [SDR], [Firm], [Day], [Time] exactly as written.
        - Order: the way a call goes. Start with the opener.
        - At most 280 words in total. Pick the lines used most; drop the rest.
        - Plain, natural language. No markdown, no bullets, no quotes around lines.

        Format, exactly: a section title in CAPITALS on its own line, then its lines, one per line.
        Use these sections, in this order, skipping any the script doesn't have:
        OPENER (1 line)
        WHY I'M CALLING (1 or 2 lines)
        QUESTIONS TO ASK (up to 4 lines)
        THE ASK (1 or 2 lines)
        IF THEY SAY (up to 5 lines, each as: Not interested: the reply)
        CLOSE (1 or 2 lines)
        GATEKEEPER (1 or 2 lines)
        VOICEMAIL (1 line)
        """
        var text = ""
        do {
            try await client.stream(system: system, user: "The script:\n\n\(script)") { text = $0 }
        } catch {
            ActivityLog.problem("My script: couldn't write the one page version: \(error.localizedDescription)")
            return nil
        }
        let page = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return page.isEmpty ? nil : page
    }

    // MARK: Reading a page into sections

    /// "OPENER" on its own line starts a section; the lines under it belong to it.
    static func split(_ page: String) -> [Section] {
        var out: [Section] = []
        var title = ""
        var lines: [String] = []
        func close() {
            if !title.isEmpty, !lines.isEmpty { out.append(Section(id: out.count, title: title, lines: lines)) }
            lines = []
        }
        for raw in page.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t*#-•"))
            guard !line.isEmpty else { continue }
            let letters = line.filter(\.isLetter)
            if letters.count >= 3, letters == letters.uppercased(), line.count <= 40 {
                close()
                title = line.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            } else if !title.isEmpty {
                lines.append(fill(line))
            }
        }
        close()
        return out
    }

    /// [SDR] becomes the rep's first name; other slots stay, so the rep knows what goes there.
    private static func fill(_ line: String) -> String {
        let name = Prefs.repName
        return name.isEmpty ? line : line.replacingOccurrences(of: "[SDR]", with: name)
    }

    // MARK: Quick local read (no Claude)

    /// Pulls the quoted "Say" lines out of a backbone-style script (tab tables under S1..., OBJECTIONS,
    /// VOICEMAIL headings). Scripts in other layouts give nothing; the card then says it's being written.
    static func quickRead(_ script: String) -> [Section] {
        // What each heading becomes, how many lines to keep, and where it goes on the page.
        func plan(_ heading: String) -> (title: String, keep: Int, order: Int)? {
            let h = heading.uppercased()
            if h.contains("OPENER") { return ("OPENER", 1, 0) }
            if h.contains("REASON") { return ("WHY I'M CALLING", 2, 1) }
            if h.contains("QUESTION") || h.contains("DISCOVERY") { return ("QUESTIONS TO ASK", 4, 2) }
            if h.contains("ASK") { return ("THE ASK", 2, 3) }
            if h.hasPrefix("OBJECTION") { return ("IF THEY SAY", 5, 4) }
            if h.contains("CLOSE") { return ("CLOSE", 2, 5) }
            if h.contains("GATEKEEPER") { return ("GATEKEEPER", 2, 6) }
            if h.hasPrefix("VOICEMAIL") { return ("VOICEMAIL", 1, 7) }
            return nil
        }
        func quoted(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let first = t.first, "“\"".contains(first) else { return nil }
            let inner = t.dropFirst()
            let end = inner.firstIndex(where: { "”\"".contains($0) }) ?? inner.endIndex
            let text = String(inner[..<end]).trimmingCharacters(in: .whitespaces)
            return text.count >= 8 ? text : nil
        }
        var found: [Int: (title: String, keep: Int, lines: [String])] = [:]
        var current: (title: String, keep: Int, order: Int)?
        for raw in script.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if !line.contains("\t") {
                // A heading: "S2: OPENER", "OBJECTIONS", "VOICEMAIL". Other plain lines are tool notes.
                let letters = line.filter(\.isLetter)
                if letters.count >= 4, letters == letters.uppercased(), line.count <= 50 { current = plan(line) }
                continue
            }
            guard let c = current else { continue }
            let cols = line.components(separatedBy: "\t")
            // The spoken line: the last column that is one whole quote (earlier ones are "sounds like").
            // (In the objections table the 2nd column is what the prospect says, never the reply.)
            guard let say = cols.dropFirst(c.title == "IF THEY SAY" ? 2 : 1).reversed().compactMap({ col -> String? in
                let t = col.trimmingCharacters(in: .whitespaces)
                guard let last = t.last, "”\"".contains(last) || t.hasSuffix("”.") else { return nil }
                return t.filter({ "“".contains($0) }).count <= 1 ? quoted(t) : nil
            }).first else { continue }
            var entry = found[c.order] ?? (c.title, c.keep, [])
            guard entry.lines.count < c.keep else { continue }
            if c.title == "IF THEY SAY", cols.count > 2, let hear = quoted(cols[1].components(separatedBy: ",")[0]) {
                entry.lines.append("\(hear.prefix(1).uppercased() + hear.dropFirst()): \(fill(say))")
            } else {
                entry.lines.append(fill(say))
            }
            found[c.order] = entry
        }
        return found.keys.sorted().enumerated().compactMap { i, k in
            guard let e = found[k], !e.lines.isEmpty else { return nil }
            return Section(id: i, title: e.title, lines: e.lines)
        }
    }
}
