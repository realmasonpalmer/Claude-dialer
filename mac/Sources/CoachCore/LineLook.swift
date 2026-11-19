import Foundation

/// How a line looks on the card: a one-glance move label, and which part to make stand out.
/// Display only. It never changes the words, the model, or when a line shows.
public enum LineLook {
    /// The label above the line, from the move the model already picks. Empty move = "SAY THIS" (no guessing).
    public static func label(move: String, exact: Bool) -> String {
        let base: String
        switch move.lowercased().trimmingCharacters(in: .whitespaces) {
        case "discover": base = "ASK"
        case "clarify": base = "CHECK WHAT THEY MEANT"
        case "answer": base = "ANSWER THEM"
        case "acknowledge": base = "ACKNOWLEDGE"
        case "objection": base = "HANDLE THE PUSHBACK"
        case "close": base = "CLOSE"
        default: base = "SAY THIS"
        }
        return exact ? base + " · EXACT" : base
    }

    /// The line split so its one question stands out: (before, question, after).
    /// Only when the line has exactly one sentence ending in "?" and some other text too.
    /// Anything else returns nil and the whole line shows plain. No guessing.
    public static func emphasis(_ say: String) -> (before: String, key: String, after: String)? {
        let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.filter({ $0 == "?" }).count == 1, let q = text.firstIndex(of: "?") else { return nil }
        // Start of the question's sentence: just after the last ". ", "! " before the "?".
        var start = text.startIndex
        var i = text.startIndex
        while i < q {
            let next = text.index(after: i)
            if ".!".contains(text[i]), next < q, text[next] == " " { start = text.index(after: next) }
            i = next
        }
        let end = text.index(after: q)
        let before = String(text[..<start]), key = String(text[start..<end]), after = String(text[end...])
        guard !before.trimmingCharacters(in: .whitespaces).isEmpty || !after.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (before, key, after)
    }
}
