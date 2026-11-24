import Foundation

// Plain values. No behavior beyond small derived properties.

enum SFObject: String, Codable, Sendable {
    case lead = "Lead", contact = "Contact"
}

/// A person on the call list, as loaded from Salesforce.
struct Lead: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let object: SFObject
    var name: String
    var firstName: String
    var company: String
    var title: String
    var phone: String?
    var mobile: String?
    var city: String?
    var state: String?
    var status: String
    var doNotCall: Bool
    var linkedIn: String? = nil

    /// Mobile first, then Phone.
    var dialNumber: String? { mobile.nonBlank ?? phone.nonBlank }
    var zone: CallZone? { CallZone.of(state: state, phones: [mobile, phone]) }
}

/// What happened on a call. Chosen by the rep, or set automatically for unanswered calls.
enum Outcome: String, Codable, CaseIterable, Identifiable, Sendable {
    case connected, meeting, notInterested, voicemail, noAnswer, badNumber

    var id: String { rawValue }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .meeting: return "Meeting booked"
        case .notInterested: return "Not interested"
        case .voicemail: return "Voicemail"
        case .noAnswer: return "No answer"
        case .badNumber: return "Bad number"
        }
    }

    /// Keyboard shortcut 1-6 in wrap-up.
    var key: Character { Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)) }

    /// A real person picked up.
    var isConnect: Bool { [.connected, .meeting, .notInterested].contains(self) }

    /// No more calls to this person from this list.
    var isFinal: Bool { [.meeting, .notInterested, .badNumber].contains(self) }
}

/// A call script. Merge fields: {{FirstName}} {{Name}} {{Company}} {{Title}} {{City}} {{Rep}}.
struct Script: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var body: String
    /// The Salesforce File it's shared as (nil = not shared yet).
    var sharedDocID: String?
    /// When this text was last written, here or by anyone in Salesforce. Newest wins.
    var updatedAt = Date.distantPast
    /// Edited here but not in Salesforce yet (offline). Retried until it goes.
    var needsPublish = false

    init(name: String, body: String) {
        self.name = name
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Script"
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        sharedDocID = try? c.decodeIfPresent(String.self, forKey: .sharedDocID)
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? .distantPast
        needsPublish = (try? c.decodeIfPresent(Bool.self, forKey: .needsPublish)) ?? false
    }

    func render(for lead: Lead?, rep: String) -> String {
        Merge.fill(body, lead: lead, rep: rep)
    }
}

enum Merge {
    static let fields = ["FirstName", "Name", "Company", "Title", "City", "Rep"]

    static func fill(_ text: String, lead: Lead?, rep: String) -> String {
        let values: [String: String] = [
            "FirstName": lead?.firstName ?? "",
            "Name": lead?.name ?? "",
            "Company": lead?.company ?? "",
            "Title": lead?.title ?? "",
            "City": lead?.city ?? "",
            "Rep": rep,
        ]
        var out = text
        for (k, v) in values {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v.isEmpty ? k.lowercased() : v)
        }
        return out
    }
}

/// Every outbound setting, in one value. Saved as JSON; missing keys fall back to defaults.
struct OutboundSettings: Codable, Equatable, Sendable {
    var repName = ""
    var fromNumberID: Int?          // Aircall number calls go out from
    var fromNumberDigits = ""       // its digits, recorded on each attempt for metrics
    var textNumberID: Int?          // Aircall number texts go out from (nil = same as calls)
    var aircallUserID: Int?         // Aircall user calls are placed as
    var autoDial = true             // dial the next person after logging
    var countdown = 3               // seconds before auto-dial
    var callTwice = false           // redial once right away if unanswered
    var mobileOnly = false          // skip people with no Mobile
    var startHour = 8               // calling hours, in the person's local time
    var endHour = 17
    var voicemailDrop = true        // show the Drop voicemail button (Aircall's recorded messages)
    var cadence = Cadence.standard  // the Day 1 / 3 / 5 sequence
    var maxAttemptsPerDay = 2

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OutboundSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        repName = v(.repName, d.repName)
        fromNumberID = try? c.decodeIfPresent(Int.self, forKey: .fromNumberID)
        fromNumberDigits = v(.fromNumberDigits, d.fromNumberDigits)
        textNumberID = try? c.decodeIfPresent(Int.self, forKey: .textNumberID)
        aircallUserID = try? c.decodeIfPresent(Int.self, forKey: .aircallUserID)
        autoDial = v(.autoDial, d.autoDial)
        countdown = v(.countdown, d.countdown)
        callTwice = v(.callTwice, d.callTwice)
        mobileOnly = v(.mobileOnly, d.mobileOnly)
        startHour = v(.startHour, d.startHour)
        endHour = v(.endHour, d.endHour)
        voicemailDrop = v(.voicemailDrop, d.voicemailDrop)
        cadence = v(.cadence, d.cadence)
        maxAttemptsPerDay = v(.maxAttemptsPerDay, d.maxAttemptsPerDay)
    }
}

