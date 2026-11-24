import Foundation

/// What a dial turned out to be. Decided once, by fixed rules, when the call ends.
/// The coaching model never decides it, so Haiku vs Sonnet can't change the numbers.
public enum CallOutcome: String, Codable, Sendable, CaseIterable {
    case humanProspect, humanGatekeeper, voicemail, phoneTree, screenerOnly, noAnswer, invalidNumber, failedConnection, unknown

    /// A real person answered (the prospect or a gatekeeper).
    public var humanAnswered: Bool { self == .humanProspect || self == .humanGatekeeper }
    /// The prospect themself was reached. Gatekeepers don't count.
    public var prospectReached: Bool { self == .humanProspect }
}

/// One call attempt, from dial to hang-up. The single record the Pickup numbers, the call plan
/// (DialHistory) and the Salesforce checkbox all read from.
public struct CallAttempt: Codable, Sendable, Equatable {
    /// One prospect-side utterance, tagged by rules at the moment it was heard.
    public struct Heard: Codable, Sendable, Equatable {
        public enum Tag: String, Codable, Sendable { case speech, menu, screener }
        public var text: String
        public var at: Date
        public var tag: Tag
        public init(text: String, at: Date, tag: Tag = .speech) { self.text = text; self.at = at; self.tag = tag }
    }

    public let attemptID: String
    public let leadID: String?
    public let campaign: String?
    public let startedAt: Date
    /// The phone confirmed the call was placed (Aircall showed it, or any call audio or words came through).
    public var placedAt: Date?
    /// First words from a real person (not a menu, screener, recording or echo).
    public var callConnectedAt: Date?
    public var callEndedAt: Date?
    public var outcome: CallOutcome?
    /// Which rule decided the outcome, for the trace.
    public var classificationSource = ""
    /// A real conversation with the prospect: 3+ of their turns, or 45+ s from their first words to hang-up.
    public var conversation = false
    /// The live model this call used (logged only; never used to classify).
    public var liveModel: String?

    // Facts, filled in as the call happens.
    public var heard: [Heard] = []
    public var repSaid: [Heard] = []
    public var voicemailByRule = false
    public var badNumber = false
    public var phoneTree = false
    public var screenerSeen = false
    public var screenerOpen = false
    /// What the model labelled the call (Voicemail, Gatekeeper...). A hint for the trace only.
    public var modelStages: [String] = []

    public init(attemptID: String = UUID().uuidString, leadID: String?, campaign: String?, startedAt: Date = Date(), liveModel: String? = nil) {
        self.attemptID = attemptID; self.leadID = leadID; self.campaign = campaign; self.startedAt = startedAt; self.liveModel = liveModel
    }

    public var finalized: Bool { outcome != nil }

    // MARK: Lifecycle events

    public mutating func placed(at: Date = Date()) { if placedAt == nil { placedAt = at } }
    public mutating func prospect(_ text: String, at: Date = Date(), tag: Heard.Tag = .speech) {
        guard !finalized, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        placed(at: at)
        heard.append(Heard(text: text, at: at, tag: screenerOpen && tag == .speech ? .screener : tag))
    }
    public mutating func rep(_ text: String, at: Date = Date()) {
        guard !finalized, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        placed(at: at)
        repSaid.append(Heard(text: text, at: at))
    }
    public mutating func voicemailDetected() { if !finalized { voicemailByRule = true } }
    /// A phone menu answered. Menus answer first, so words heard before this were the menu; a
    /// voicemail guess made on the menu's words is cancelled.
    public mutating func phoneTreeDetected() {
        guard !finalized else { return }
        phoneTree = true
        voicemailByRule = false
        for i in heard.indices where heard[i].tag == .speech { heard[i].tag = .menu }
    }
    /// A number that doesn't work (its recording can sound like a voicemail, so that guess is cancelled).
    public mutating func badNumberDetected() { if !finalized { badNumber = true; voicemailByRule = false } }
    /// A call screener answered. Screeners answer first, so earlier words were the screener.
    public mutating func screenerStarted() {
        guard !finalized else { return }
        screenerSeen = true
        screenerOpen = true
        for i in heard.indices where heard[i].tag == .speech { heard[i].tag = .screener }
    }
    /// A person came on after the screener. `personSaid`: their words, already heard while the screener
    /// was still open, are moved back to a person.
    public mutating func screenerEnded(personSaid: String = "") {
        screenerOpen = false
        let said = Self.norm(personSaid).joined(separator: " ")
        guard !said.isEmpty else { return }
        var i = heard.count - 1
        while i >= 0, heard[i].tag == .screener, said.contains(Self.norm(heard[i].text).joined(separator: " ")) {
            heard[i].tag = .speech
            i -= 1
        }
    }
    public mutating func modelStage(_ stage: String) { if !finalized, !stage.isEmpty { modelStages.append(stage) } }

    /// Decides the outcome once. Returns false if it was already decided (so nothing is counted twice).
    @discardableResult
    public mutating func finalize(endedAt: Date = Date(), source: String? = nil) -> Bool {
        guard !finalized else { return false }
        callEndedAt = endedAt
        let (o, why, human) = Self.classify(self)
        outcome = o
        classificationSource = source.map { "\($0): \(why)" } ?? why
        callConnectedAt = human.first?.at
        if o.prospectReached, let first = human.first?.at {
            conversation = human.count >= 3 || endedAt.timeIntervalSince(first) >= 45
        }
        return true
    }

    // MARK: Rules

    /// Words only a phone menu says (checked on what's heard once a menu was detected).
    static let menuWords = ["press", "dial", "option", "options", "extension", "menu", "directory", "pound",
                            "para", "español", "to reach", "please listen", "your party", "hold for the next"]

