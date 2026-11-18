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
    case repTalking = "Rep talking"    // rep is speaking, but not saying the line on screen
    case doNotCall = "Do not call"     // they asked not to be called: terminal, no more coaching
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
    public var overlapping: Bool         // both sides talking at the same moment (a real interruption)
    public var repOnLine: Bool           // what the rep is saying matches the line on screen
    public var doNotCall: Bool           // they asked not to be called again

    public init(hasLine: Bool, prospectSpeaking: Bool, repSpeaking: Bool, secondsSinceShown: Double,
                repStarted: Bool, delivered: Bool, prospectAnsweredSince: Bool, queued: Bool, queuedIsForNewTopic: Bool,
                lineWords: Int = 0, overlapping: Bool = false, repOnLine: Bool = false, doNotCall: Bool = false) {
        self.hasLine = hasLine; self.prospectSpeaking = prospectSpeaking; self.repSpeaking = repSpeaking
        self.secondsSinceShown = secondsSinceShown; self.repStarted = repStarted; self.delivered = delivered
        self.prospectAnsweredSince = prospectAnsweredSince; self.queued = queued; self.queuedIsForNewTopic = queuedIsForNewTopic
        self.lineWords = lineWords
        self.overlapping = overlapping; self.repOnLine = repOnLine; self.doNotCall = doNotCall
    }
}

public enum CoachMachine {
    /// How long a brand-new line is protected for reading before an un-started line can be swapped.
    public static let readingGrace = 1.2

    /// Silent reading can't be seen, so protect it by length: about 4 words a second, 1.2 to 5 seconds.
    public static func readingTime(words: Int) -> Double { min(5, max(readingGrace, Double(words) / 4)) }

    public static func state(_ s: CoachSignals) -> CoachState {
        if s.doNotCall { return .doNotCall }
        // Only real overlap is an interruption. One side answering right after the other is a normal turn.
        if s.overlapping { return .interrupted }
        // Delivering = saying the line on screen. Any other rep talk ("okay", small talk) is just talking.
        if s.repSpeaking { return s.hasLine && (s.repOnLine || s.delivered) ? .delivering : .repTalking }
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
        if s.doNotCall { return false } // the goodbye line stays; nothing replaces it
        guard s.hasLine else { return true }
        if s.repSpeaking { return false }
        // Not started: only something new from the prospect replaces it, never the clock alone.
        if !s.repStarted { return s.queuedIsForNewTopic && s.secondsSinceShown >= 2 }
        return s.delivered || s.queuedIsForNewTopic
    }

    /// Answers only count if they're for the newest request (older ones finishing late are dropped).
    public static func isFresh(requestID: Int, latestID: Int) -> Bool { requestID == latestID }
}

/// Who is talking, read from audio timestamps (when the words were spoken), not from when the
/// transcript happened to arrive. Each side's speech is a list of time ranges on one shared clock.
/// Deepgram revises a range while it's interim (the end grows, the start may shift), so the newest
/// interim range replaces the previous interim one. A turn change is classified by how the ranges sit:
///   turn taking   the new speaker starts after the other one's words end (any gap, even 0.1 s)
///   backchannel   a short "yeah", "uh-huh", "right" over the other side: not a turn at all
///   interruption  the new speaker starts while the other is talking, and the other stops soon after
///   overlap       both keep talking at once (crosstalk)
/// Time windows are only a fallback: they say whether a side is still "active" while its next
/// transcript is in flight, never whether two sides overlapped.
public struct SpeechTimeline: Sendable {
    public enum Side: String, Sendable { case rep, prospect }
    public enum Kind: String, Sendable { case turnTaking = "turn_taking", backchannel, interruption, overlap }

    public struct Segment: Sendable, Equatable {
        public var side: Side, start: Double, end: Double, text: String, isFinal: Bool
        public var kind: Kind?
    }

    /// Deepgram boundaries jitter by about a word; overlap smaller than this is a clean hand-off.
    public static let tolerance = 0.25
    /// The interrupted side stopping within this long of the newcomer's start means it yielded.
    public static let yieldWindow = 1.0
    /// Fallback only: a side counts as still talking this long after its last word, to bridge
    /// transcript delay and breaths. Never used to decide overlap.
    public static let repActiveWindow = 1.5
    public static let prospectActiveWindow = 0.9

    public static let backchannelWords: Set<String> = ["yeah", "yep", "yes", "uh-huh", "uh", "huh", "mhm", "mm", "hmm", "mm-hmm",
        "right", "okay", "ok", "sure", "got", "it", "gotcha", "totally", "true", "cool", "nice", "wow", "oh"]

    public private(set) var segments: [Side: [Segment]] = [.rep: [], .prospect: []]

    public init() {}

