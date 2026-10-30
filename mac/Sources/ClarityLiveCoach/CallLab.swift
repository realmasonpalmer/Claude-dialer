import Foundation

// MARK: - Scoring

/// How every answered call is scored. Simple on purpose, so the reasoning is objective and visible.
enum CallScore {
    static let explanation = """
    Goal reached = 100. Otherwise: up to 50 points for talk time (full points at 3 minutes), \
    +15 if the call reached discovery, +25 if it reached closing. 50 or more counts as a good call.
    """

    static func compute(talkSeconds: Double, stages: Set<String>, goal: Bool) -> Int {
        if goal { return 100 }
        var points = min(talkSeconds, 180) / 180 * 50
        if stages.contains("Discovery") { points += 15 }
        if stages.contains("Closing") { points += 25 }
        return min(Int(points.rounded()), 95)
    }
}

// MARK: - Records

/// A short, nameless summary Claude writes after each call, so the lab can learn without keeping transcripts.
struct CallSummary: Codable {
    var objections: [String] = []
    var worked = ""
    var failed = ""
    var outcome = ""
}

struct CallRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var campaignID: UUID
    var campaignVersion: Int
    var openerID: String?
    var talkSeconds: Double
    var prospectTurns: Int
    var stages: [String]
    var goal: Bool
    var score: Int
    var summary: CallSummary?

    var good: Bool { score >= 50 }
}

struct ScriptSuggestion: Codable, Identifiable {
    var id = UUID()
    var campaignID: UUID
    var section: String   // a Campaign section key, e.g. "objections"
    var suggested: String
    var why: String
    var confidence: String

    var title: String { Campaign.sections.first { $0.json == section }?.title ?? section }
}

struct LabStats {
    struct Row: Identifiable { let id: String; let label: String; let calls: Int; let avgScore: Int; let goodRate: Int }

    var calls = 0
    var avgScore = 0
    var goodRate = 0
    var goalRate = 0
    struct Step: Identifiable { var id: String { stage }; let stage: String; let rate: Int }
    var funnel: [Step] = []
    var versions: [Row] = []
    var openers: [Row] = []
    var objections: [Row] = []
}

// MARK: - The lab

/// Keeps a local history of scored calls (no names, no transcripts), finds patterns,
/// and asks Claude for evidence-based script edits.
@MainActor
final class CallLab: ObservableObject {
    @Published private(set) var records: [CallRecord] = []
    @Published private(set) var suggestions: [ScriptSuggestion] = []
    @Published private(set) var analyzing = false
    @Published private(set) var hasNewSuggestions = false
    @Published var analysisError: String?
    @Published var learning: Bool { didSet { UserDefaults.standard.set(learning, forKey: "learnFromCalls") } }

