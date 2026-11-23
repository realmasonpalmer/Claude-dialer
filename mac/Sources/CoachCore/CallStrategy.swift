import Foundation

/// The coach's judgment about the WHOLE call, in plain rules (no model call): what the prospect just
/// revealed, whether the rep is helping or hurting, and the one best next move. The model still writes
/// the words; this decides which move is allowed. Hard rules here outrank the script and the stage:
/// a follow-up offer is accepted, a clear no is respected, a long pitch with no found need is stopped.
public enum CallStrategy {
    public struct Turn: Sendable, Equatable {
        public let rep: Bool
        public let text: String
        public init(rep: Bool, text: String) { self.rep = rep; self.text = text }
    }

    public enum Kind: String, Sendable {
        case acceptFollowUp, respectNo, stopPitching, riskyClaim, alreadyUsing, tooSmall, notPriority
    }

    /// The one thing to do now. `hard`: the app writes the card itself and no model line may replace it.
    public struct Directive: Sendable, Equatable {
        public let kind: Kind
        public let think: String
        public let say: String
        public let move: String
        public let hard: Bool
        public let reason: String
        public init(kind: Kind, think: String, say: String, move: String, hard: Bool, reason: String) {
            self.kind = kind; self.think = think; self.say = say; self.move = move; self.hard = hard; self.reason = reason
        }
    }

    /// What the prospect's words mean for the rep's next move.
    public enum Meaning: String, Sendable {
        case optOut, followUpOffered, clearNo, tooSmall, alreadyUsing, notPriority, softObjection, none
    }

    // MARK: - Reading the prospect

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{2019}", with: "'") }
    static func has(_ text: String, _ phrases: [String]) -> Bool { ObjectionTracker.has(norm(text), phrases) }
    static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    static let tooSmallPhrases = ["too small", "small team", "small company", "small business", "just me", "only a few", "just a few",
                                  "only two", "only three", "tiny team", "small shop", "not big enough", "we're small", "we are small",
                                  "we're a small", "we are a small", "one person", "one man", "solo"]
    static let alreadyUsingPhrases = ["already use", "already using", "already have", "we use", "i use", "we're using", "we are using",
                                      "i'm using", "i am using", "using it", "we have it", "use it every day", "use it daily"]
    static let notPriorityPhrases = ["not a priority", "not our priority", "not on our radar", "not a focus", "other priorities",
                                     "higher priorities", "bigger priorities", "not at the top", "back burner"]

    public static func meaning(of text: String) -> Meaning {
        let t = norm(text)
        if OptOut.matches(t) { return .optOut }
        if FollowUp.isOffered(t) { return .followUpOffered }
        if Rejection.isNo(t) { return .clearNo }
        if has(t, tooSmallPhrases) { return .tooSmall }
        if has(t, alreadyUsingPhrases) { return .alreadyUsing }
        if has(t, notPriorityPhrases) { return .notPriority }
        if ObjectionTracker.detect(t) != nil { return .softObjection }
        return .none
    }

    /// A clear no was said and nothing since shows new interest: the sale stays closed.
    public static func noStands(_ turns: [Turn]) -> Bool {
        guard let i = turns.lastIndex(where: { !$0.rep && Rejection.isNo($0.text) }) else { return false }
        return !turns[(i + 1)...].contains { !$0.rep && NeedSignal.interested($0.text) }
    }

    // MARK: - Reading the rep

    /// The rep's words since the prospect last spoke (a pitch is one stretch, however many chunks it came in).
    static func trailingRepStretch(_ turns: [Turn]) -> (start: Int, text: String, words: Int)? {
        var start = turns.count
        while start > 0, turns[start - 1].rep { start -= 1 }
        guard start < turns.count else { return nil }
        let text = turns[start...].map(\.text).joined(separator: " ")
        return (start, text, wordCount(text))
    }

    /// About 20 seconds of talking. A pitch longer than this with no problem found is too much.
    public static let longPitchWords = 55
    /// After an objection the rep has less room.
    public static let pitchAfterObjectionWords = 35
    /// After a clear no, even a short push is too much.
    public static let pushAfterNoWords = 25