    public static func isBackchannel(_ text: String) -> Bool {
        let w = text.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted).filter { !$0.isEmpty }
        return !w.isEmpty && w.count <= 2 && w.allSatisfy(backchannelWords.contains)
    }

    /// Adds or revises one transcript range. Returns the segment's classification when it is new
    /// or changed (so the caller logs every decision once), else nil.
    @discardableResult
    public mutating func update(_ side: Side, start: Double, end: Double, text: String, isFinal: Bool) -> Kind? {
        var list = segments[side] ?? []
        var seg = Segment(side: side, start: start, end: max(end, start), text: text, isFinal: isFinal)
        let old: Kind?
        if let last = list.last, !last.isFinal { old = last.kind; list.removeLast() } else { old = nil }
        seg.kind = classify(seg)
        list.append(seg)
        if list.count > 40 { list.removeFirst(list.count - 40) }
        segments[side] = list
        // A newcomer can turn an earlier "interruption" of the other side into crosstalk: re-check it.
        reclassifyOther(than: side)
        return seg.kind != old ? seg.kind : nil
    }

    private func classify(_ x: Segment) -> Kind? {
        let other: Side = x.side == .rep ? .prospect : .rep
        // The other side's most recent range that started before this one.
        guard let y = segments[other]?.last(where: { $0.start <= x.start }) else { return nil }
        let overlap = min(x.end, y.end) - max(x.start, y.start)
        if overlap <= Self.tolerance { return .turnTaking }
        if Self.isBackchannel(x.text) { return .backchannel }
        // Did the other side keep going after this side came in?
        let otherKeptGoing = (segments[other] ?? []).contains { $0.end > x.start + Self.yieldWindow && $0.start < x.end }
        return otherKeptGoing ? .overlap : .interruption
    }

    private mutating func reclassifyOther(than side: Side) {
        let other: Side = side == .rep ? .prospect : .rep
        guard var list = segments[other], var last = list.last else { return }
        last.kind = classify(last)
        list[list.count - 1] = last
        segments[other] = list
    }

    /// Who holds the floor at `now` (same clock as the ranges).
    public func now(_ now: Double) -> (rep: Bool, prospect: Bool, overlap: Bool) {
        let rep = segments[.rep]?.last, pro = segments[.prospect]?.last
        // A backchannel never takes the turn.
        let repActive = rep.map { now - $0.end < Self.repActiveWindow && $0.kind != .backchannel } ?? false
        let proActive = pro.map { now - $0.end < Self.prospectActiveWindow && $0.kind != .backchannel } ?? false
        guard repActive, proActive, let r = rep, let p = pro else { return (repActive, proActive, false) }
        let newer = r.start >= p.start ? r : p
        if newer.kind == .interruption || newer.kind == .overlap {
            // Real overlap only while both ranges actually cross in audio time.
            if min(r.end, p.end) - max(r.start, p.start) > Self.tolerance { return (true, true, true) }
        }
        // Clean hand-off: whoever started last holds the turn.
        return newer.side == .rep ? (true, false, false) : (false, true, false)
    }
}

/// "Take me off your list", "don't call me back": matched in code, no AI.
public enum OptOut {
    public static let phrases = ["take me off your list", "take me off the list", "remove me from your list",
                                 "remove me from the list", "don't call me again", "do not call me again",
                                 "stop calling me", "put me on your do not call", "do not call list",
                                 "don't ever call", "never call me", "quit calling", "lose my number",
                                 "don't call me back", "do not call me back", "don't call back", "don't call here",
                                 "don't call this number", "never call here", "never call this number", "remove my number",
                                 "take my number off", "delete my number", "don't contact me", "do not contact me",
                                 "stop contacting me", "never call again", "don't call again", "do not call again"]

    public static func matches(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "dont ", with: "don't ")
        return phrases.contains { t.contains($0) }
    }
}

/// When to start Claude before the prospect is done. A one or two word fragment ("No.") is not
/// worth a request: it almost always grows ("No. No. Just don't call me back."), wasting the draft.
public enum EarlyStart {
    public static let minFinishedWords = 3
    public static let minUnfinishedWords = 6

    /// Milliseconds to wait for the words to hold still, or nil for "don't start early".
    public static func delayMS(for text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if OptOut.matches(t) { return nil } // handled in code, never drafted
        let words = t.split(separator: " ").count
        let finished = t.last.map { ".?!".contains($0) } ?? false
        if finished && words >= minFinishedWords { return 200 }
        if words >= minUnfinishedWords { return 450 }
        return nil
    }
}

/// Reading level for every word the rep reads or a prospect hears: 1st to 5th grade.
/// Flesch-Kincaid grade, with names left out (a name like "Clarity Consulting" is read once,
/// not sounded out, and shouldn't push a plain line over).
public enum ReadingLevel {
    /// The prompt asks for grade 1 to 5. The check allows one grade of slack, since the formula
    /// is noisy on one or two short sentences.
    public static let target = 5.0
    public static let checkMax = 6.0