    /// Fewest answered calls before Claude suggests edits.
    static let minimumCalls = 10
    /// After the first analysis, run again automatically every this many new calls.
    static let autoEvery = 20

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clarity Live Coach/Script Lab", isDirectory: true)
    }()
    private var recordsFile: URL { folder.appendingPathComponent("calls.json") }
    private var suggestionsFile: URL { folder.appendingPathComponent("suggestions.json") }
    private var analyzedAt: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "labAnalyzedAt") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "labAnalyzedAt") }
    }

    init() {
        learning = UserDefaults.standard.object(forKey: "learnFromCalls") as? Bool ?? true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        records = (try? JSONDecoder().decode([CallRecord].self, from: Data(contentsOf: recordsFile))) ?? []
        suggestions = (try? JSONDecoder().decode([ScriptSuggestion].self, from: Data(contentsOf: suggestionsFile))) ?? []
        prune()
    }

    func records(for campaign: Campaign) -> [CallRecord] {
        records.filter { $0.campaignID == campaign.id }
    }

    func suggestions(for campaign: Campaign) -> [ScriptSuggestion] {
        suggestions.filter { $0.campaignID == campaign.id }
    }

    /// Saves a finished call. The summary arrives a few seconds later.
    func add(_ record: CallRecord, campaign: Campaign, transcript: String) {
        guard learning else { return }
        records.append(record)
        prune()
        save()
        Task {
            if let summary = try? await Self.summarize(transcript: transcript) {
                if let i = records.firstIndex(where: { $0.id == record.id }) {
                    records[i].summary = summary
                    save()
                }
            }
            await autoAnalyze(campaign)
        }
    }

    func clearHistory() {
        records = []
        suggestions = []
        analyzedAt = [:]
        save()
    }

    func markSeen() { hasNewSuggestions = false }

    // MARK: Stats (computed locally, the same way every time)

    func stats(for campaign: Campaign) -> LabStats {
        let calls = records(for: campaign)
        var s = LabStats()
        s.calls = calls.count
        guard !calls.isEmpty else { return s }
        s.avgScore = average(calls)
        s.goodRate = rate(calls.filter(\.good).count, calls.count)
        s.goalRate = rate(calls.filter(\.goal).count, calls.count)
        s.funnel = ["Discovery", "Objection", "Closing", "Goal reached"].map { stage in
            LabStats.Step(stage: stage, rate: rate(calls.filter { $0.stages.contains(stage) || (stage == "Goal reached" && $0.goal) }.count, calls.count))
        }
        s.versions = Dictionary(grouping: calls, by: \.campaignVersion)
            .sorted { $0.key < $1.key }
            .map { row("v\($0.key)", "Version \($0.key)", $0.value) }
        s.openers = Opener.all.compactMap { opener in
            let mine = calls.filter { $0.openerID == opener.id }
            return mine.isEmpty ? nil : row(opener.id, opener.name, mine)
        }
        var byObjection: [String: [CallRecord]] = [:]
        for call in calls {
            for label in Set(call.summary?.objections ?? []) { byObjection[label, default: []].append(call) }
        }
        s.objections = byObjection
            .sorted { $0.value.count > $1.value.count }
            .prefix(6)
            .map { row($0.key, $0.key, $0.value) }
        return s
    }

    private func row(_ id: String, _ label: String, _ calls: [CallRecord]) -> LabStats.Row {
        .init(id: id, label: label, calls: calls.count, avgScore: average(calls), goodRate: rate(calls.filter(\.good).count, calls.count))
    }

    private func average(_ calls: [CallRecord]) -> Int {
        calls.isEmpty ? 0 : Int((Double(calls.map(\.score).reduce(0, +)) / Double(calls.count)).rounded())
    }

    private func rate(_ part: Int, _ whole: Int) -> Int {
        whole == 0 ? 0 : Int((Double(part) / Double(whole) * 100).rounded())
    }

    // MARK: Suggestions

    private func autoAnalyze(_ campaign: Campaign) async {
        let count = records(for: campaign).count
        let last = analyzedAt[campaign.id.uuidString]
        let due = last == nil ? count >= Self.minimumCalls : count - (last ?? 0) >= Self.autoEvery
        if due { await analyze(campaign) }
    }

    func analyze(_ campaign: Campaign) async {
        guard !analyzing, let key = Keychain.read(.anthropic) else { return }
        let calls = records(for: campaign)
        guard calls.count >= Self.minimumCalls else {
            analysisError = "Needs at least \(Self.minimumCalls) answered calls on this campaign."
            return
        }
        analyzing = true
        analysisError = nil
        defer { analyzing = false }
        do {
            let found = try await Self.suggest(campaign: campaign, stats: stats(for: campaign), calls: calls, apiKey: key)
            suggestions.removeAll { $0.campaignID == campaign.id }
            suggestions += found
            analyzedAt[campaign.id.uuidString] = calls.count
            hasNewSuggestions = !found.isEmpty
            save()
        } catch {
            analysisError = "Couldn't analyze: \(error.localizedDescription)"
        }
    }

    /// Writes the suggestion into the campaign and bumps its version, so before/after can be compared.
    func apply(_ suggestion: ScriptSuggestion, to store: CampaignStore) {
        guard var campaign = store.campaigns.first(where: { $0.id == suggestion.campaignID }),
              let section = Campaign.sections.first(where: { $0.json == suggestion.section }) else { return }
        campaign[keyPath: section.key] = suggestion.suggested
        campaign.version += 1
        store.save(campaign)
        dismiss(suggestion)
    }

    func dismiss(_ suggestion: ScriptSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        save()
    }

    // MARK: Storage

    /// Keeps the last 500 calls from the last 90 days.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        records = Array(records.filter { $0.date > cutoff }.suffix(500))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: recordsFile, options: .atomic) }
        if let data = try? JSONEncoder().encode(suggestions) { try? data.write(to: suggestionsFile, options: .atomic) }
    }

    // MARK: Claude

    private static func ask(system: String, user: String, effort: String) async throws -> [String: Any] {
        guard let key = Keychain.read(.anthropic) else { throw ClaudeClient.APIError(message: "No Anthropic key") }
        var client = ClaudeClient(apiKey: key)
        client.effort = effort
        var text = ""
        try await client.stream(system: system, user: user) { text = $0 }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw ClaudeClient.APIError(message: "Unexpected answer format")
        }
        return json
    }

    static func summarize(transcript: String) async throws -> CallSummary {
        let system = """
        You summarize a finished cold call for a coaching database. Never include names of people or companies.
        Return only JSON: {"objections": [short standard labels], "worked": "", "failed": "", "outcome": ""}.
        objections: each objection raised, as a short standard label such as "Not interested", "Send me an email",
        "No budget", "Bad time", "Already have a vendor", "Already use ChatGPT", "Security concerns", "Not the right person",
        "Building in-house", "Asked about price". Reuse these labels when they fit.
        worked: one sentence on what the rep said that moved the call forward, or "".
        failed: one sentence on where the call stalled and why, or "".
        outcome: a short phrase, like "Meeting booked" or "Hung up after opener".
        """
        let json = try await ask(system: system, user: "Transcript:\n\(transcript)", effort: "low")
        return CallSummary(
            objections: (json["objections"] as? [String]) ?? [],
            worked: (json["worked"] as? String) ?? "",
            failed: (json["failed"] as? String) ?? "",
            outcome: (json["outcome"] as? String) ?? ""
        )
    }

    static func suggest(campaign: Campaign, stats: LabStats, calls: [CallRecord], apiKey: String) async throws -> [ScriptSuggestion] {
        let keys = Campaign.sections.map { $0.json }
        let system = """
        You are a cold calling script analyst. Improve the campaign script using evidence from scored calls.
        Scoring: \(CallScore.explanation)
        Rules:
        - Suggest at most 3 changes, highest expected impact first.
        - Target the biggest drop in the funnel, or the most common objection with the weakest results.
        - Every "why" must cite the numbers behind it, with sample sizes (for example "Send me an email came up on 9 of 24 calls; only 2 of those 9 were good calls").
        - With small samples, say so and set confidence to "low". Never overstate.
        - Keep the campaign's objective and facts. Never invent features, prices, results or claims.
        - Lines must be easy to say out loud: short, plain, human.
        - "suggested" is the complete new text for that section, ready to use.
        Return only JSON: {"suggestions": [{"section": one of \(keys.joined(separator: ", ")), "suggested": "", "why": "", "confidence": "low" | "medium" | "high"}]}
        """
        var lines = [
            "Campaign (version \(campaign.version)):\n\(campaign.promptText)",
            "Answered calls: \(stats.calls). Average score: \(stats.avgScore). Good calls: \(stats.goodRate)%. Goal reached: \(stats.goalRate)%.",
            "Funnel (share of calls reaching each stage): " + stats.funnel.map { "\($0.stage) \($0.rate)%" }.joined(separator: ", "),
            "By version: " + stats.versions.map { "\($0.label): \($0.calls) calls, avg \($0.avgScore), good \($0.goodRate)%" }.joined(separator: "; "),
            "By opener: " + stats.openers.map { "\($0.label): \($0.calls) calls, avg \($0.avgScore), good \($0.goodRate)%" }.joined(separator: "; "),
            "By objection: " + stats.objections.map { "\($0.label): \($0.calls) calls, avg \($0.avgScore), good \($0.goodRate)%" }.joined(separator: "; "),
            "Recent calls (newest last):",
        ]
        for call in calls.suffix(60) {
            let s = call.summary
            lines.append("- score \(call.score), \(Int(call.talkSeconds))s, stages \(call.stages.joined(separator: "/")), opener \(call.openerID ?? "campaign"), objections \(s?.objections.joined(separator: ", ") ?? "?"), worked: \(s?.worked ?? ""), stalled: \(s?.failed ?? ""), outcome: \(s?.outcome ?? "")")
        }
        let json = try await ask(system: system, user: lines.joined(separator: "\n"), effort: "high")
        let raw = (json["suggestions"] as? [[String: Any]]) ?? []
        return raw.compactMap { item in
            guard let section = item["section"] as? String, keys.contains(section),
                  let suggested = (item["suggested"] as? String)?.trimmed, !suggested.isEmpty else { return nil }
            return ScriptSuggestion(
                campaignID: campaign.id, section: section, suggested: suggested,
                why: (item["why"] as? String) ?? "", confidence: (item["confidence"] as? String) ?? "low"
            )
        }
    }
}
