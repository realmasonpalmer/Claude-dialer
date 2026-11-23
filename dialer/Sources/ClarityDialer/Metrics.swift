import Foundation

/// Totals and rates for a set of attempts. Pure: computed, never stored.
struct Summary: Equatable, Sendable {
    var dials = 0
    var uniqueLeads = 0
    var connects = 0
    var conversations = 0
    var voicemails = 0
    var noAnswers = 0
    var meetings = 0
    var notInterested = 0
    var badNumbers = 0
    var textsSent = 0
    var talkSeconds = 0
    var activeSeconds = 0

    var connectRate: Double { ratio(connects, dials) }
    var conversationRate: Double { ratio(conversations, dials) }
    var meetingRate: Double { ratio(meetings, dials) }
    /// Meetings per conversation: how well the script converts once someone is listening.
    var conversationToMeeting: Double { ratio(meetings, conversations) }
    var leadConnectRate: Double { ratio(connects, uniqueLeads) }
    var avgTalkSeconds: Int { connects == 0 ? 0 : talkSeconds / connects }
    var dialsPerHour: Double { activeSeconds < 60 ? 0 : Double(dials) / (Double(activeSeconds) / 3600) }
    var dialsPerMeeting: Double? { meetings == 0 ? nil : Double(dials) / Double(meetings) }

    private func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
}

enum Period: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days", all = "All time"
    var id: String { rawValue }

    func contains(_ date: Date, now: Date = Date(), calendar cal: Calendar = .current) -> Bool {
        switch self {
        case .today: return cal.isDate(date, inSameDayAs: now)
        case .week: return date >= cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        case .month: return date >= cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
        case .all: return true
        }
    }
}

/// The ways attempts can be broken down.
enum Breakdown: String, CaseIterable, Identifiable {
    case day = "Day", list = "List", script = "Script", localHour = "Their local hour",
         zone = "Time zone", attemptNumber = "Attempt #", fromNumber = "From number", redial = "First dial vs redial"
    var id: String { rawValue }

    /// (sort key, label) for an attempt.
    func key(_ a: Attempt, calendar cal: Calendar = .current) -> (sort: String, label: String) {
        switch self {
        case .day:
            let d = cal.startOfDay(for: a.dialedAt)
            return (String(format: "%012.0f", d.timeIntervalSince1970), d.formatted(date: .abbreviated, time: .omitted))
        case .list: return (a.listName, a.listName.isEmpty ? "-" : a.listName)
        case .script: return (a.scriptName, a.scriptName.isEmpty ? "-" : a.scriptName)
        case .localHour:
            var c = cal
            c.timeZone = a.leadZone?.timeZone ?? cal.timeZone
            let h = c.component(.hour, from: a.dialedAt)
            return (String(format: "%02d", h), "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "am" : "pm")")
        case .zone: return (String(a.leadZone?.eastRank ?? 99), a.leadZone?.label ?? "Unknown")
        case .attemptNumber:
            let n = min(a.attemptNumber, 6)
            return (String(format: "%02d", n), n == 6 ? "6+" : "#\(n)")
        case .fromNumber: return (a.fromNumber, a.fromNumber.isEmpty ? "-" : a.fromNumber)
        case .redial: return (a.isRedial ? "1" : "0", a.isRedial ? "Redial" : "First dial")
        }
    }
}

enum Metrics {
    /// Gaps longer than this between dials are breaks, not dialing time.
    static let breakAfter: TimeInterval = 10 * 60

    static func summary(_ attempts: [Attempt]) -> Summary {
        var s = Summary()
        let logged = attempts.filter(\.isLogged)
        s.dials = logged.count
        s.uniqueLeads = Set(logged.map { History.key($0.leadID) }).count
        for a in logged {
            guard let o = a.outcome else { continue }
            if o.isConnect { s.connects += 1 }
            if a.isConversation { s.conversations += 1 }
            switch o {
            case .voicemail: s.voicemails += 1
            case .noAnswer: s.noAnswers += 1
            case .meeting: s.meetings += 1
            case .notInterested: s.notInterested += 1
            case .badNumber: s.badNumbers += 1
            case .connected: break
            }
            if a.textSent { s.textsSent += 1 }
            s.talkSeconds += a.talkSeconds
        }
        s.activeSeconds = activeSeconds(logged)
        return s
    }

    /// Time spent dialing: the span of each session of dials, plus the last call's length.
    static func activeSeconds(_ attempts: [Attempt]) -> Int {
        let sorted = attempts.sorted { $0.dialedAt < $1.dialedAt }
        guard !sorted.isEmpty else { return 0 }
        var total: TimeInterval = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            total += min(b.dialedAt.timeIntervalSince(a.dialedAt), breakAfter)
        }
        let last = sorted[sorted.count - 1]
        total += max(30, (last.endedAt ?? last.dialedAt).timeIntervalSince(last.dialedAt))
        return Int(total)
    }

    struct Row: Identifiable {
        let id: String
        let label: String
        let summary: Summary
    }

    static func rows(_ attempts: [Attempt], by b: Breakdown) -> [Row] {
        var groups: [String: (label: String, items: [Attempt])] = [:]
        for a in attempts where a.isLogged {
            let k = b.key(a)
            groups[k.sort, default: (k.label, [])].items.append(a)
        }
        return groups.keys.sorted().map { k in Row(id: k, label: groups[k]!.label, summary: summary(groups[k]!.items)) }
    }

    static func csv(_ attempts: [Attempt]) -> String {
        let iso = ISO8601DateFormatter()
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["dialed_at,lead_id,lead,list,script,attempt,redial,from_number,zone,outcome,answered_at,ended_at,talk_seconds,voicemail_dropped,text_sent,status_before,status_after,note,aircall_call_id,salesforce_task_id"]
        for a in attempts.sorted(by: { $0.dialedAt < $1.dialedAt }) {
            let who: [String] = [iso.string(from: a.dialedAt), a.leadID, cell(a.leadName), cell(a.listName), cell(a.scriptName)]
            let dial: [String] = [String(a.attemptNumber), String(a.isRedial), a.fromNumber, a.leadZone?.label ?? ""]
            let answered: String = a.answeredAt.map { iso.string(from: $0) } ?? ""
            let ended: String = a.endedAt.map { iso.string(from: $0) } ?? ""
            let result: [String] = [a.outcome?.label ?? "", answered, ended, String(a.talkSeconds),
                                    String(a.voicemailDropped), String(a.textSent)]
            let crm: [String] = [cell(a.statusBefore), cell(a.statusAfter ?? ""), cell(a.note),
                                 a.aircallCallID.map { String($0) } ?? "", a.salesforceTaskID ?? ""]
            lines.append((who + dial + result + crm).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension Double {
    var percent: String { String(format: "%.0f%%", self * 100) }
}

extension Int {
    /// 4512 -> "1h 15m", 95 -> "1m 35s"
    var duration: String {
        let h = self / 3600, m = (self % 3600) / 60, s = self % 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
