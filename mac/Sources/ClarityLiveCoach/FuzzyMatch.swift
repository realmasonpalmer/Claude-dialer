import Foundation

/// Forgiving search: every word you type must match somewhere in the text.
/// A word matches if it is inside a word, starts a word, has letters in order ("qrvp" finds "Q4 RevOps"),
/// or is a close typo of a word ("revopps" finds "RevOps").
enum FuzzyMatch {
    /// Higher is better. nil means no match. An empty query matches everything.
    static func score(query: String, in text: String) -> Int? {
        let tokens = words(query)
        if tokens.isEmpty { return 0 }
        let haystack = text.lowercased()
        let textWords = words(text)
        var total = 0
        for token in tokens {
            guard let s = tokenScore(token, haystack: haystack, textWords: textWords) else { return nil }
            total += s
        }
        return total
    }

    private static func tokenScore(_ token: String, haystack: String, textWords: [String]) -> Int? {
        if textWords.contains(token) { return 100 }
        if textWords.contains(where: { $0.hasPrefix(token) }) { return 80 }
        if haystack.contains(token) { return 60 }
        // Close typo of a whole word.
        let allowed = token.count <= 3 ? 0 : (token.count <= 6 ? 1 : 2)
        if allowed > 0, textWords.contains(where: { distance($0, token, limit: allowed) <= allowed }) { return 40 }
        // Letters in order, only for longer tokens so short ones don't match everything.
        if token.count >= 3, isSubsequence(token, of: haystack) { return 20 }
        return nil
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func isSubsequence(_ needle: String, of text: String) -> Bool {
        var it = text.makeIterator()
        for ch in needle {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// Edit distance, giving up early once it passes `limit`.
    private static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
