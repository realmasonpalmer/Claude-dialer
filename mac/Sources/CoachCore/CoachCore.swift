import Foundation

// The live coach's decisions, kept small and pure so they can be tested without a call.

/// What the coach screen is doing right now.
public enum CoachState: String, Sendable {
    case listening = "Listening"       // prospect is talking; preparing
    case ready = "Ready"               // a fresh line is on screen
    case reading = "Reading"           // line shown, rep hasn't started (likely reading)
    case delivering = "Delivering"     // rep is speaking; line is protected
    case interrupted = "Interrupted"   // prospect cut in while the rep spoke
    case resolved = "Resolved"         // line delivered and the prospect answered
    case superseded = "Outdated"       // a better line is queued for this moment
    case idle = "Idle"                 // nothing useful to say
}

/// Everything the state machine looks at, sampled twice a second.
public struct CoachSignals: Sendable {
    public var hasLine: Bool
    public var prospectSpeaking: Bool
    public var repSpeaking: Bool
    public var secondsSinceShown: Double
    public var repStarted: Bool          // rep has said words since the line appeared
    public var delivered: Bool           // the line's meaning was said
    public var prospectAnsweredSince: Bool // prospect spoke after the rep delivered it
    public var queued: Bool              // a newer line is waiting
    public var queuedIsForNewTopic: Bool // the prospect moved on (interrupt/new question)
    public var lineWords: Int            // words in the line on screen (to protect silent reading)

    public init(hasLine: Bool, prospectSpeaking: Bool, repSpeaking: Bool, secondsSinceShown: Double,
                repStarted: Bool, delivered: Bool, prospectAnsweredSince: Bool, queued: Bool, queuedIsForNewTopic: Bool,
                lineWords: Int = 0) {
        self.hasLine = hasLine; self.prospectSpeaking = prospectSpeaking; self.repSpeaking = repSpeaking
        self.secondsSinceShown = secondsSinceShown; self.repStarted = repStarted; self.delivered = delivered
        self.prospectAnsweredSince = prospectAnsweredSince; self.queued = queued; self.queuedIsForNewTopic = queuedIsForNewTopic
        self.lineWords = lineWords
    }
}

public enum CoachMachine {
    /// How long a brand-new line is protected for reading before an un-started line can be swapped.
    public static let readingGrace = 1.2

    /// Silent reading can't be seen, so protect it by length: about 4 words a second, 1.2 to 5 seconds.
    public static func readingTime(words: Int) -> Double { min(5, max(readingGrace, Double(words) / 4)) }

    public static func state(_ s: CoachSignals) -> CoachState {
        if s.repSpeaking && s.prospectSpeaking { return .interrupted }
        if s.repSpeaking { return s.hasLine ? .delivering : .idle }
        if s.queued && s.queuedIsForNewTopic && s.repStarted && !s.delivered { return .superseded }
        if s.prospectSpeaking { return .listening }
        guard s.hasLine else { return .idle }
        if s.delivered && s.prospectAnsweredSince { return .resolved }
        if !s.repStarted { return s.secondsSinceShown < readingTime(words: s.lineWords) ? .ready : .reading }
        return .reading
    }

    /// May a newer line replace the one on screen right now?
    /// Never while the rep speaks. Not during the first moment of reading. Otherwise yes if the rep
    /// hasn't started it, it's been delivered, or the conversation clearly moved on.
    public static func canReplace(_ s: CoachSignals) -> Bool {
        guard s.hasLine else { return true }
        if s.repSpeaking { return false }
        // Not started: only something new from the prospect replaces it, never the clock alone.
        if !s.repStarted { return s.queuedIsForNewTopic && s.secondsSinceShown >= 2 }
        return s.delivered || s.queuedIsForNewTopic
    }

    /// Answers only count if they're for the newest request (older ones finishing late are dropped).
    public static func isFresh(requestID: Int, latestID: Int) -> Bool { requestID == latestID }
}

/// Did the rep get the line's meaning across? Paraphrase-friendly: compares meaningful words, and the
/// line's question counts as delivered once the rep asks a question with its key words.
public enum Delivery {
    private static let stop: Set<String> = ["the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "is",
        "are", "it", "that", "this", "you", "your", "we", "our", "i", "me", "my", "so", "just", "do", "does", "with",
        "at", "be", "can", "if", "what", "how", "about", "as", "have", "has", "was", "they", "them", "their", "would"]

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 && !stop.contains($0) }
    }

    /// 0 to 1: share of the line's meaningful words the rep said.
    public static func confidence(line: String, spoken: String) -> Double {
        let want = Set(words(line))
        guard !want.isEmpty else { return 0 }
        let said = Set(words(spoken))
        return Double(want.intersection(said).count) / Double(want.count)
    }

    public static func delivered(line: String, spoken: String) -> Bool {
        if confidence(line: line, spoken: spoken) >= 0.5 { return true }
        // The question at the end is the part that matters.
        if let q = line.split(separator: "?").first.map(String.init),
           let lastSentence = q.split(whereSeparator: { ".!".contains($0) }).last.map(String.init),
           confidence(line: lastSentence, spoken: spoken) >= 0.6 { return true }
        return false
    }
}

