import Foundation

/// THINK mode (on by default): the card shows one short thought the rep can say
/// as-is or in their own words. The full SAY line stays one shortcut away. Script rows always show in full.
public enum Think {
    public static let defaultsKey = "thinkCoach"
    /// On unless turned off in Settings.
    public static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// The prompt line asking for the thought. Empty when THINK mode is off, so the live prompt is unchanged.
    public static func promptLine(enabled: Bool) -> String {
        guard enabled else { return "" }
        return """
        THINK: <one quick coaching nudge for the rep, usually 5 to 12 simple words>
          THINK rules (a skilled coach whispering the next move, not a script):
          - Pick the MOVE first, then write THINK for that move. THINK and SAY must be the same move and the same question.
          - Before you write it, decide the ONE most valuable thing still unknown: a concrete example of something
            broad, the cause of a problem they confirmed, how they do it today, what it costs them, who decides, or
            (when interest and fit are real) a meeting. Not a fixed order. Pick what this conversation needs.
          - Ask about their actual tools, process and words. Never assume a problem because it is common in their industry.
          - Usually ONE short question the rep can say aloud. Example ladder, they said "our team won't use Salesforce":
            weak "What's your biggest challenge?" / better "What's stopping your team from using Salesforce?" /
            best when you need the root cause "What happens when your team tries to use it?" (it asks for a real example).
          - When a question is the wrong move, a short instruction instead: they asked what the call is about
            -> "Explain the free AI health check." They said no again -> "Thank them and end the call." They are
            ending the call -> "Thank them. Don't push." Never both a question and an instruction in one THINK.
          - Answer their direct question first. An objection ("we use Gong", "no time") can get one relevant question.
            A clear no ("not interested", "not a fit") gets no sales question: acknowledge, at most offer an easy exit.
          - Never repeat a question they already answered, declined or deflected. Skip what the call already established.
          - Never vague coaching words: no "explore", "probe", "find the gap", "handle the objection", "qualify".
          - Everyday words: "your team", "call notes", "follow-ups". Never "your reps".
          - Good: "Does Gong handle your follow-ups too?"  Bad: "Who's the right person? Ask for a name."
          - Good: "Who handles sales tools there?"  Bad: "Explore whether Gong handles CRM updates."

        """
    }

    /// Coaching jargon that needs translating mid-call: falls back to SAY.
    static let jargon = ["explore", "probe", "dig ", "drive ", "uncover", "leverage", "qualify", "find the gap",
                         "handle the objection", "handle objection", "identify friction", "friction"]

    /// Words a THINK that states (not asks) a pain would be assuming, unless the prospect said them.
    static let assumedPain = ["wasting", "struggling", "losing hours", "drowning", "frustrated", "painful", "a mess"]

    /// A usable thought on its own, or nil (then the card falls back to SAY).
    public static func valid(_ think: String) -> String? {
        let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = t.split(whereSeparator: { $0 == " " }).count
        guard words >= 2, words <= 16, !t.hasPrefix("<"), !t.uppercased().hasPrefix("SAY") else { return nil }
        let low = t.lowercased()
        if jargon.contains(where: { low.contains($0) }) { return nil }
        // A question to say plus an instruction to the rep ("Who's the right person? Ask for a name.").
        if let q = t.firstIndex(of: "?"), t[t.index(after: q)...].contains(where: { $0.isLetter }) { return nil }
        if RoleCheck.speaksAsProspect(t) { return nil }
        return t
    }