    static let incentiveWords = ["free", "lunch", "gift", "discount", "no cost", "no charge", "on us", "we'd buy", "we will buy", "we'll buy"]
    static let meetingWords = ["meeting", "calendar", "schedule", "book", "demo", "health check", "call with", "30 minutes", "15 minutes"]
    static let riskyWords = ["guarantee", "guaranteed", "100%", "no risk", "risk free", "risk-free", "double your", "triple your",
                             "we'll save you", "we will save you", "proven to", "never fails"]

    public static func offersIncentive(_ text: String) -> Bool { has(text, incentiveWords) || text.contains("$") }
    public static func pitchesMeeting(_ text: String) -> Bool { has(text, meetingWords) }
    public static func riskyClaims(in text: String) -> [String] { riskyWords.filter { has(text, [$0]) || text.lowercased().contains($0) } }

    // MARK: - Decisions

    /// After the prospect finished a turn.
    public static func afterProspect(_ turns: [Turn]) -> Directive? {
        guard let last = turns.last, !last.rep else { return nil }
        let m = meaning(of: last.text)
        if m == .optOut { return nil } // the opt-out path owns this
        if m == .followUpOffered {
            let when = FollowUp.timing(last.text)
            return Directive(kind: .acceptFollowUp, think: "They offered a follow-up. Accept it and end the call.",
                             say: when.map { "Sounds good. I'll reach out \($0). Thanks for your time." } ?? "Sounds good. I'll reach out then. Thanks for your time.",
                             move: "close", hard: true, reason: "follow-up offered" + (when.map { " (\($0))" } ?? ""))
        }
        if noStands(turns) {
            let fresh = m == .clearNo
            return Directive(kind: .respectNo,
                             think: fresh ? "Respect the no. Don't offer another incentive." : "They said no earlier. Don't reopen the sale.",
                             say: "Understood. Thanks for your time.", move: "acknowledge", hard: false,
                             reason: fresh ? "clear no" : "the no still stands")
        }
        switch m {
        case .tooSmall:
            return Directive(kind: .tooSmall, think: "They see no need. Test for one real gap, or exit.",
                             say: "Fair. What's one thing that still takes more time than it should?", move: "discover", hard: false,
                             reason: "too small / no need")
        case .alreadyUsing:
            return Directive(kind: .alreadyUsing, think: "They already use it. Find out if anything is missing.",
                             say: "Good to hear. What's one thing it doesn't handle for you yet?", move: "discover", hard: false,
                             reason: "already using a solution")
        case .notPriority:
            return Directive(kind: .notPriority, think: "Not a priority for them. Ask when it might matter, or let it go.",
                             say: "Understood. Is there a time of year this comes up?", move: "discover", hard: false,
                             reason: "not a priority")
        default:
            return nil
        }
    }

    /// After the rep spoke (their words are the trailing turns): is the rep hurting the call?
    public static func afterRep(_ turns: [Turn]) -> Directive? {
        guard let stretch = trailingRepStretch(turns), stretch.start > 0, !turns[stretch.start - 1].rep else { return nil }
        let lastProspect = turns[stretch.start - 1]
        // They asked a question: a long answer is the job, not a mistake.
        if ConversationIntent.classify(lastProspect.text) == .question, !noStands(turns) { return nil }
        if noStands(turns), stretch.words >= pushAfterNoWords || offersIncentive(stretch.text) || pitchesMeeting(stretch.text) {
            let incentive = offersIncentive(stretch.text)
            return Directive(kind: .respectNo,
                             think: incentive ? "Respect the no. Don't offer another incentive." : "Respect the no. Stop selling and wrap up.",
                             say: "Understood. Thanks for your time.", move: "acknowledge", hard: true,
                             reason: "the rep kept selling after a clear no")
        }
        if !riskyClaims(in: stretch.text).isEmpty {
            return Directive(kind: .riskyClaim, think: "Careful: don't promise results you can't back up.",
                             say: "Let me be careful there. I can't promise a result.", move: "acknowledge", hard: true,
                             reason: "a promise the rep can't support: " + riskyClaims(in: stretch.text).joined(separator: ", "))
        }
        let needConfirmed = turns.contains { !$0.rep && NeedSignal.confirms($0.text) }
        let objecting: Bool = {
            switch meaning(of: lastProspect.text) {
            case .tooSmall, .alreadyUsing, .notPriority, .softObjection: return true
            default: return false
            }
        }()
        let limit = objecting ? pitchAfterObjectionWords : longPitchWords
        if stretch.words >= limit, !needConfirmed {
            return Directive(kind: .stopPitching, think: "Stop pitching. You haven't found a reason they'd need this.",
                             say: "Let me stop there. What does your team do about this today?", move: "discover", hard: true,
                             reason: "\(stretch.words) rep words with no problem found")
        }
        return nil
    }