    public static let rule = """
    Reading level, always: every word the rep will say, read or send (lines, scripts, voicemails, texts, notes)
    is at a 1st to 5th grade reading level. Short, common words of one or two syllables. Short sentences,
    under 12 words each. No jargon, no long words when a short one works ("use" not "utilize", "help" not
    "facilitate", "about" not "approximately"). Names of people and companies are fine as they are.
    """

    static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter { $0.isLetter }
        guard !w.isEmpty else { return 0 }
        if w.count <= 3 { return 1 }
        let vowels = Set("aeiouy")
        var count = 0, prev = false
        for c in w { let v = vowels.contains(c); if v && !prev { count += 1 }; prev = v }
        if w.hasSuffix("e"), !w.hasSuffix("le"), count > 1 { count -= 1 }
        if w.hasSuffix("ed"), count > 1, !(w.hasSuffix("ted") || w.hasSuffix("ded")) { count -= 1 }
        return max(1, count)
    }

    /// Flesch-Kincaid grade level. Capitalized words after a sentence's first word count as names (1 syllable).
    public static func grade(_ text: String) -> Double {
        let sentences = text.split(whereSeparator: { ".?!".contains($0) })
            .map { $0.split(separator: " ").map(String.init).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) } }
            .filter { !$0.isEmpty }
        let words = sentences.reduce(0) { $0 + $1.count }
        guard words > 0 else { return 0 }
        var syl = 0
        for s in sentences {
            for (i, w) in s.enumerated() {
                let isName = i > 0 && (w.first?.isUppercase ?? false) && w != "I" && !w.hasPrefix("I'")
                syl += isName ? 1 : (w.allSatisfy({ $0.isNumber || ",.".contains($0) }) ? 2 : syllables(w))
            }
        }
        return 0.39 * Double(words) / Double(sentences.count) + 11.8 * Double(syl) / Double(words) - 15.59
    }

    public static func tooHard(_ text: String) -> Bool { grade(text) > checkMax }
}

/// Live line length. The prompt asks for fewer words than the check allows, so a line that runs a
/// word long passes instead of costing a second fixing it.
public enum LineBudget {
    public static let checkMax = 25
    public static let promptMax = 20
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

    /// The words behind a delivery score, for the trace: which of the line's key words were said.
    public static func evidence(line: String, spoken: String) -> (matched: [String], missing: [String]) {
        let said = Set(words(spoken))
        var seen = Set<String>(), matched: [String] = [], missing: [String] = []
        for w in words(line) where seen.insert(w).inserted { if said.contains(w) { matched.append(w) } else { missing.append(w) } }
        return (matched, missing)
    }

    /// Is the rep on the line at all (enough to call it delivering, not just talking)?
    public static func onLine(line: String, spoken: String) -> Bool {
        evidence(line: line, spoken: spoken).matched.count >= 2 || confidence(line: line, spoken: spoken) >= 0.25
    }

