import Foundation

/// What the team's real calls teach. Two jobs, both safe to fail (a failure changes nothing):
/// 1. Every 200 summarized calls, Claude boils the call notes down to a short list of lessons.
///    "Generate script" reads that list, so each new script starts smarter.
/// 2. Once a day (the first call of a new day), the day before is sent to the team's Slack channel
///    as a nameless digest: calls, scores, objections and what worked and where calls stalled.
/// Nothing here has names or transcripts. The notes were written nameless.
@MainActor
enum CallLessons {
    /// New summarized calls between lesson refreshes.
    static let every = 200
    private static var refreshing = false

    /// The current lessons, one per line, or "". Safe to read from anywhere.
    nonisolated static var text: String { UserDefaults.standard.string(forKey: "callLessonsText") ?? "" }

    /// A call's note just arrived.
    static func afterSummary(_ records: [CallRecord]) {
        let d = UserDefaults.standard
        let n = d.integer(forKey: "callLessonsCount") + 1
        d.set(n, forKey: "callLessonsCount")
        if n >= every { refresh(records) }
        Task { await sendDigestIfNew(records) }
    }

    private static func refresh(_ records: [CallRecord]) {
        guard !refreshing, Keychain.read(.anthropic) != nil else { return }
        let notes = records.suffix(every).compactMap(\.summary)
        guard notes.count >= 20 else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            var lines = ["Current lessons:\n" + (text.isEmpty ? "(none yet)" : text), "Call notes:"]
            for s in notes.suffix(200) {
                var line = "- outcome: \(s.outcome)"
                if !s.objections.isEmpty { line += "; objections: " + s.objections.joined(separator: ", ") }
                if !s.worked.isEmpty { line += "; worked: \(s.worked)" }
                if !s.failed.isEmpty { line += "; stalled: \(s.failed)" }
                lines.append(line)
            }
            let system = """
            You coach cold callers. From these nameless call notes, write the lessons that would make the next call script better.
            Keep what still holds from the current lessons, drop what the new notes disprove, add what shows up again and again.
            Rules: at most 8 lessons. Each one sentence, plain, easy to say out loud, about what to say or do. Only patterns that
            show up in several calls. Never invent facts, prices or results. No names of people or companies.
            Return only JSON: {"lessons": ["", ...]}
            """
            guard let json = try? await CallLab.ask(system: system, user: lines.joined(separator: "\n"), effort: "low"),
                  let lessons = json["lessons"] as? [String] else { return } // failed: keep the old lessons, try again next call
            let clean = lessons.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(8)
            guard !clean.isEmpty else { return }
            UserDefaults.standard.set(clean.map { "- " + $0 }.joined(separator: "\n"), forKey: "callLessonsText")
            UserDefaults.standard.set(0, forKey: "callLessonsCount")
            ActivityLog.add("Call lessons updated (\(clean.count) lessons)")
        }
    }

    // MARK: Daily digest

    private static func sendDigestIfNew(_ records: [CallRecord]) async {
        guard BugReporter.isOn else { return }
        let cal = Calendar.current
        let todayKey = Date().formatted(.iso8601.year().month().day())
        let d = UserDefaults.standard
        guard d.string(forKey: "callDigestDay") != todayKey else { return }
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) else { return }
        let day = records.filter { cal.isDate($0.date, inSameDayAs: yesterday) }
        guard !day.isEmpty else { d.set(todayKey, forKey: "callDigestDay"); return }
        let avg = day.map(\.score).reduce(0, +) / day.count
        let good = day.filter(\.good).count * 100 / day.count
        var counts: [String: Int] = [:]
        for o in day.flatMap({ $0.summary?.objections ?? [] }) { counts[o, default: 0] += 1 }
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
        let worked = day.compactMap { $0.summary?.worked }.filter { !$0.isEmpty }.prefix(3).map { "• " + $0 }.joined(separator: "\n")
        let stalled = day.compactMap { $0.summary?.failed }.filter { !$0.isEmpty }.prefix(3).map { "• " + $0 }.joined(separator: "\n")
        let rep = d.string(forKey: PrefKey.repName) ?? "?"
        let text = """
        :bar_chart: *Call learning: \(rep), \(yesterday.formatted(.iso8601.year().month().day()))*
        \(day.count) answered calls · average score \(avg) · \(good)% good · goal reached \(day.filter(\.goal).count)
        Top objections: \(top.isEmpty ? "none" : top)
        \(worked.isEmpty ? "" : "*What worked:*\n" + worked)
        \(stalled.isEmpty ? "" : "*Where it stalled:*\n" + stalled)
        """
        if await BugReporter.digest(text) { d.set(todayKey, forKey: "callDigestDay") }
    }
}
