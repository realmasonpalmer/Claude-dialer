import Foundation

/// THINK mode (off by default, test builds only): the card shows one short thought the rep can say
/// as-is or in their own words. The full SAY line stays one shortcut away. Script rows always show in full.
public enum Think {
    public static let defaultsKey = "thinkCoach"
    /// Off unless turned on for a test. Live calls in the Haiku vs Sonnet test never see it.
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The prompt line asking for the thought. Empty when THINK mode is off, so the live prompt is unchanged.
    public static func promptLine(enabled: Bool) -> String {
        guard enabled else { return "" }
        return "THINK: <the rep's next move as ONE short thought they can say as-is, 5 to 12 words, "
            + "speaking to the prospect (you/your), specific to what was just said. Not a vague command.>\n"
    }

    /// A usable thought, or nil (then the card falls back to SAY).
    public static func valid(_ think: String) -> String? {
        let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = t.split(whereSeparator: { $0 == " " }).count
        guard words >= 2, words <= 16, !t.hasPrefix("<"), !t.uppercased().hasPrefix("SAY") else { return nil }
        return t
    }

    /// What the big line shows. Script rows (exact) and missing or bad thoughts show SAY; the rep can ask for SAY anytime.
    public static func primary(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool) -> String {
        guard enabled, !exact, !showFull, let t = valid(think) else { return say }
        return t
    }
}
