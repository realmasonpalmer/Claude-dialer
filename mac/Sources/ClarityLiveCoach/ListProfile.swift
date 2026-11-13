import Foundation

/// "Who are these people?" from a Salesforce list: their real titles, levels, areas, industries,
/// company sizes and states, counted. Fills the box on New and Edit call list, so Claude writes
/// the script for who is really on the list. Blank fields are skipped.
enum ListProfile {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads up to 400 people on the list (two queries) and describes them in a few short lines.
    static func describe(object: String, viewID: String) async throws -> String {
        guard ["Lead", "Contact"].contains(object), !viewID.isEmpty else { throw Failure(message: "Pick a Salesforce list first.") }
        let rows = try await Salesforce.fullList(object: object, key: viewID)
        guard !rows.isEmpty else { throw Failure(message: "That list has no one on it yet.") }
        let sample = rows.prefix(400).map(\.id).filter { $0.allSatisfy { $0.isLetter || $0.isNumber } }
        let fields = object == "Lead"
            ? "Title, Industry, NumberOfEmployees, State"
            : "Title, MailingState, Account.Industry, Account.NumberOfEmployees"

        var titles: [String: (shown: String, count: Int)] = [:]
        var levels: [String: Int] = [:]
        var areas: [String: Int] = [:]
        var industries: [String: Int] = [:]
        var sizes: [String: Int] = [:]
        var states: [String: Int] = [:]
        var read = 0, withTitle = 0
        for start in stride(from: 0, to: sample.count, by: 200) {
            let list = sample[start..<min(start + 200, sample.count)].map { "'\($0)'" }.joined(separator: ",")
            for r in try await Salesforce.query("SELECT \(fields) FROM \(object) WHERE Id IN (\(list))") {
                read += 1
                let account = r["Account"] as? [String: Any]
                if let t = clean(r["Title"] as? String) {
                    withTitle += 1
                    let k = titleKey(t)
                    titles[k] = (titles[k]?.shown ?? t, (titles[k]?.count ?? 0) + 1)
                    levels[level(k), default: 0] += 1
                    if let a = area(k) { areas[a, default: 0] += 1 }
                }
                if let i = clean((r["Industry"] as? String) ?? (account?["Industry"] as? String)) { industries[i, default: 0] += 1 }
                if let n = (r["NumberOfEmployees"] as? Int) ?? (account?["NumberOfEmployees"] as? Int), n > 0 {
                    sizes[sizeBucket(n), default: 0] += 1
                }
                if let s = clean((r["State"] as? String) ?? (r["MailingState"] as? String)) { states[s, default: 0] += 1 }
            }
        }

        var lines = ["From Salesforce (\(read) of \(rows.count) people on this list):"]
        let top = titles.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.shown < $1.shown }.prefix(8)
        if !top.isEmpty { lines.append("Titles: " + top.map { "\($0.shown) (\($0.count))" }.joined(separator: ", ") + ".") }
        if let s = percents(levels, of: withTitle, skip: "Other") { lines.append("Level: \(s).") }
        if let s = percents(areas, of: withTitle) { lines.append("Area: \(s).") }
        if let s = counts(industries, n: 4) { lines.append("Industries: \(s).") }
        if let s = counts(sizes, n: 3) { lines.append("Company size (employees): \(s).") }
        if let s = counts(states, n: 4) { lines.append("Where: \(s).") }
        if lines.count == 1 { throw Failure(message: "The people on this list have no titles or company details in Salesforce yet.") }
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces

    private static func clean(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "Vice President, Sales" and "VP of Sales" count as the same title.
    private static func titleKey(_ title: String) -> String {
        var t = " " + title.lowercased() + " "
        for (from, to) in [("vice president", "vp"), ("&", " and "), (",", " "), ("-", " "), ("/", " "), (".", "")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        t = t.replacingOccurrences(of: " of ", with: " ")
        return t.split(separator: " ").joined(separator: " ")
    }

    private static func has(_ key: String, _ words: [String]) -> Bool {
        let padded = " " + key + " "
        return words.contains { padded.contains(" " + $0 + " ") }
    }

    private static func level(_ key: String) -> String {
        if has(key, ["chief", "ceo", "cfo", "cro", "cmo", "coo", "cto", "cio", "president", "founder", "co founder", "owner", "principal", "managing partner"]) { return "C-suite and owners" }
        if has(key, ["vp", "svp", "evp", "avp"]) { return "VP" }
        if has(key, ["director", "head"]) { return "Director or head" }
        if has(key, ["manager", "lead", "supervisor"]) { return "Manager" }
        return "Other"
    }

    private static func area(_ key: String) -> String? {
        if has(key, ["revops", "revenue operations", "sales operations", "sales ops", "gtm operations", "business operations"]) { return "RevOps and sales ops" }
        if has(key, ["sales", "revenue", "cro", "business development", "account executive", "partnerships"]) { return "Sales" }
        if has(key, ["marketing", "cmo", "growth", "demand generation"]) { return "Marketing" }
        if has(key, ["finance", "cfo", "controller", "accounting", "tax", "cpa"]) { return "Finance and accounting" }
        if has(key, ["operations", "coo"]) { return "Operations" }
        if has(key, ["technology", "cto", "cio", "it", "engineering", "information"]) { return "Tech and IT" }
        if has(key, ["hr", "people", "talent", "human resources"]) { return "People and HR" }
        if has(key, ["ceo", "founder", "co founder", "owner", "president", "principal", "partner"]) { return "Running the company" }
        return nil
    }

    private static func sizeBucket(_ n: Int) -> String {
        switch n {
        case ..<11: return "1 to 10"
        case ..<51: return "11 to 50"
        case ..<201: return "51 to 200"
        case ..<1001: return "201 to 1,000"
        default: return "over 1,000"
        }
    }

    /// "VP 45%, Director or head 30%". Only shares of 5% or more.
    private static func percents(_ d: [String: Int], of total: Int, skip: String? = nil) -> String? {
        guard total > 0 else { return nil }
        let parts = d.filter { $0.key != skip }.sorted { $0.value > $1.value }
            .map { ($0.key, Int((Double($0.value) / Double(total) * 100).rounded())) }
            .filter { $0.1 >= 5 }
            .map { "\($0.0) \($0.1)%" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "Software (40), Healthcare (12)".
    private static func counts(_ d: [String: Int], n: Int) -> String? {
        let parts = d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map { "\($0.key) (\($0.value))" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
