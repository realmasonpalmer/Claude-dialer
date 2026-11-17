import Foundation

/// The house rules for every line the rep reads, checked in code (the model sometimes breaks them).
/// Used on new scripts now; the live coach will use the same check.
enum Guardrail {
    static let banned = ["awesome", "super excited", "beautiful day", "my friend", "brother", "to be honest",
                         "selected", "assigned", "referred", "certified", "replace", "never messes up",
                         "roadmap", "transformation", "maturity", "enablement", "digital"]
    private static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                               "tomorrow", "next week"]

    /// What's wrong with a line, or [] if it's fine.
    /// - long: voicemails, texts and LinkedIn notes may run past 25 words.
    /// - endsCall: the row ends the call, so it needn't end with a question.
    static func problems(_ line: String, long: Bool = false, endsCall: Bool = false, allowTimes: Bool = false) -> [String] {
        let say = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !say.isEmpty, !say.lowercased().hasPrefix("show nothing") else { return [] }
        var out: [String] = []
        let words = say.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if !long, words > 25 { out.append("\(words) words (max 25)") }
        let questions = say.filter { $0 == "?" }.count
        if !long, questions > 1 { out.append("more than one question") }
        if !long, !endsCall, !say.hasSuffix("?") { out.append("doesn't end with a question") }
        // All-caps abbreviations, except AI and [slots].
        let noSlots = say.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        let caps = noSlots.matches(#"\b[A-Z]{2,}\b"#).filter { $0 != "AI" }
        if !caps.isEmpty { out.append("abbreviation: " + caps.joined(separator: ", ")) }
        let lower = say.lowercased()
        let hits = banned.filter { lower.contains($0) }
        if !hits.isEmpty { out.append("banned: " + hits.joined(separator: ", ")) }
        if say.contains("$") || say.contains("%") || lower.range(of: #"\d+\s*(dollar|percent)"#, options: .regularExpression) != nil {
            out.append("money or percent")
        }
        if say.contains("\u{2014}") { out.append("em dash") }
        let timeLike = lower.range(of: #"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)"#, options: .regularExpression) != nil
        if !allowTimes, timeLike || days.contains(where: { noSlots.lowercased().contains($0) }) { out.append("a made-up day or time (use [Slot A])") }
        if lower.contains("show the") || lower.contains("show s") { out.append("an instruction, not a real line") }
        return out
    }

    struct Issue { let id: String; let say: String; let problems: [String] }

    /// Checks every Say line in a backbone script (rows with " | " under a header with a Say column).
    static func lint(script: String) -> [Issue] {
        var issues: [Issue] = []
        var sayCol: Int?
        var thenCol: Int?
        var long = false
        for raw in script.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.contains("VOICEMAIL") || upper.hasPrefix("TEXTS") || upper.hasPrefix("LINKEDIN") { if !line.contains("|") { long = true } }
            else if !line.contains("|"), line == upper, line.count > 2, line.count < 40 { long = false } // a new section title
            guard line.contains("|") else { continue }
            let cols = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if let i = cols.firstIndex(where: { $0 == "Say" || $0 == "Send" }) {
                sayCol = i; thenCol = cols.firstIndex(of: "Then"); continue // a header row
            }
            guard let s = sayCol, cols.count > s else { continue }
            let then = thenCol.flatMap { cols.count > $0 ? cols[$0].lowercased() : nil } ?? ""
            let ends = ["end", "show nothing", "directory", "wait"].contains { then.contains($0) }
            let p = problems(cols[s], long: long, endsCall: ends)
            if !p.isEmpty { issues.append(Issue(id: cols[0], say: cols[s], problems: p)) }
        }
        return issues
    }
}

private extension String {
    func matches(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