    /// The directive for the call right now: from the prospect's last turn, or from how the rep is talking.
    public static func current(_ turns: [Turn]) -> Directive? {
        guard let last = turns.last else { return nil }
        return last.rep ? afterRep(turns) : afterProspect(turns)
    }

    // MARK: - For the model

    /// A line for the prompt. The model still writes the words; this says which move it may pick.
    public static func promptText(_ d: Directive) -> String {
        let rule: String
        switch d.kind {
        case .acceptFollowUp: rule = "Accept it, confirm the timing, and end the call. No question, no new pitch, no meeting ask."
        case .respectNo: rule = "Acknowledge in a few words. No sales question, no new offer or incentive, and don't reopen the sale unless they show new interest."
        case .stopPitching: rule = "No more pitch. At most one short question about their situation, or wrap up."
        case .riskyClaim: rule = "Don't promise results. Keep claims to what the rep can support."
        case .alreadyUsing: rule = "One question about what is missing or still hard. No pitch, no meeting ask yet."
        case .tooSmall: rule = "At most one question to test for a real gap; if none, let them go. No incentive, no meeting ask."
        case .notPriority: rule = "At most ask when it might matter. No hard push."
        }
        return "- \(d.think) \(rule)"
    }

    // MARK: - Checking a model line against the strategy

    /// Reasons a model line breaks the strategy ("STRATEGY ..." problems are serious: the line is rewritten or dropped).
    public static func problems(directive: Directive?, move: String, think: String, say: String) -> [String] {
        guard let d = directive else { return [] }
        var out: [String] = []
        let asks = think.hasSuffix("?") || say.contains("?")
        switch d.kind {
        case .acceptFollowUp:
            if !["close", "acknowledge", ""].contains(move) { out.append("STRATEGY: MOVE \(move) after they offered a follow-up: accept it, confirm the timing, end the call") }
            if asks { out.append("STRATEGY: no question after they offered a follow-up: accept it and end the call") }
            if pitchesMeeting(say) || offersIncentive(say) { out.append("STRATEGY: no new meeting pitch or offer after they offered a follow-up") }
        case .respectNo:
            if ["discover", "clarify", "objection"].contains(move) { out.append("STRATEGY: MOVE \(move) after a clear no: acknowledge or close") }
            if offersIncentive(say) { out.append("STRATEGY: no incentive after a no") }
            if pitchesMeeting(say) { out.append("STRATEGY: no meeting pitch after a no") }
        case .stopPitching, .riskyClaim:
            break // the rep side: the app writes the card itself
        case .alreadyUsing, .tooSmall, .notPriority:
            if move == "close" { out.append("STRATEGY: MOVE close while they see no need: find out if anything is missing first") }
            if offersIncentive(say) { out.append("STRATEGY: no incentive before they've shown a need") }
        }
        return out
    }

    // MARK: - Measuring the coaching

    /// Did the rep do the coached move, in any words? (A paraphrase counts.) Judged on what the rep said after the card.
    public static func followed(kind: Kind, repSaid: String) -> Bool {
        let t = norm(repSaid)
        let ack = ["understand", "fair", "got it", "no problem", "thanks", "thank you", "appreciate", "totally", "of course",
                   "sounds good", "sounds great", "will do", "perfect", "absolutely", "works for me", "sorry"]
        switch kind {
        case .acceptFollowUp:
            return has(t, ack + ["reach out", "talk then", "talk to you", "i'll call", "i will call"]) && !t.contains("?")
                && !pitchesMeeting(t) && !offersIncentive(t)
        case .respectNo:
            return has(t, ack) && !offersIncentive(t) && !pitchesMeeting(t)
        case .stopPitching:
            return t.contains("?") || has(t, ack + ["let me stop", "let me pause", "i hear you"])
        case .riskyClaim:
            return riskyClaims(in: t).isEmpty && wordCount(t) >= 3
        case .alreadyUsing, .tooSmall, .notPriority:
            return t.contains("?") && !offersIncentive(t) && wordCount(t) <= 35
        }
    }