    /// Why this THINK should not reach the screen in this conversation (empty = fine). Rules only, no model call.
    /// `sayLine` is the SAY that came with it. Each problem string is also what a retry is told to fix.
    public static func problems(think: String, say: String, move: String, intent: ConversationIntent, objectionKind: String?,
                                latestProspect: String, recentText: String, scriptText: String, answeredQuestions: [String]) -> [String] {
        let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return ["THINK is missing: write one short coaching nudge"] }
        guard valid(t) != nil else { return ["THINK isn't usable: one clear move, 2 to 16 simple words, no jargon, no question plus instruction"] }
        var out: [String] = []
        let isQuestion = t.hasSuffix("?")
        // They're done: no question to ask.
        if isQuestion, [.ending, .optOut].contains(intent) {
            out.append("THINK asks a question but they're ending the call: thank them, don't push")
        }
        // A clear no: no sales question. The only question allowed is the exit itself (move close: "Can I send one email?").
        if isQuestion, intent == .rejection, move != "close" {
            out.append("THINK asks a question after a clear no: acknowledge it, at most offer an easy exit")
        }
        if intent == .rejection, ["discover", "clarify", "objection"].contains(move) {
            out.append("MOVE \(move) after a clear no: acknowledge or close instead")
        }
        // A direct question from them comes first: THINK must answer it, not discover.
        if intent == .question, move == "discover" {
            out.append("they asked a direct question: THINK must answer it first (MOVE answer), not start discovery")
        }
        // Poor moves for the objection they raised (a line can pass every other check and still be bad coaching).
        if objectionKind == "happy as is", move == "close" {
            out.append("MOVE close on a brush-off (\"we're all set\"): acknowledge, then one light question; offer a meeting only if they open up")
        }
        if ["no time", "call later"].contains(objectionKind ?? ""), ["discover", "clarify"].contains(move) {
            out.append("MOVE \(move) when they have no time: ask for a better time, don't start discovery")
        }
        // Discovery needs a question; a pure statement or instruction for MOVE discover is the wrong coaching.
        if move == "discover", !isQuestion {
            out.append("MOVE is discover but THINK isn't a question: write the one question to ask")
        }
        if isQuestion {
            // Already answered: same meaning as a question the rep asked and got an answer to.
            if let again = answeredQuestions.first(where: { Repeats.same($0, t) }) {
                out.append("THINK repeats a question already answered: \"\(again)\"")
            }
            // Unrelated topic: a discovery question with nothing from this conversation or the script. Next steps
            // (a time, who joins, a referral, sending what they asked for) are new topics by nature, so they're fine.
            let mine = Repeats.meaning(t)
            if !mine.isEmpty, ["discover", "clarify"].contains(move) {
                let known = Repeats.meaning(recentText).union(Repeats.meaning(scriptText))
                if mine.intersection(known).isEmpty { out.append("THINK is about something that hasn't come up: ground it in what they said") }
            }
        } else {
            // States a pain as theirs when they never said it.
            let low = t.lowercased(), said = latestProspect.lowercased() + " " + recentText.lowercased()
            if let w = assumedPain.first(where: { low.contains($0) && !said.contains($0) }) {
                out.append("THINK assumes a problem they haven't named (\"\(w)\"): ask, don't state it")
            }
        }
        if !agrees(think: t, say: say, move: move) {
            out.append("THINK and SAY aren't the same move: SAY should say what THINK asks or explains")
        }
        return out
    }

    /// The kind of question: "qty" (how many / much / long / often), "who", "when", "where", "which",
    /// "open" (what / why / how), or "yn". "What's blocking it?" and "Why aren't they using it?" are both open.
    static func group(_ word: String) -> String? {
        switch word {
        case "what", "why", "how": return "open"
        case "who", "when", "where", "which": return word
        default: return nil
        }
    }

    static func questionClass(_ q: String) -> String {
        let low = q.lowercased()
        if ["how many", "how much", "how long", "how often"].contains(where: { low.contains($0) }) { return "qty" }
        let first = low.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return group(first) ?? "yn"
    }

    /// Every kind a question could be read as ("If this went well, what would that look like?" is open too).
    static func questionClasses(_ q: String) -> Set<String> {
        let low = q.lowercased()
        var out: Set<String> = [questionClass(q)]
        if out.contains("qty") { return out }
        for w in low.split(whereSeparator: { !$0.isLetter }).map(String.init) { if let g = group(w) { out.insert(g) } }
        return out
    }

    /// THINK and SAY must be the same move. Not "share any word": the same kind of question, and most of
    /// THINK's meaning inside SAY's question; or, for an instruction, at least one shared meaning word.
    public static func agrees(think: String, say: String, move: String = "") -> Bool {
        let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("?") {
            // SAY's questions: the one that best matches THINK.
            let sayQuestions = QuestionTracker.questions(in: say)
            guard !sayQuestions.isEmpty else { return false }
            let mine = Repeats.meaning(t)
            return sayQuestions.contains { q in
                guard questionClasses(q).contains(questionClass(t)) else { return false }
                let theirs = Repeats.meaning(q)
                guard !mine.isEmpty else { return true }
                return Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.5
            }
        }
        // An instruction describes the move; SAY carries it out. Discovery needs a question, so no.
        if move == "discover" { return false }
        // Stop-type instructions ("Thank them and end the call", "Don't push"): SAY must not go on asking.
        let low = t.lowercased()
        let stop = ["thank them", "end the call", "don't push", "do not push", "acknowledge", "let them go", "wrap up"]
        if move == "acknowledge" || (move == "close" && stop.contains(where: { low.contains($0) })) { return !say.contains("?") }
        // Answer or explain: SAY must be about the same thing.
        let mine = Repeats.meaning(t)
        return mine.isEmpty || !mine.intersection(Repeats.meaning(say)).isEmpty
    }

    /// What the card shows, and why. One function for the card and for the trace, so they can't disagree.
    public enum Display: String, Sendable { case think, say, exact, fallback }

    public static func resolve(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool,
                               thinkProblems: [String] = []) -> (text: String, display: Display, reason: String) {
        if !enabled { return (say, .say, "THINK mode is off") }
        if exact { return (say, .exact, "an approved script line, word for word") }
        if showFull { return (say, .say, "the rep asked for the full line") }
        guard let t = valid(think) else {
            return (say, .fallback, think.trimmingCharacters(in: .whitespaces).isEmpty ? "THINK was missing" : "THINK wasn't usable (format)")
        }
        // Serious THINK problems mean the move is wrong; those lines are suppressed before they get here.
        // Anything left (wording differs from SAY, a new topic) still shows THINK: different words are fine.
        _ = thinkProblems
        return (t, .think, "")
    }

    /// What the big line shows. Script rows (exact) and missing or bad thoughts show SAY; the rep can ask for SAY anytime.
    public static func primary(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool, move: String = "") -> String {
        resolve(think: think, say: say, exact: exact, enabled: enabled, showFull: showFull).text
    }
}
