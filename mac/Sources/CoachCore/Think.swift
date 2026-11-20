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
          - Pick the MOVE first, then write THINK for that move. THINK and SAY must be the same move.
          - Usually ONE short, specific question the rep can ask aloud, built from what the prospect just said,
            what the rep just asked, and what's already answered. Example: they said "Our team uses Salesforce,
            but adoption is poor" -> "What's stopping your team from using Salesforce?"
          - When a question isn't the right move, a short instruction instead: they asked what the call is about
            -> "Explain the free AI health check." Second no -> "Thank them and end the call."
            Never both a question and an instruction in one THINK.
          - Answer their direct question first. Respect a no: never a discovery question after they decline.
          - Never repeat a question they already answered or declined. Never assume a pain they haven't said.
          - Never vague coaching words: no "explore", "probe", "find the gap", "handle the objection", "qualify".
          - Everyday words: "your team", "call notes", "follow-ups". Never "your reps".
          - Good: "Does Gong handle your follow-ups too?"  Bad: "Who's the right person? Ask for a name."
          - Good: "Who handles sales tools there?"  Bad: "Explore whether Gong handles CRM updates."

        """
    }

    /// Coaching jargon that needs translating mid-call: falls back to SAY.
    static let jargon = ["explore", "probe", "dig ", "drive ", "uncover", "leverage", "qualify", "find the gap",
                         "handle the objection", "handle objection", "identify friction", "friction"]

    /// A usable thought, or nil (then the card falls back to SAY).
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

    /// THINK and SAY must be the same move: a question THINK needs a question in SAY that shares its point.
    public static func agrees(think: String, say: String) -> Bool {
        guard think.contains("?") else { return true } // an instruction describes the move; SAY carries it out
        guard let q = say.split(separator: "?").first, say.contains("?") else { return false }
        let a = Set(Delivery.words(think)), b = Set(Delivery.words(String(q)))
        return !a.intersection(b).isEmpty
    }

    /// What the big line shows. Script rows (exact) and missing or bad thoughts show SAY; the rep can ask for SAY anytime.
    public static func primary(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool) -> String {
        guard enabled, !exact, !showFull, let t = valid(think), agrees(think: t, say: say) else { return say }
        return t
    }
}