    /// One coaching moment, judged: was the strategy right for the conversation, and did the rep follow it?
    public struct Verdict: Sendable, Equatable {
        public let strategyMatched: Bool
        public let followed: Bool
        public let problems: [String]
    }

    public static func evaluate(directive: Directive?, move: String, think: String, say: String, repSaidAfter: String) -> Verdict {
        let p = problems(directive: directive, move: move, think: think, say: say)
        let f = directive.map { followed(kind: $0.kind, repSaid: repSaidAfter) } ?? false
        return Verdict(strategyMatched: p.isEmpty, followed: f, problems: p)
    }
}

/// A prospect offering to talk later ("give me a call at the end of Q1"). A verb of getting back
/// to them plus a time: either alone isn't an offer, and half a sentence ("give me a call at the end of") isn't either.
public enum FollowUp {
    static let verbs = ["call me", "give me a call", "give me a ring", "call back", "reach out", "reach back out", "check back",
                        "check in", "circle back", "follow up", "touch base", "get back to me", "ping me", "try me", "contact me",
                        "reconnect", "talk then", "talk again", "revisit", "come back", "hit me up"]
    static let refusals = ["don't call", "do not call", "stop calling", "never call", "don't contact", "do not contact", "remove me", "take me off"]
    static let months = "january|february|march|april|may|june|july|august|september|october|november|december"
    static let patterns: [String] = [
        #"(?:at |by |around |toward |towards )?the (?:end|beginning|start|middle) of (?:the |this |next )?(?:q[1-4]|quarter|month|year|week|summer|fall|spring|winter|\#(months))"#,
        #"\b(?:in |by |around |for )?q[1-4]\b"#,
        #"\b(?:next|this coming) (?:quarter|month|year|week)\b"#,
        #"\b(?:after|in|around|early|late|mid)[ -](?:the )?(?:new year|holidays|\#(months))\b"#,
        #"\b(?:in )?(?:a |a few |a couple of |a couple |few |couple |two |three |four |six |2 |3 |4 |6 )(?:weeks?|months?)\b"#,
        #"\btomorrow\b"#,
        #"\b(?:on )?(?:monday|tuesday|wednesday|thursday|friday)\b"#,
    ]

    /// The timing they gave ("the end of Q1"), or nil.
    public static func timing(_ text: String) -> String? {
        let t = CallStrategy.norm(text).lowercased()
        for p in patterns {
            if let r = t.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                return String(t[r]).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\bq([1-4])\b"#, with: "Q$1", options: .regularExpression)
            }
        }
        return nil
    }

    public static func isOffered(_ text: String) -> Bool {
        let t = CallStrategy.norm(text)
        guard !CallStrategy.has(t, refusals) else { return false }
        return CallStrategy.has(t, verbs) && timing(t) != nil
    }
}

/// Did the prospect name a real problem, or show interest? A pitch with neither is a pitch with no reason to exist.
public enum NeedSignal {
    static let pains = ["problem", "problems", "struggle", "struggling", "takes forever", "takes too long", "takes a long time",
                        "time consuming", "time-consuming", "manual", "manually", "hassle", "headache", "wish we", "we need",
                        "we could use", "that would help", "slow", "messy", "out of date", "outdated", "falls behind", "falling behind",
                        "bottleneck", "tedious", "frustrating", "can't keep up", "never gets updated", "doesn't get updated", "no one updates"]
    static let negations = ["no problem", "not a problem", "no problems", "don't have a problem", "do not have a problem", "no issue",
                            "no issues", "not struggling", "don't need", "do not need", "no need"]
    static let interest = ["tell me more", "how does it work", "how does that work", "how much", "what does it cost", "sounds interesting",
                           "interesting", "that could help", "go ahead", "what would that", "i'm curious", "i am curious"]

    /// They said something is hard, slow or missing (and didn't say the opposite).
    public static func confirms(_ text: String) -> Bool {
        let t = CallStrategy.norm(text)
        return CallStrategy.has(t, pains) && !CallStrategy.has(t, negations)
    }

    /// A new signal of interest: a real need, or a question that shows they want to hear more.
    public static func interested(_ text: String) -> Bool {
        confirms(text) || CallStrategy.has(CallStrategy.norm(text), interest)
    }
}