/// One dial. Appended when the call is placed, completed when it's logged. Never edited after.
/// Every metric is computed from these.
struct Attempt: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let leadID: String
    var leadName: String
    var listID: String
    var listName: String
    var scriptID: UUID?
    var scriptName: String
    var attemptNumber: Int          // 1 = first ever dial to this person
    var isRedial: Bool              // the "call twice" second dial
    var fromNumber: String
    var leadZone: CallZone?
    let dialedAt: Date
    var answeredAt: Date?
    var endedAt: Date?
    var outcome: Outcome?
    var cadenceStep: Int?           // 0 = Day 1, 1 = Day 3, ... (index into the sequence)
    var voicemailDropped = false
    var textSent = false
    var linkedInSent = false
    var statusBefore: String
    var statusAfter: String?
    var note = ""
    var aircallCallID: Int?
    var salesforceTaskID: String?
    /// Changed since Salesforce last saw it. Cleared only after Salesforce accepts the change.
    var needsSync = false
    var statusSynced = false

    // What the call transcript says (filled in by CallReview a few minutes after the call).
    var reviewedAt: Date?
    /// The lead themself was on the line (not a front desk, assistant, or someone else).
    var reachedLead: Bool?
    var meetingAgreed: Bool?
    var meetingTime: String?
    var meetingOnCalendar: Bool?    // unused (kept so saved lines still decode)
    var reviewSummary: String?

    // What the app itself noticed during the call.
    /// The rep talked on the call (their mic).
    var repSpoke: Bool?
    /// A voicemail beep or greeting ("leave a message", "after the tone") was heard.
    var voicemailHeard: Bool?
    /// A call screener answered.
    var screenerHeard: Bool?

    /// A real pickup. If Claude reviewed the transcript, its verdict decides. Otherwise only a
    /// call where the rep actually talked, no voicemail was heard, and the line was open 15 s+.
    var isPickup: Bool {
        if let reachedLead { return reachedLead }
        guard outcome?.isConnect == true, repSpoke == true, voicemailHeard != true,
              let a = answeredAt, let e = endedAt else { return false }
        return e.timeIntervalSince(a) >= 15
    }
    /// A meeting: the transcript shows the lead clearly agreed to a specific time, or the rep
    /// marked the call Meeting booked.
    var isMeeting: Bool { meetingAgreed == true || outcome == .meeting }

    /// Seconds a real person was on the line (0 unless it was a pickup).
    var talkSeconds: Int {
        guard isPickup, let a = answeredAt, let e = endedAt else { return 0 }
        return max(0, Int(e.timeIntervalSince(a)))
    }
    var isConversation: Bool { talkSeconds >= 30 }
    var isLogged: Bool { outcome != nil }
}

/// Decodes every saved version of an attempt: fields added later fall back to their defaults,
/// so older lines in attempts.jsonl still load.
extension Attempt {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func o<T: Decodable>(_ k: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: k) }
        self.init(
            id: o(.id) ?? UUID(), leadID: try c.decode(String.self, forKey: .leadID),
            leadName: o(.leadName) ?? "", listID: o(.listID) ?? "", listName: o(.listName) ?? "",
            scriptID: o(.scriptID), scriptName: o(.scriptName) ?? "",
            attemptNumber: o(.attemptNumber) ?? 1, isRedial: o(.isRedial) ?? false,
            fromNumber: o(.fromNumber) ?? "", leadZone: o(.leadZone),
            dialedAt: try c.decode(Date.self, forKey: .dialedAt),
            answeredAt: o(.answeredAt), endedAt: o(.endedAt), outcome: o(.outcome),
            cadenceStep: o(.cadenceStep), voicemailDropped: o(.voicemailDropped) ?? false,
            textSent: o(.textSent) ?? false, linkedInSent: o(.linkedInSent) ?? false,
            statusBefore: o(.statusBefore) ?? "", statusAfter: o(.statusAfter), note: o(.note) ?? "",
            aircallCallID: o(.aircallCallID), salesforceTaskID: o(.salesforceTaskID),
            needsSync: o(.needsSync) ?? false, statusSynced: o(.statusSynced) ?? false,
            reviewedAt: o(.reviewedAt), reachedLead: o(.reachedLead), meetingAgreed: o(.meetingAgreed),
            meetingTime: o(.meetingTime), meetingOnCalendar: o(.meetingOnCalendar), reviewSummary: o(.reviewSummary),
            repSpoke: o(.repSpoke), voicemailHeard: o(.voicemailHeard), screenerHeard: o(.screenerHeard))
    }
}

extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

extension String {
    var nonBlankString: String? { trimmed.isEmpty ? nil : trimmed }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
