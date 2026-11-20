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
        THINK: <one short thought the rep could say straight to the prospect, ideally 5 to 12 words>
          THINK rules:
          - Something the rep could say directly to the prospect. Use "you" / "your" when it fits.
          - One conversational move, specific to their latest meaningful words and the call so far.
          - Follow the script's backbone: the thought moves the call toward the goal of the STAGE you picked,
            using that stage's own words from the script when they fit.
          - Never mix spoken words with instructions to the rep. Never start with a command like
            "ask", "explore", "find out" or "mention".
          - Never repeat a question they already answered or declined. Never assume a pain they haven't said.
          - If the right move is silence or ending the call, use MOVE silent or close; don't invent a question.
          - Clear, everyday words over clever ones. Say "your team", never "your reps".
          - Good: "Who would be the best person to speak with?"  Bad: "Who's the right person? Ask for a name."
          - Good: "Does Gong update your CRM too, or does your team?"  Bad: "Explore whether Gong handles CRM updates."

        """
    }

    /// A usable thought, or nil (then the card falls back to SAY).
    public static func valid(_ think: String) -> String? {
        let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = t.split(whereSeparator: { $0 == " " }).count
        guard words >= 2, words <= 16, !t.hasPrefix("<"), !t.uppercased().hasPrefix("SAY") else { return nil }
        // An instruction to the rep, not words to say: fall back to the full line.
        let low = t.lowercased()
        if ["ask ", "explore ", "find out", "mention ", "probe ", "dig ", "try "].contains(where: { low.hasPrefix($0) })
            || low.contains(" ask for ") || low.contains(". ask ") { return nil }
        return t
    }

    /// What the big line shows. Script rows (exact) and missing or bad thoughts show SAY; the rep can ask for SAY anytime.
    public static func primary(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool) -> String {
        guard enabled, !exact, !showFull, let t = valid(think) else { return say }
        return t
    }
}
