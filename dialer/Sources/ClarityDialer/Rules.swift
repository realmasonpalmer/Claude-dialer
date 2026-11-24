import Foundation

/// Past calls per person: Salesforce call Tasks merged with this Mac's attempts.
/// Keyed by the 15-character Salesforce Id (list views give 18).
struct History: Sendable, Equatable {
    private(set) var calls: [String: [Date]] = [:]
    private(set) var finished: Set<String> = []

    static func key(_ id: String) -> String { String(id.prefix(15)) }

    func dates(_ id: String) -> [Date] { calls[Self.key(id)] ?? [] }
    func isFinished(_ id: String) -> Bool { finished.contains(Self.key(id)) }

    /// `fromSalesforce`: Salesforce may already know a call this Mac made; within 2 minutes of
    /// one we have, it's the same call. Calls made here are always distinct (a redial seconds
    /// later is a second call).
    mutating func add(_ id: String, at date: Date, fromSalesforce: Bool = false) {
        let k = Self.key(id)
        if fromSalesforce, calls[k, default: []].contains(where: { abs($0.timeIntervalSince(date)) < 120 }) { return }
        calls[k, default: []].append(date)
    }

    mutating func finish(_ id: String) { finished.insert(Self.key(id)) }

    init(salesforce: [String: [Date]] = [:], attempts: [Attempt] = []) {
        for a in attempts {
            add(a.leadID, at: a.dialedAt)
            if a.outcome?.isFinal == true { finish(a.leadID) }
        }
        for (id, dates) in salesforce { for d in dates { add(id, at: d, fromSalesforce: true) } }
    }
}

/// Why a person isn't called right now.
enum Skip: Equatable, Sendable {
    case doNotCall, noNumber, notNorthAmerican, noMobile, finished, calledToday
    case notDue(days: Int)
    case outsideHours(String)

    var label: String {
        switch self {
        case .doNotCall: return "Do Not Call"
        case .noNumber: return "No phone number"
        case .notNorthAmerican: return "Not a US/Canada number"
        case .noMobile: return "No mobile (Mobile only is on)"
        case .finished: return "Done (meeting, not interested, bad number, or cadence finished)"
        case .calledToday: return "Already called today"
        case .notDue(let d): return "Next call due in \(d) day\(d == 1 ? "" : "s")"
        case .outsideHours(let t): return "Outside calling hours (\(t) there)"
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

        switch s.cadence.plan(callDates: history.dates(lead.id), now: now, calendar: cal) {
        case .done: return .finished
        case .calledToday: return .calledToday
        case .notYet(_, let days): return .notDue(days: days)
        case .due: break
        }

        // Calling hours, in their own time zone (from their state or area code). Unknown zone: call.
        if let zone = lead.zone {
            let h = zone.hour(at: now)
            if h < s.startHour || h >= s.endHour { return .outsideHours(zone.timeString(at: now)) }
        }
        return nil
    }

    /// Queue order: most overdue first, then other follow-ups due today, then new people (Day 1).
    /// Within each, the list's own order.
    static func order(_ leads: [Lead], _ s: OutboundSettings, _ history: History,
                      now: Date = Date(), calendar cal: Calendar = .current) -> [Lead] {
        func key(_ l: Lead) -> (Int, Int, Int) {
            var overdue = 0, isNew = 1
            if case .due(let step, let late) = s.cadence.plan(callDates: history.dates(l.id), now: now, calendar: cal) {
                overdue = late
                isNew = step == 0 ? 1 : 0
            }
            return (-overdue, isNew, 0)
        }
        return leads.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    /// The busy / disconnected signal: 4+ tones about a second apart (0.5 s on, 0.5 s off).
    /// Ringback is 2 s on, 4 s off, so it never matches.
    static func isBusySignal(_ toneTimes: [Date]) -> Bool {
        guard toneTimes.count >= 4 else { return false }
        let last = Array(toneTimes.suffix(4))
        return zip(last, last.dropFirst()).allSatisfy { (0.75...1.3).contains($1.timeIntervalSince($0)) }
    }

    /// Never more than this many dials to one person in a day, however they got back on screen.
    static let maxDialsPerDay = 2

    /// Call twice: redial once, right away, when nobody answered.
    /// `hungUpAtBeep`: the first call reached voicemail and was hung up at the beep to call again.
    static func shouldRedial(_ outcome: Outcome, dialsToday: Int, _ s: OutboundSettings, hungUpAtBeep: Bool = false) -> Bool {
        s.callTwice && (outcome == .noAnswer || (outcome == .voicemail && hungUpAtBeep)) && dialsToday < maxDialsPerDay
    }

    /// What to do when the voicemail beep is heard.
    enum BeepAction: Equatable { case hangUpAndRedial, dropVoicemail(String), hangUp }

    static func onBeep(dialsToday: Int, step: Step?, _ s: OutboundSettings) -> BeepAction {
        // Call twice: the first call to voicemail is hung up and redialed right away (people often
        // pick up the second ring); the voicemail is left on the second call.
        if s.callTwice, dialsToday < maxDialsPerDay { return .hangUpAndRedial }
        if s.voicemailDrop, let vm = step?.voicemail?.nonBlankString { return .dropVoicemail(vm) }
        return .hangUp
    }

    /// The text for today's step, sent only when they didn't pick up and they have a mobile.
    static func text(for step: Step?, after outcome: Outcome, to lead: Lead, rep: String) -> String? {
        guard [.voicemail, .noAnswer].contains(outcome), lead.mobile.nonBlank != nil,
              let body = step?.text?.trimmed, !body.isEmpty else { return nil }
        return Merge.fill(body, lead: lead, rep: rep)
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