/// Approved answers from the script (objections, questions, blockers), matched in code: no AI wait.
public struct ScriptAnswers: Sendable {
    public struct Entry: Sendable, Equatable { public let id: String; public let phrases: [String]; public let say: String }
    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Reads every table row with a "Sounds like" and a "Say" column (" | " or tab separated).
    public init(script: String) {
        var out: [Entry] = []
        var soundsCol: Int?, sayCol: Int?
        for raw in script.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let sep = line.contains("|") ? "|" : (line.contains("\t") ? "\t" : nil)
            guard let sep else { continue }
            let cols = line.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
            if let s = cols.firstIndex(where: { $0.lowercased() == "sounds like" }), let y = cols.firstIndex(where: { $0.lowercased() == "say" }) {
                soundsCol = s; sayCol = y; continue
            }
            guard let s = soundsCol, let y = sayCol, cols.count > max(s, y) else { continue }
            let say = cols[y].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !say.isEmpty, !say.lowercased().hasPrefix("show"), !say.contains("(") else { continue }
            let phrases = cols[s].lowercased()
                .components(separatedBy: CharacterSet(charactersIn: ",;/\"“”"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.split(separator: " ").count >= 2 } // two words or more: safe to match
            guard !phrases.isEmpty else { continue }
            out.append(Entry(id: cols[0], phrases: phrases, say: say))
        }
        entries = out
    }

    /// The approved answer whose "sounds like" phrase appears in what they said (longest match wins).
    public func match(_ said: String) -> Entry? {
        let t = said.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var best: (Entry, Int)?
        for e in entries {
            for p in e.phrases where t.contains(p) {
                if best == nil || p.count > best!.1 { best = (e, p.count) }
            }
        }
        return best?.0
    }
}

/// Questions asked on the call and what happened to each, tracked in code from the transcript
/// (not inferred by the model). Fed to Haiku as facts: what's still open, what's already answered.
public struct QuestionTracker: Sendable {
    public enum Speaker: String, Sendable { case rep, prospect }
    public enum Status: String, Sendable { case open, answered, interrupted, abandoned }
    public struct Question: Sendable, Equatable {
        public let id: Int
        public let asker: Speaker
        public let text: String
        public var status: Status
        public var answer: String
    }
    public enum Change: Sendable, Equatable {
        case asked(Question), answered(Question), interrupted(Question), abandoned(Question)
    }

    public private(set) var questions: [Question] = []
    private var nextID = 1
    public init() {}

    private static let filler: Set<String> = ["uh", "um", "hmm", "mm", "mhm", "uh-huh", "huh"]
    private static let starts = ["who", "what", "when", "where", "why", "how", "do", "does", "did", "is", "are", "can",
                                 "could", "would", "will", "should", "have", "has", "any", "which"]

    /// The questions in a turn: sentences ending in "?" (or starting like a question when no punctuation came through).
    static func questions(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if ch == "?" { out.append(s) }
                current = ""
            }
        }
        if out.isEmpty, !text.contains("."), let first = text.lowercased().split(separator: " ").first,
           starts.contains(String(first)), text.split(separator: " ").count >= 4 {
            out.append(text.trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    /// One finished turn. `overlapped`: the other person was still talking when this turn started.
    public mutating func add(turn text: String, from speaker: Speaker, overlapped: Bool = false) -> [Change] {
        var changes: [Change] = []
        let words = text.lowercased().split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        let substantive = words.contains { !Self.filler.contains($0) && !$0.isEmpty }
        // The other side's open questions: answered by this turn, or cut off if this turn talked over them.
        for i in questions.indices where questions[i].asker != speaker && questions[i].status == .open && substantive {
            if overlapped {
                questions[i].status = .interrupted
                changes.append(.interrupted(questions[i]))
            } else {
                questions[i].status = .answered
                questions[i].answer = text
                changes.append(.answered(questions[i]))
            }
        }
        let asked = Self.questions(in: text)
        // Asking again before getting an answer abandons the earlier one.
        if !asked.isEmpty {
            for i in questions.indices where questions[i].asker == speaker && (questions[i].status == .open || questions[i].status == .interrupted) {
                questions[i].status = .abandoned
                changes.append(.abandoned(questions[i]))
            }
        }
        for q in asked {
            let new = Question(id: nextID, asker: speaker, text: q, status: .open, answer: "")
            nextID += 1
            questions.append(new)
            changes.append(.asked(new))
        }
        return changes
    }

    /// For the model: hard facts about questions, so it never re-asks or forgets one.
    public var promptText: String {
        let repAnswered = questions.filter { $0.asker == .rep && $0.status == .answered }
        let theirsOpen = questions.filter { $0.asker == .prospect && $0.status == .open }
        let repOpen = questions.filter { $0.asker == .rep && ($0.status == .open || $0.status == .interrupted) }
        var lines: [String] = []
        if !theirsOpen.isEmpty { lines.append("Prospect questions NOT yet answered (answer these first): " + theirsOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
        if !repOpen.isEmpty { lines.append("Rep questions still waiting for an answer: " + repOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
        if !repAnswered.isEmpty { lines.append("Already asked AND answered (never ask again): " + repAnswered.map { "\"\($0.text)\" -> \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}