    static let gatekeeperPhrases = [
        "who's calling", "who is calling", "may i ask who", "can i ask who", "what is this regarding", "what's this regarding",
        "what is this about", "what's this about", "not available", "isn't available", "not in the office", "isn't in",
        "is not in", "he's out", "she's out", "they're out", "take a message", "front desk", "reception",
        "thank you for calling", "thanks for calling", "how may i direct", "how can i direct", "can i tell him", "can i tell her",
    ]
    /// A canned opening line. Recordings (auto-attendants, company greetings) say these too.
    static let greetingPhrases = ["thank you for calling", "thanks for calling"]
    /// Words a live person adds to a greeting because they are waiting for an answer.
    static let interactivePhrases = [
        "how may i", "how can i", "can i help", "may i help", "who's calling", "who is calling", "may i ask", "can i ask",
        "what is this regarding", "what's this regarding", "what is this about", "what's this about",
    ]
    static let transferPhrases = [
        "transfer you", "put you through", "connect you", "one moment", "hold please", "please hold",
        "let me get", "let me grab", "let me see if",
    ]
    static let wrongNumberPhrases = [
        "wrong number", "no one here by that name", "nobody here by that name", "doesn't work here",
        "does not work here", "no longer works here", "not this number",
    ]

    /// True when the prospect-side words are really the rep's own voice coming back (echo).
    static func isEcho(_ h: Heard, rep: [Heard]) -> Bool {
        let words = Set(norm(h.text))
        guard words.count >= 2 else { return false }
        return rep.contains { r in
            abs(r.at.timeIntervalSince(h.at)) <= 2.5 && Double(words.intersection(Set(norm(r.text))).count) / Double(words.count) >= 0.7
        }
    }

    static func norm(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    static func has(_ text: String, _ phrases: [String]) -> Bool {
        let t = " " + norm(text).joined(separator: " ") + " "
        return phrases.contains { t.contains(" " + $0 + " ") }
    }

    /// (outcome, the rule that decided it, the real-person utterances).
    public static func classify(_ a: CallAttempt) -> (CallOutcome, String, [Heard]) {
        guard a.placedAt != nil else { return (.failedConnection, "never placed", []) }
        // The voicemail rules only fire on words a machine says ("leave a message after the tone"),
        // so a voicemail rule wins: the greeting's own words are not a person.
        if a.voicemailByRule { return (.voicemail, "voicemail rule", []) }
        let human = a.heard.filter {
            $0.tag == .speech && !isEcho($0, rep: a.repSaid) && !(a.phoneTree && has($0.text, menuWords))
        }
        if human.isEmpty {
            if a.voicemailByRule { return (.voicemail, "voicemail rule", []) }
            if a.phoneTree { return (.phoneTree, "phone menu, no person after it", []) }
            if a.screenerSeen { return (.screenerOnly, "screener only, no person after it", []) }
            if a.badNumber { return (.invalidNumber, "bad number rule", []) }
            let echoOnly = a.heard.contains { $0.tag == .speech }
            return (.noAnswer, echoOnly ? "only the rep's own voice came back" : "no one spoke", [])
        }
        // Only "Thank you for calling X" (nothing that waits for an answer, no reply after it): a recording,
        // not a person. A receptionist who asks "how can I help?" or answers the rep still counts below.
        if human.allSatisfy({ has($0.text, greetingPhrases) && !has($0.text, interactivePhrases) }) {
            if a.phoneTree { return (.phoneTree, "phone menu, no person after it", []) }
            if a.screenerSeen { return (.screenerOnly, "screener only, no person after it", []) }
            return (.noAnswer, "only a recorded greeting (\"thank you for calling\"), no reply", [])
        }
        if human.contains(where: { has($0.text, wrongNumberPhrases) }) { return (.humanGatekeeper, "wrong number", human) }
        let lastTransfer = human.lastIndex { has($0.text, transferPhrases) }
        let sawGatekeeper = human.contains { has($0.text, gatekeeperPhrases) } || lastTransfer != nil
        if !sawGatekeeper { return (.humanProspect, a.phoneTree ? "person after the phone menu" : a.screenerSeen ? "person after the screener" : "person spoke", human) }
        if let i = lastTransfer, i < human.count - 1 { return (.humanProspect, "gatekeeper put them through", human) }
        if lastTransfer == nil, let firstGK = human.firstIndex(where: { has($0.text, gatekeeperPhrases) }), firstGK > 0,
           !has(human[0].text, gatekeeperPhrases) {
            // The prospect spoke first, then asked who's calling: still the prospect.
            return (.humanProspect, "prospect asked who's calling", human)
        }
        return (.humanGatekeeper, "gatekeeper only", human)
    }
}

/// The three call numbers, per dial. Built from finished attempts only.
public struct PickupStats: Equatable, Sendable {
    public var placedDials = 0
    public var humanAnswered = 0
    public var conversations = 0
    public var leadsAttempted = 0
    public var leadsReached = 0

    public init(_ attempts: [CallAttempt]) {
        let done = attempts.filter { $0.finalized && $0.placedAt != nil }
        placedDials = done.count
        humanAnswered = done.filter { $0.outcome?.humanAnswered == true }.count
        conversations = done.filter(\.conversation).count
        let leads = Set(done.compactMap(\.leadID))
        leadsAttempted = leads.count
        leadsReached = Set(done.filter { $0.outcome?.prospectReached == true }.compactMap(\.leadID)).count
    }

    public var humanAnswerRate: Double? { placedDials == 0 ? nil : Double(humanAnswered) / Double(placedDials) }
    public var prospectReachRate: Double? { leadsAttempted == 0 ? nil : Double(leadsReached) / Double(leadsAttempted) }
    public var conversationRate: Double? { placedDials == 0 ? nil : Double(conversations) / Double(placedDials) }
}
