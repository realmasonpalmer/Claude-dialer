import Foundation

/// Past calls per person: Salesforce call Tasks merged with this Mac's attempts.
/// Keyed by the 15-character Salesforce Id (list views give 18).
struct History: Sendable, Equatable {
    private(set) var calls: [String: [Date]] = [:]
    private(set) var finished: Set<String> = []

    static func key(_ id: String) -> String { String(id.prefix(15)) }

    func dates(_ id: String) -> [Date] { calls[Self.key(id)] ?? [] }
    func isFinished(_ id: String) -> Bool { finished.contains(Self.key(id)) }

    mutating func add(_ id: String, at date: Date) {
        let k = Self.key(id)
        // Salesforce and this Mac can both know the same call; within 2 minutes counts once.
        if calls[k, default: []].contains(where: { abs($0.timeIntervalSince(date)) < 120 }) { return }
        calls[k, default: []].append(date)
    }

    mutating func finish(_ id: String) { finished.insert(Self.key(id)) }

    init(salesforce: [String: [Date]] = [:], attempts: [Attempt] = []) {
        for (id, dates) in salesforce { for d in dates { add(id, at: d) } }
        for a in attempts {
            add(a.leadID, at: a.dialedAt)
            if a.outcome?.isFinal == true { finish(a.leadID) }
        }
    }
}

/// Why a person isn't called right now.
enum Skip: Equatable, Sendable {
    case doNotCall, noNumber, notNorthAmerican, noMobile, finished, calledToday
    case outsideHours(String)
    case notDue(days: Int)

    var label: String {
        switch self {
        case .doNotCall: return "Do Not Call"
        case .noNumber: return "No phone number"
        case .notNorthAmerican: return "Not a US/Canada number"
        case .noMobile: return "No mobile (Mobile only is on)"
        case .finished: return "Done (meeting, not interested, bad number, or cadence finished)"
        case .calledToday: return "Already called today"
        case .outsideHours(let t): return "Outside calling hours (\(t) there)"
        case .notDue(let d): return "Next call due in \(d) day\(d == 1 ? "" : "s")"
        }
    }
}

/// Every outbound rule, as pure functions. No state, no I/O: each one is a unit test away.
enum Rules {
    /// nil = call them now.
    static func skip(_ lead: Lead, _ s: OutboundSettings, _ history: History,
                     now: Date = Date(), calendar cal: Calendar = .current) -> Skip? {
        if lead.doNotCall { return .doNotCall }
        guard let number = lead.dialNumber else { return .noNumber }
        if s.mobileOnly, lead.mobile.nonBlank == nil { return .noMobile }
        if !isNorthAmerican(number) { return .notNorthAmerican }
        if history.isFinished(lead.id) { return .finished }

        let today = cal.startOfDay(for: now)
        let dates = history.dates(lead.id)
        if dates.contains(where: { cal.isDate($0, inSameDayAs: now) }) { return .calledToday }

        // Cadence: the Nth call day is due `cadenceDays[N]` days after the first.
        let days = Set(dates.map { cal.startOfDay(for: $0) }).filter { $0 < today }.sorted()
        if !days.isEmpty {
            guard days.count < s.cadenceDays.count else { return .finished }
            if let due = cal.date(byAdding: .day, value: s.cadenceDays[days.count], to: days[0]), due > today {
                return .notDue(days: cal.dateComponents([.day], from: today, to: due).day ?? 1)
            }
        }

        if let zone = lead.zone {
            let h = zone.hour(at: now)
            if h < s.startHour || h >= s.endHour { return .outsideHours(zone.timeString(at: now)) }
        }
        return nil
    }

    /// Queue order: East -> West when on (unknown zones last), otherwise the list's own order.
    static func order(_ leads: [Lead], _ s: OutboundSettings) -> [Lead] {
        guard s.eastToWest else { return leads }
        return leads.enumerated().sorted { a, b in
            let ra = a.element.zone?.eastRank ?? 99, rb = b.element.zone?.eastRank ?? 99
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Call twice: redial once, right away, when nobody answered.
    static func shouldRedial(_ outcome: Outcome, dialsToday: Int, _ s: OutboundSettings) -> Bool {
        s.callTwice && outcome == .noAnswer && dialsToday < max(2, s.maxAttemptsPerDay)
    }

    /// The follow-up text after a voicemail, or nil when it shouldn't go out.
    static func followUpText(after outcome: Outcome, to lead: Lead, _ s: OutboundSettings) -> String? {
        guard outcome == .voicemail, s.textAfterVoicemail, lead.mobile.nonBlank != nil,
              !s.textTemplate.trimmed.isEmpty else { return nil }
        return Merge.fill(s.textTemplate, lead: lead, rep: s.repName)
    }

    /// "(555) 555-0123" -> "+15555550123". US and Canada only.
    static func e164(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return nil
    }

    static func isNorthAmerican(_ raw: String) -> Bool {
        if raw.trimmed.hasPrefix("+"), !raw.trimmed.hasPrefix("+1") { return false }
        guard let e = e164(raw) else { return false }
        return "23456789".contains(e[e.index(e.startIndex, offsetBy: 2)]) // area codes never start with 0 or 1
    }
}
