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
          - Answer their direct question first. Respect a no: no discovery question after they decline.
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
        let redirects: Set<String> = ["wrong person", "call later"] // a question is the right move for these
        // They're done: no question to ask.
        if isQuestion, [.ending, .optOut].contains(intent) {
            out.append("THINK asks a question but they're ending the call: thank them, don't push")
        }
        if isQuestion, intent == .rejection, !redirects.contains(objectionKind ?? "") {
            out.append("THINK asks a question after they declined: acknowledge it, don't keep discovering")
        }
        // A direct question from them comes first: THINK must answer it, not discover.
        if intent == .question, move == "discover" {
            out.append("they asked a direct question: THINK must answer it first (MOVE answer), not start discovery")
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
            // Unrelated topic: nothing in it comes from this conversation or the script.
            let mine = Repeats.meaning(t)
            if !mine.isEmpty {
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

    /// First word class of a question: its wh-word, or "yn" for a yes/no question.
    static func questionClass(_ q: String) -> String {
        let first = q.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return ["what", "who", "how", "why", "when", "where", "which"].contains(first) ? first : "yn"
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
                guard questionClass(q) == questionClass(t) else { return false }
                let theirs = Repeats.meaning(q)
                guard !mine.isEmpty else { return true }
                return Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.5
            }
        }
        // An instruction describes the move; SAY carries it out. Discovery needs a question, so no.
        if move == "discover" { return false }
        // Stop or close: SAY must not go on asking.
        if ["acknowledge", "close"].contains(move) { return !say.contains("?") }
        // Answer or explain: SAY must be about the same thing.
        let mine = Repeats.meaning(t)
        return mine.isEmpty || !mine.intersection(Repeats.meaning(say)).isEmpty
    }

    /// What the big line shows. Script rows (exact) and missing or bad thoughts show SAY; the rep can ask for SAY anytime.
    public static func primary(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool, move: String = "") -> String {
        guard enabled, !exact, !showFull, let t = valid(think), agrees(think: t, say: say, move: move) else { return say }
        return t
    }
}