    /// Which rule (if any) counted it delivered: "overall" or "question".
    public static func rule(line: String, spoken: String) -> String? {
        if confidence(line: line, spoken: spoken) >= 0.5 { return "overall" }
        if let q = line.split(separator: "?").first.map(String.init),
           let lastSentence = q.split(whereSeparator: { ".!".contains($0) }).last.map(String.init),
           confidence(line: lastSentence, spoken: spoken) >= 0.6 { return "question" }
        return nil
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

/// Objections on this call, tracked in code from the transcript (no AI).
/// Addressed is not resolved: "addressed" only means the rep answered it. Only the prospect's
/// next words can mark it resolved, still open, or uncertain.
public struct ObjectionTracker: Sendable {
    public enum Status: String, Sendable { case raised, addressed, resolved, stillOpen = "still_open", uncertain }
    public struct Objection: Sendable, Equatable {
        public let id: Int
        public let kind: String          // e.g. "not interested"
        public let raisedText: String    // their exact words
        public let raisedTurn: Int       // transcript turn number
        public var status: Status
        public var addressedText = ""    // the rep's answer
        public var addressedTurn = 0
        public var evidenceText = ""     // the prospect's words that decided resolved / still open / uncertain
        public var evidenceTurn = 0
    }
    public struct Change: Sendable, Equatable {
        public let objection: Objection
        public let from: Status?
        public let why: String
    }

    /// Common cold-call objections: a name and the phrases that mean it.
    public static let kinds: [(String, [String])] = [
        ("not interested", ["not interested", "no interest", "not for us", "we're good", "we are good", "i'm good", "pass on"]),
        ("no time", ["no time", "too busy", "i'm busy", "in a meeting", "bad time", "not a good time", "driving"]),
        ("send info", ["send me an email", "send me something", "send me info", "email me", "send it over", "send me some"]),
        ("already have it", ["we already have", "we already use", "we use", "already working with", "we have a partner", "we have someone", "in house", "in-house"]),
        ("happy as is", ["happy with", "it's working", "works fine", "we're fine", "don't need", "do not need", "no need"]),
        ("price", ["too expensive", "no budget", "can't afford", "cost too much", "costs too much", "not in the budget"]),
        ("wrong person", ["not the right person", "not my area", "not my department", "talk to someone else", "i don't handle"]),
        ("call later", ["call me later", "call back later", "call me next", "reach out next", "maybe later", "not right now"]),
        ("trust", ["how did you get my number", "who gave you", "is this a sales call", "is this a scam"]),
    ]
    static let stillOpenWords = ["no", "nope", "still not", "not interested", "i said", "like i said", "already told you", "not really", "i don't think so"]
    static let resolvedWords = ["sure", "okay", "ok", "go ahead", "yeah", "yes", "tell me", "what is it", "how does", "how much", "what do you",
                                "that's fair", "fair enough", "makes sense", "i guess so", "interesting", "send it", "let's do", "that works"]
    static let uncertainWords = ["hmm", "maybe", "i don't know", "not sure", "we'll see", "possibly", "i guess"]

    public private(set) var objections: [Objection] = []
    private var nextID = 1
    public init() {}

    /// The objection kind in these words, or nil. Script "sounds like" phrases can add their own kinds.
    public static func detect(_ text: String, extra: [(String, [String])] = []) -> String? {
        let t = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
        return (extra + kinds).first { $0.1.contains { t.contains($0) } }?.0
    }

    static func has(_ text: String, _ words: [String]) -> Bool {
        let t = " " + text.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted).joined(separator: " ") + " "
        return words.contains { t.contains(" \($0) ") }
    }

    /// Feed each finalized turn. `turn` is the transcript turn number (for evidence in the trace).
    public mutating func add(turn text: String, from speaker: QuestionTracker.Speaker, turn: Int,
                             extra: [(String, [String])] = []) -> [Change] {
        var out: [Change] = []
        func set(_ i: Int, _ s: Status, why: String) {
            let from = objections[i].status
            objections[i].status = s
            out.append(Change(objection: objections[i], from: from, why: why))
        }
        if speaker == .rep {
            // The rep answered any objection still waiting. Addressed, not resolved.
            for i in objections.indices where [.raised, .stillOpen].contains(objections[i].status) && text.split(separator: " ").count >= 3 {
                objections[i].addressedText = text
                objections[i].addressedTurn = turn
                set(i, .addressed, why: "rep answered it (turn \(turn)); waiting on the prospect")
            }
            return out
        }
        // Prospect: first judge any objection the rep just addressed, from their words only.
        let newKind = Self.detect(text, extra: extra)
        for i in objections.indices where objections[i].status == .addressed {
            objections[i].evidenceText = text
            objections[i].evidenceTurn = turn
            if newKind == objections[i].kind || Self.has(text, Self.stillOpenWords) {
                set(i, .stillOpen, why: "prospect pushed back again (turn \(turn))")
            } else if Self.has(text, Self.uncertainWords) {
                set(i, .uncertain, why: "prospect's answer is unsure (turn \(turn))")
            } else if Self.has(text, Self.resolvedWords) || (newKind == nil && text.split(separator: " ").count >= 6) {
                set(i, .resolved, why: "prospect moved on or agreed (turn \(turn))")
            } else {
                set(i, .uncertain, why: "prospect's answer doesn't settle it (turn \(turn))")
            }
        }
        // A new objection (not one already open of the same kind).
        if let kind = newKind, !objections.contains(where: { $0.kind == kind && $0.status != .resolved }) {
            objections.append(Objection(id: nextID, kind: kind, raisedText: text, raisedTurn: turn, status: .raised))
            nextID += 1
            out.append(Change(objection: objections[objections.count - 1], from: nil, why: "prospect raised it (turn \(turn))"))
        }
        return out
    }

    /// For Claude's context. Empty when there are none.
    public var promptText: String {
        objections.map { o in
            var line = "- \(o.kind) (turn \(o.raisedTurn), \"\(o.raisedText)\"): "
            switch o.status {
            case .raised: line += "NOT answered yet"
            case .addressed: line += "rep answered it, prospect hasn't responded yet. NOT resolved"
            case .resolved: line += "resolved: they said \"\(o.evidenceText)\""
            case .stillOpen: line += "STILL OPEN after the rep's answer: they said \"\(o.evidenceText)\""
            case .uncertain: line += "unclear: they said \"\(o.evidenceText)\""
            }
            return line
        }.joined(separator: "\n")
    }
}
