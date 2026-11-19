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

extension CoachSignals {
    /// For the trace, as JSON fields (not one long string).
    public var trace: [String: Any] {
        ["has_line": hasLine, "prospect_speaking": prospectSpeaking, "rep_speaking": repSpeaking,
         "seconds_since_shown": (secondsSinceShown * 100).rounded() / 100, "rep_started": repStarted, "delivered": delivered,
         "prospect_answered": prospectAnsweredSince, "queued": queued, "new_topic": queuedIsForNewTopic, "line_words": lineWords,
         "overlapping": overlapping, "rep_on_line": repOnLine, "do_not_call": doNotCall]
    }
}

public enum CoachMachine {
    /// How long a brand-new line is protected for reading before an un-started line can be swapped.
    public static let readingGrace = 1.2

    /// Silent reading can't be seen, so protect it by length: about 4 words a second, 1.2 to 5 seconds.
    /// Reading under pressure: about 3 words a second, plus about 1.5 s to start speaking. 2 to 6.5 s.
    public static func readingTime(words: Int) -> Double { min(6.5, max(2.0, Double(words) / 3 + 1.5)) }

    public static func state(_ s: CoachSignals) -> CoachState {
        if s.doNotCall { return .doNotCall }
        // Only real overlap is an interruption. One side answering right after the other is a normal turn.
        if s.overlapping { return .interrupted }
        // Delivering = saying the line on screen. Any other rep talk ("okay", small talk) is just talking.
        // Once delivered and answered, new rep talk is the rep's own words, not this line.
        if s.repSpeaking {
            let onThisLine = s.hasLine && !(s.delivered && s.prospectAnsweredSince) && (s.repOnLine || s.delivered)
            return onThisLine ? .delivering : .repTalking
        }
        if s.queued && s.queuedIsForNewTopic && s.repStarted && !s.delivered { return .superseded }
        if s.prospectSpeaking { return .listening }
        guard s.hasLine else { return .idle }
        if s.delivered && s.prospectAnsweredSince { return .resolved }
        if !s.repStarted { return .reading } // one steady label while it's theirs to read (no flicker)
        return .reading
    }

    /// May a newer line replace the one on screen right now?
    /// Never while the rep speaks. Not during the first moment of reading. Otherwise yes if the rep
    /// hasn't started it, it's been delivered, or the conversation clearly moved on.
    public static func canReplace(_ s: CoachSignals) -> Bool {
        if s.doNotCall { return false } // the goodbye line stays; nothing replaces it
        guard s.hasLine else { return true }
        if s.repSpeaking { return false }
        // Not started: only something new from the prospect replaces it, never the clock alone, and
        // never before the line has had its reading time (about 4 words a second, up to 5 s).
        if !s.repStarted { return s.queuedIsForNewTopic && s.secondsSinceShown >= readingTime(words: s.lineWords) }
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

    /// "Don't call me back" can mean "call me later" ("...until Tuesday"). Those only count on a final
    /// transcript, and not when a later time follows. Clear phrases ("take me off your list") count at once.
    static let ambiguous = ["don't call me back", "do not call me back", "don't call back", "don't call me again",
                            "do not call me again", "don't call again", "do not call again", "don't call here"]

    /// The words contain a phrase that might be a callback ("...until Tuesday"): wait for the full pause before acting.
    public static func hasAmbiguous(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "dont ", with: "don't ")
        return ambiguous.contains { t.contains($0) }
    }
    static let deferrals = ["until", "till", "later", "tomorrow", "next", "after", "monday", "tuesday", "wednesday",
                            "thursday", "friday", "in a few", "in an hour", "when", "this afternoon", "tonight"]

    public static func matches(_ text: String, isFinal: Bool = true) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "dont ", with: "don't ")
        for p in phrases where t.contains(p) {
            guard ambiguous.contains(p) else { return true }
            guard isFinal, let r = t.range(of: p) else { continue }
            let after = " " + t[r.upperBound...].prefix(40).split(whereSeparator: { !$0.isLetter && $0 != "'" }).joined(separator: " ") + " "
            if !deferrals.contains(where: { after.contains(" \($0) ") }) { return true } // whole words: "still" isn't "till"
        }
        return false
    }
}

/// MOVE: silent keeps the line on screen only if it still fits. If the talk moved past it, it's cleared.
public enum SilentRule {
    public static func clearCurrent(superseded: Bool, delivered: Bool, answered: Bool) -> Bool {
        superseded || (delivered && answered)
    }

    /// The same, but never pulled from under the rep: not while they talk or are still reading it.
    public static func clearNow(superseded: Bool, delivered: Bool, answered: Bool, signals: CoachSignals) -> Bool {
        guard clearCurrent(superseded: superseded, delivered: delivered, answered: answered) else { return false }
        if signals.repStarted && !signals.delivered { return false } // partway through it: let them finish
        var s = signals
        s.queuedIsForNewTopic = superseded || s.queuedIsForNewTopic
        return CoachMachine.canReplace(s)
    }
}

/// When to start Claude before the prospect is done. A one or two word fragment ("No.") is not
/// worth a request: it almost always grows ("No. No. Just don't call me back."), wasting the draft.
public enum EarlyStart {
    public static let minFinishedWords = 4 // real words, not "I", "yeah", "so"
    public static let minUnfinishedWords = 6

    /// Another early draft for the same turn only when their meaning moved: 5+ more words, or a sentence
    /// finished since the last draft. Stops a burst of near-identical requests while they talk.
    public static let maxDraftsPerTurn = 2
    public static func shouldRedraft(previous: String?, text: String, draftsThisTurn: Int) -> Bool {
        guard draftsThisTurn < maxDraftsPerTurn else { return false }
        guard let previous else { return true }
        let grew = text.split(separator: " ").count - previous.split(separator: " ").count
        let finishedNow = (text.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false)
        let finishedBefore = (previous.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false)
        return grew >= 5 || (finishedNow && !finishedBefore && grew >= 2)
    }

    /// Milliseconds to wait for the words to hold still, or nil for "don't start early".
    public static func delayMS(for text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if OptOut.matches(t) || OptOut.hasAmbiguous(t) { return nil } // handled in code, never drafted (Fix 3)
        let filler: Set<String> = ["i", "yeah", "so", "um", "uh", "well", "oh", "like", "okay", "ok", "and", "but", "the", "a"]
        let words = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).filter { !filler.contains(String($0)) }.count
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
        "at", "be", "can", "if", "about", "as", "have", "has", "was", "they", "them", "their", "would"]
    // Question words (what, how, who, when, why) are kept: they carry the point of a question.

    /// A light stem, so "updating"/"updated"/"updates" and "calls"/"called" match.
    static func stem(_ w: String) -> String {
        if w.count > 5, w.hasSuffix("ing") { return String(w.dropLast(3)) }
        if w.count > 4, w.hasSuffix("ed") { return String(w.dropLast(2)) }
        if w.count > 4, w.hasSuffix("ly") { return String(w.dropLast(2)) }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast(1)) }
        return w
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 && !stop.contains($0) }.map(stem)
    }

    static let negations: Set<String> = ["not", "no", "never", "don't", "doesn't", "didn't", "won't", "can't", "isn't", "aren't",
                                         "wasn't", "haven't", "hasn't", "dont", "cant", "wont", "nobody", "nothing"]

    /// The rep said the opposite: a negation the line doesn't have, right before one of the line's words.
    static func negated(line: String, spoken: String) -> Bool {
        func tokens(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
                .map { $0.replacingOccurrences(of: "\u{2019}", with: "'") }
        }
        let lineTokens = Set(tokens(line))
        let key = Set(words(line))
        let t = tokens(spoken)
        for (i, w) in t.enumerated() where negations.contains(w) && !lineTokens.contains(w) {
            if t[(i + 1)..<min(t.count, i + 4)].contains(where: { key.contains(stem($0)) }) { return true }
        }
        return false
    }

    /// 0 to 1: share of the line's meaningful words the rep said. 0 if they said the opposite.
    public static func confidence(line: String, spoken: String) -> Double {
        let want = Set(words(line))
        guard !want.isEmpty, !negated(line: line, spoken: spoken) else { return 0 }
        let said = Set(words(spoken))
        return Double(want.intersection(said).count) / Double(want.count)
    }

    /// Partly said in the rep's own words (a paraphrase): not confirmed delivery, but not "never said" either.
    public static func likelyCovered(line: String, spoken: String) -> Bool {
        evidence(line: line, spoken: spoken).matched.count >= 2 && confidence(line: line, spoken: spoken) >= 0.35
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
    /// A line with a question is delivered when its question is asked (or nearly all of it is said):
    /// half the words of the intro is not the point of the line.
    public static func rule(line: String, spoken: String) -> String? {
        if line.contains("?") {
            if let q = line.split(separator: "?").first.map(String.init),
               let lastSentence = q.split(whereSeparator: { ".!".contains($0) }).last.map(String.init),
               confidence(line: lastSentence, spoken: spoken) >= 0.6 { return "question" }
            return confidence(line: line, spoken: spoken) >= 0.8 ? "overall" : nil
        }
        return confidence(line: line, spoken: spoken) >= 0.5 ? "overall" : nil
    }

    public static func delivered(line: String, spoken: String) -> Bool { rule(line: line, spoken: spoken) != nil }
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
    public enum Status: String, Sendable { case open, answered, interrupted, abandoned, uncertain }
    public struct Question: Sendable, Equatable {
        public let id: Int
        public let asker: Speaker
        public let text: String
        public var status: Status
        public var answer: String
    }
    public enum Change: Sendable, Equatable {
        case asked(Question), answered(Question), interrupted(Question), abandoned(Question), uncertain(Question)
    }

    public private(set) var questions: [Question] = []
    private var nextID = 1
    public init() {}

    private static let filler: Set<String> = ["uh", "um", "hmm", "mm", "mhm", "uh-huh", "huh"]
    private static let starts = ["who", "what", "when", "where", "why", "how", "do", "does", "did", "is", "are", "can",
                                 "could", "would", "will", "should", "have", "has", "any", "which"]

    /// The questions in a turn: sentences ending in "?" (or starting like a question when no punctuation came through).
    public static func questions(in text: String) -> [String] {
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
        // The other side's open questions: answered only by a real answer. A question back, a
        // deflection or a refusal leaves it uncertain (still not answered). Cut off if talked over.
        for i in questions.indices where questions[i].asker != speaker
            && (questions[i].status == .open || questions[i].status == .uncertain) && substantive {
            if overlapped, questions[i].status == .open {
                questions[i].status = .interrupted
                changes.append(.interrupted(questions[i]))
            } else if AnswerEvidence.isAnswer(text) {
                questions[i].status = .answered
                questions[i].answer = text
                changes.append(.answered(questions[i]))
            } else if questions[i].status == .open {
                questions[i].status = .uncertain
                questions[i].answer = text
                changes.append(.uncertain(questions[i]))
            }
        }
        let asked = Self.questions(in: text)
        // Asking again before getting an answer abandons the earlier one.
        if !asked.isEmpty {
            for i in questions.indices where questions[i].asker == speaker
                && (questions[i].status == .open || questions[i].status == .interrupted || questions[i].status == .uncertain) {
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
        let repUncertain = questions.filter { $0.asker == .rep && $0.status == .uncertain }
        var lines: [String] = []
        if !theirsOpen.isEmpty { lines.append("Prospect questions NOT yet answered (answer these first): " + theirsOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
        if !repOpen.isEmpty { lines.append("Rep questions still waiting for an answer: " + repOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
        if !repUncertain.isEmpty { lines.append("Rep questions NOT answered (they asked back, deflected or declined; don't treat as answered, don't push): " + repUncertain.map { "\"\($0.text)\" -> they said \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
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
        ("won't share", ["can't discuss", "cannot discuss", "not something i can discuss", "can't share", "cannot share",
                         "not something i can share", "confidential", "can't talk about", "not able to discuss", "not at liberty"]),
        ("ending the call", ["thank you for calling", "thanks for calling", "thanks for the call", "have a good day",
                             "have a great day", "i have to go", "i've got to go", "gotta go", "i need to go"]),
        ("not interested", ["not interested", "no interest", "not for us", "we're good", "we are good", "i'm good", "pass on"]),
        ("no time", ["no time", "too busy", "i'm busy", "in a meeting", "bad time", "not a good time", "driving"]),
        ("send info", ["send me an email", "send me something", "send me info", "email me", "send it over", "send me some"]),
        ("already have it", ["we already have", "we already use", "we use another", "we use a ", "already working with", "we have a partner", "we have someone", "in house", "in-house"]),
        ("happy as is", ["happy with", "it's working", "works fine", "we're fine", "don't need", "do not need", "no need"]),
        ("price", ["too expensive", "no budget", "can't afford", "cost too much", "costs too much", "not in the budget"]),
        ("wrong person", ["not the right person", "not my area", "not my department", "talk to someone else", "i don't handle"]),
        ("call later", ["call me later", "call back later", "call me next", "reach out next", "maybe later", "not right now"]),
        ("trust", ["how did you get my number", "who gave you", "is this a sales call", "is this a scam"]),
    ]
    static let stillOpenWords = ["no", "nope", "still not", "not interested", "i said", "like i said", "already told you", "not really", "i don't think so",
                                 "can't do", "cannot do", "won't work", "not looking", "not a priority", "no thanks"]
    static let contrastWords = ["but", "however", "though", "although"]
    /// Words that show the rep spoke to this kind of objection (plus general acknowledgments).
    static let addressCues: [String: [String]] = [
        "not interested": ["interested", "fair", "understand", "get it", "makes sense", "hear you"],
        "no time": ["quick", "time", "seconds", "minute", "busy", "later", "call back"],
        "send info": ["email", "send", "info"],
        "already have it": ["already", "use", "using", "partner", "tool", "today", "working", "current"],
        "happy as is": ["fine", "working", "need", "happy", "good", "today"],
        "price": ["cost", "price", "budget", "free", "expensive", "money", "invest", "spend"],
        "wrong person": ["right person", "who", "handles", "point me", "best person", "in charge"],
        "call later": ["later", "when", "better time", "call back", "tomorrow", "next week"],
        "trust": ["number", "list", "linkedin", "found", "sales call", "honest", "research"],
        "won't share": ["no problem", "understand", "fair", "of course", "totally"],
        "ending the call": [],
    ]
    static let acknowledgments = ["fair", "understand", "totally get", "get it", "makes sense", "hear you", "appreciate", "no problem", "of course"]

    /// Did the rep's words speak to this objection? Not just any 3 words: words tied to it, or an acknowledgment.
    static func addresses(kind: String, text: String) -> Bool {
        has(text, (addressCues[kind] ?? []) + acknowledgments)
    }
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
            for i in objections.indices where [.raised, .stillOpen].contains(objections[i].status)
                && Self.addresses(kind: objections[i].kind, text: text) {
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
            } else if Self.has(text, Self.resolvedWords) && !Self.has(text, Self.contrastWords) {
                set(i, .resolved, why: "prospect agreed (turn \(turn))")
            } else if Self.has(text, Self.contrastWords) {
                set(i, .uncertain, why: "prospect agreed but added a 'but' (turn \(turn))")
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
            case .raised where o.kind == "won't share": line += "they won't share this. Respect it: don't ask about it again"
            case .raised where o.kind == "ending the call": line += "they're ending the call. Thank them and close politely, no more questions"
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


/// A line waiting in the queue (held while the rep talked) is only shown if it still fits.
/// The rep's own words are the source of truth: if they've moved on, the old line is dropped.
public enum QueuedLine {
    public static let maxAge = 8.0
    public static let maxRepWords = 8

    /// "heuristic" (the word or time limit, a safety net) or "conversation" (the rep asked their own
    /// question, a real change in the talk). Logged with every drop so the two can be told apart.
    public static func ruleKind(_ reason: String) -> String {
        reason.contains("asked") || reason.contains("pivot") ? "conversation" : "heuristic"
    }

    /// Phrases a rep uses to change direction, with or without a question mark.
    static let pivots = ["quick question", "before i let you go", "one last thing", "actually", "let me ask", "can i ask", "curious"]

    /// The rep changed direction in their own words: an unpunctuated question or a pivot phrase.
    public static func repPivoted(_ text: String) -> Bool {
        let t = text.lowercased()
        return pivots.contains(where: { t.contains($0) }) || !QuestionTracker.questions(in: text).isEmpty
    }

    /// C4: the rep asked a question after this line was requested (even while it was still being written).
    public static func repAskedSinceRequest(requestedAt: Double, lastRepQuestionAt: Double) -> Bool {
        lastRepQuestionAt > requestedAt
    }

    /// Why it's stale, or nil if it can still be shown.
    public static func staleReason(ageSeconds: Double, repWordsSinceQueued: Int, repAskedSinceQueued: Bool,
                                   repTextSinceQueued: String = "") -> String? {
        if repAskedSinceQueued { return "the rep asked their own question since" }
        if repPivoted(repTextSinceQueued) { return "the rep pivoted in their own words since" }
        if repWordsSinceQueued >= maxRepWords { return "the rep said \(repWordsSinceQueued) words of their own since" }
        if ageSeconds > maxAge { return String(format: "waited %.0f s; the talk moved on", ageSeconds) }
        return nil
    }
}

/// Small, safe fixes done in code, so a line isn't sent back to Claude (about a second) for formatting.
public enum LineRepair {
    public static let abbreviations: [String: String] = [
        "CRM": "customer system", "ROI": "return", "SDR": "rep", "SDRs": "reps", "BDR": "rep", "BDRs": "reps",
        "AE": "account rep", "AEs": "account reps", "KPI": "goal", "KPIs": "goals", "RevOps": "revenue team",
        "SaaS": "software", "B2B": "business", "ASAP": "soon", "FYI": "just so you know",
    ]

    /// The line with known abbreviations spelled out and em dashes turned to commas, or nil if an
    /// all-caps word we don't know is left (that one still goes back to Claude).
    public static func fix(_ line: String) -> String? {
        var out = line.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: ",")
        out = oneQuestion(out)
        for (abbr, plain) in abbreviations {
            out = out.replacingOccurrences(of: "\\b\(abbr)\\b", with: plain, options: .regularExpression)
        }
        let leftover = out.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 && $0.allSatisfy(\.isUppercase) && $0 != "AI" }
        return leftover.isEmpty ? out : nil
    }

    /// "Makes sense? How many reps?" -> "Makes sense. How many reps?": only the last question keeps its "?" (H4).
    public static func oneQuestion(_ line: String) -> String {
        guard let last = line.lastIndex(of: "?") else { return line }
        var out = ""
        for (i, ch) in zip(line.indices, line) { out.append(ch == "?" && i != last ? "." : ch) }
        return out
    }

    /// Fit a long line to `max` words without leaving a fragment (M7): keep the trailing question if it
    /// fits, else whole sentences from the start, else the first `max` words.
    public static func trimToFit(_ line: String, max: Int) -> String {
        let words = line.split(separator: " ")
        guard words.count > max else { return line }
        let sentences = line.split(omittingEmptySubsequences: true, whereSeparator: { ".!?".contains($0) })
        var ends: [String] = []
        var rest = Substring(line)
        for s in sentences {
            guard let r = rest.range(of: s) else { break }
            let after = rest[r.upperBound...]
            let punct = after.prefix(while: { ".!?".contains($0) })
            ends.append((s + punct).trimmingCharacters(in: .whitespaces))
            rest = after.dropFirst(punct.count)
        }
        if let q = ends.last, q.hasSuffix("?"), q.split(separator: " ").count <= max { return q }
        var kept: [String] = []
        for s in ends {
            if (kept + [s]).joined(separator: " ").split(separator: " ").count > max { break }
            kept.append(s)
        }
        return kept.isEmpty ? words.prefix(max).joined(separator: " ") : kept.joined(separator: " ")
    }
}


/// Prepare the next line while the rep is still talking off script, so it's ready the moment they
/// pause (instead of dropping the old line at the pause and making them wait for a new one).
public enum FollowRep {
    /// Should a new rep-led line be requested now, after the rep's latest words?
    /// - Not when they just asked a question (the prospect's answer comes next).
    /// - Not while they're reading the line on screen (they're on script).
    /// - Only once they've said 8+ of their own words since the last request.
    /// - `recentRepSpeech`: the rep's last couple of transcript chunks, so a line read across two
    ///   chunks still counts as on the line.
    public static func shouldPrepare(repJustSaid: String, recentRepSpeech: String, shownLine: String,
                                     shownLineDelivered: Bool, repWordsSinceLastAsk: Int) -> Bool {
        if repJustSaid.contains("?") { return false }
        if Delivery.onLine(line: shownLine, spoken: recentRepSpeech) && !shownLineDelivered { return false }
        return repWordsSinceLastAsk >= QueuedLine.maxRepWords
    }
}


/// The rep paused mid-sentence ("...take notes and keep"): they're still talking, even if the pause
/// is longer than the usual 1.5 s window. A line never changes in the middle of their sentence.
public enum RepTurn {
    public static let midSentenceHold = 3.0
    /// Words that leave a sentence hanging ("...take notes and keep", "...so", "...to the").
    public static let danglingWords: Set<String> = ["and", "or", "but", "so", "to", "the", "a", "an", "of", "with",
        "for", "in", "on", "at", "because", "like", "that", "which", "if", "then", "keep", "is", "are", "was",
        "we", "you", "i", "my", "your", "our", "um", "uh", "just", "kind", "sort", "what", "how",
        "do", "does", "have", "has", "get", "make", "need", "want", "be", "been", "about", "from", "by", "as", "really",
        "also", "very", "can", "could", "would", "will", "into", "onto", "our", "their", "this", "these", "those"]

    /// Still mid-sentence? Two signals, not punctuation alone: the transcriber's punctuation, and
    /// whether the last word leaves the sentence hanging. 3 s of silence ends it either way.
    public static func midSentence(lastFinal: String, secondsSince: Double) -> Bool {
        let t = lastFinal.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, secondsSince < midSentenceHold else { return false }
        if t.hasSuffix("?") { return false } // a question is a finished turn
        let lastWord = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
        if danglingWords.contains(lastWord) { return true }
        return !(t.last.map { ".!".contains($0) } ?? true)
    }
}


/// The rep asked a yes/no question ("Can I get 30 seconds?", "Does that sound familiar?", "...yeah?"):
/// the line for "yes" can be written before they answer. Open questions ("What do you use?") aren't.
public enum RepQuestion {
    static let closedStarts: Set<String> = ["can", "could", "would", "will", "do", "does", "did", "is", "are", "was",
        "were", "have", "has", "mind", "may", "should", "okay", "ok", "sound", "fair", "right", "yeah", "correct", "cool", "make"]

    /// The last question in what the rep said, if it's a yes/no question.
    /// Check-ins ("Still with me?") aren't a real ask: a "yeah" to them isn't a yes to anything.
    static let checkIns = ["still with me", "you there", "can you hear me", "are you there", "did i lose you", "still there"]

    /// Questions often come through with no "?" ("You guys use Salesforce right"). Treat a tag ending as one.
    public static func asQuestion(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.hasSuffix("?") else { return t }
        let l = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!, "))
        let tags = [" right", " correct", " yeah", " yes", " no", " true", " fair"]
        return tags.contains(where: { l.hasSuffix($0) }) ? l + "?" : t
    }

    public static func closedQuestion(in raw: String) -> String? {
        let t = asQuestion(raw)
        guard t.hasSuffix("?") else { return nil }
        if checkIns.contains(where: { t.lowercased().contains($0) }) { return nil }
        let sentence = t.dropLast().split(whereSeparator: { ".?!".contains($0) }).last.map(String.init) ?? ""
        var words = sentence.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        while let w = words.first, ["so", "and", "but", "well", "hey", "um", "uh", "like", "just"].contains(w) { words.removeFirst() }
        guard let first = words.first else { return nil }
        return closedStarts.contains(first) ? sentence.trimmingCharacters(in: .whitespaces) + "?" : nil
    }
}

/// What kind of answer the prospect gave to the rep's yes/no question. Only a clear yes uses the
/// line written ahead; no, unsure, or anything else gets a fresh answer from their real words.
public enum ProspectReply {
    public enum Kind: String, Sendable { case yes, no, unsure, other }
    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "correct", "right", "absolutely",
        "definitely", "totally", "go", "ahead", "fire", "away", "shoot", "of", "course", "please", "alright", "fine", "i", "guess", "it", "does", "is", "true"]

    public static func kind(_ text: String) -> Kind {
        let t = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
        let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard !words.isEmpty else { return .other }
        if ["not sure", "maybe", "depends", "hmm", "i don't know", "kind of", "sort of", "we'll see"].contains(where: { t.contains($0) }) { return .unsure }
        if words.contains("no") || words.contains("nope") || words.contains("nah") || t.contains("not really")
            || t.contains("not interested") || t.contains("i'm good") || t.contains("don't") || t.contains("not now") { return .no }
        if words.count <= 5, words.allSatisfy(yesWords.contains),
           words.contains(where: { ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "correct", "right", "absolutely", "definitely", "go", "shoot", "alright", "fine", "true"].contains($0) }) {
            return .yes
        }
        return .other
    }
}


/// The conversational move Claude picks before writing the line. "silent" means the rep doesn't need
/// a new line right now (they're mid-thought, or the line on screen still fits).
public enum Move: String, CaseIterable, Sendable {
    case answer, clarify, discover, acknowledge, objection, close, silent

    /// "MOVE: discover" -> .discover. nil if the line isn't a MOVE line.
    public static func parse(_ line: String) -> Move? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.uppercased().hasPrefix("MOVE:") else { return nil }
        let word = t.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return Move(rawValue: word) ?? (word == "handle" ? .objection : nil)
    }
}

extension RepTurn {
    /// The last word leaves the sentence hanging ("...and keep", "...so").
    public static func hangs(_ lastFinal: String) -> Bool {
        let t = lastFinal.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("?") { return false }
        let lastWord = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
        return danglingWords.contains(lastWord)
    }

    /// Is the rep still talking? Primary signals: words in the air, the transcriber's own end-of-speech
    /// call (it hears the pause in the audio), and whether the sentence is left hanging. The fixed
    /// windows (1.5 s after the last word, 3 s for an unfinished sentence) are only the fallback when
    /// the transcriber hasn't called it.
    public static func stillTalking(wordsInTheAir: Bool, endpointed: Bool, lastFinal: String,
                                    secondsSinceFinal: Double, inFallbackWindow: Bool) -> Bool {
        if wordsInTheAir { return true }
        let t = lastFinal.trimmingCharacters(in: .whitespaces)
        if hangs(lastFinal) { return secondsSinceFinal < midSentenceHold }
        if t.hasSuffix(",") { return secondsSinceFinal < midSentenceHold } // "So, essentially," is mid-thought
        if endpointed { return false }
        return inFallbackWindow || midSentence(lastFinal: lastFinal, secondsSince: secondsSinceFinal)
    }
}


/// Is the prospect's reply an answer? A question back, a deflection or a refusal is not.
public enum AnswerEvidence {
    public enum Kind: String, Sendable { case answer, counterQuestion, deflection, unsure, filler }
    static let filler: Set<String> = ["uh", "um", "hmm", "mm", "mhm", "uh-huh", "huh"]
    static let deflections = ["why are you asking", "why do you ask", "what do you mean", "who is this", "who's this",
        "can't discuss", "cannot discuss", "not something i can", "rather not", "none of your", "not going to share",
        "can't share", "cannot share", "why do you want to know", "what's this about", "what is this about", "can't say"]
    static let unsure = ["not sure", "i don't know", "no idea", "hard to say", "it depends", "depends"]
    static let whStarts: Set<String> = ["why", "what", "who", "how", "huh", "meaning", "sorry"]

    public static func kind(_ text: String) -> Kind {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
        if words.isEmpty || words.allSatisfy(filler.contains) { return .filler }
        if deflections.contains(where: { t.contains($0) }) { return .deflection }
        if unsure.contains(where: { t.contains($0) }) { return .unsure }
        if t.contains("?") { return .counterQuestion }
        if words.count <= 3, let first = words.first, whStarts.contains(first) { return .counterQuestion }
        return .answer
    }

    public static func isAnswer(_ text: String) -> Bool { kind(text) == .answer }
}


/// Call memory rules (C3, M4).
public enum CallMemoryRules {
    /// A background summary is kept only for the same call, and only if it covers more turns than the one stored.
    public static func acceptSummary(currentCallID: String, summaryCallID: String, summaryCovers: Int, storedCovers: Int) -> Bool {
        currentCallID == summaryCallID && summaryCovers > storedCovers
    }

    /// First turn (index) sent word for word: everything the summary doesn't cover, and never fewer than the last `minRecent`.
    public static func verbatimStart(totalTurns: Int, summaryCovers: Int, hasSummary: Bool, minRecent: Int = 10) -> Int {
        guard hasSummary, totalTurns > 12 else { return 0 }
        return max(0, min(summaryCovers, totalTurns - minRecent))
    }

    /// Ask for a fresh summary when 6+ turns aren't covered (a late or failed one is retried).
    public static func summaryDue(totalTurns: Int, summaryCovers: Int, inFlight: Bool) -> Bool {
        !inFlight && totalTurns > 12 && totalTurns - summaryCovers >= 6
    }
}


/// When to keep or drop the line written ahead for "yes" (H3).
public enum YesBranchRule {
    /// Keep it through small talk after the question ("Just a quick one."); drop it for a new yes/no
    /// question (a new one is written) or once the rep has said 8+ more words (the context moved on).
    public static func keep(afterRepSaid text: String, wordsSinceQuestion: Int) -> Bool {
        RepQuestion.closedQuestion(in: text) == nil && wordsSinceQuestion < QueuedLine.maxRepWords
    }

    /// A ready yes line expires: older than this since the question, it's not used, even on a clear yes.
    public static let maxAge = 12.0
    /// If they say yes while it's still being written, wait at most this long, then answer fresh.
    public static let maxWait = 1.2
    public static func usable(ageSinceQuestion: Double) -> Bool { ageSinceQuestion <= maxAge }
}


/// The meeting is only "booked" when the prospect's words agree, not when a closing line is shown (N4).
public enum GoalEvidence {
    static let agree = ["works for me", "that works", "sounds good", "send the invite", "send me the invite", "let's do",
                        "book it", "put me down", "i'm in", "see you then", "that's perfect", "perfect, send"]
    static let times = ["monday", "tuesday", "wednesday", "thursday", "friday", "tomorrow", "next week", " am", " pm", "o'clock"]

    public static func mentionsTime(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        // A clock time, not any number ("30 seconds" isn't a meeting time).
        let clock = #"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s?(am|pm|a\.m\.|p\.m\.)|\bat \d{1,2}\b"#
        return times.contains(where: { t.contains($0) }) || t.range(of: clock, options: .regularExpression) != nil
    }

    static let negative = ["difficult", "can't", "cannot", "won't", "busy", "bad", "doesn't work", "don't", "tough", "booked", "out of"]
    static let positive = ["works", "good", "fine", "great", "perfect", "okay", "ok", "sure", "yes", "yeah"]

    /// `afterTimeOffer`: the line they answered offered a time, so a plain "sure" agrees to it.
    public static func confirms(_ prospectSaid: String, afterTimeOffer: Bool = false) -> Bool {
        let t = " " + prospectSaid.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
        let kind = ProspectReply.kind(prospectSaid)
        if kind == .no || kind == .unsure { return false }
        if t.contains(" but ") || t.contains("not ") || negative.contains(where: { t.contains($0) }) { return false }
        if agree.contains(where: { t.contains($0) }) { return true }
        // A day or time alone isn't agreement ("Tuesday is difficult"): it needs a positive word with it.
        if times.contains(where: { t.contains($0) }) { return positive.contains(where: { t.contains(" \($0)") }) }
        return kind == .yes && afterTimeOffer
    }
}


/// The screen controller's two decisions, shared by the app and the replay tests (H7), so the tests
/// prove the code the app actually runs.
public enum CoachController {
    public enum Offer: Equatable, Sendable { case show, queue, drop(String) }
    public enum Promote: Equatable, Sendable { case wait, show, drop(String) }

    /// An ordinary new line waits while the prospect is talking, so the rep's eyes stay on them.
    /// It shows when they stop. Exceptions live elsewhere and are untouched: openers, voicemail,
    /// screeners, opt-out (the goodbye line), and a line the rep asked for with Space.
    public static func waitForProspect(_ s: CoachSignals) -> Bool {
        s.hasLine && s.prospectSpeaking && !s.doNotCall
    }

    /// A finished line arrives. Openers, voicemails and the first line show at once; anything else
    /// only if the line on screen can be replaced now, else it waits in the queue.
    /// `staleReason`: why the rep has moved past this line since it was asked for (checked before showing too).
    public static func offer(isOpenerOrVoicemail: Bool, firstLine: Bool, holdLine: Bool, signals: CoachSignals,
                             staleReason: String? = nil) -> Offer {
        if isOpenerOrVoicemail || firstLine { return .show }
        if let why = staleReason { return .drop(why) }
        if waitForProspect(signals) { return .queue }
        return !holdLine && CoachMachine.canReplace(signals) ? .show : .queue
    }

    /// A queued line, checked on each tick or when the rep's speech ends: wait, show, or drop as stale.
    public static func promote(holdLine: Bool, signals: CoachSignals, ageSeconds: Double, repWordsSinceQueued: Int,
                               repAskedSinceQueued: Bool, repTextSinceQueued: String) -> Promote {
        guard !holdLine, !waitForProspect(signals), CoachMachine.canReplace(signals) else { return .wait }
        if let why = QueuedLine.staleReason(ageSeconds: ageSeconds, repWordsSinceQueued: repWordsSinceQueued,
                                            repAskedSinceQueued: repAskedSinceQueued, repTextSinceQueued: repTextSinceQueued) {
            return .drop(why)
        }
        return .show
    }
}


/// A possible opt-out ("Don't call me back") waiting to see if a later time follows (Fix 1).
/// It is never dropped: it resolves as an opt-out unless a later time actually follows.
public enum PendingOptOut {
    public enum Outcome: Equatable, Sendable { case optOut, callback, wait }
    /// Long enough for "Don't call me back... until Tuesday" with a real pause. Restarts on any new prospect words.
    public static let timeout = 2.5

    /// - later: what the prospect said after the phrase (may be empty).
    /// - utteranceEnded / callEnded / secondsWaited: what has happened since. Any of them decides it.
    public static func resolve(pending: String, later: String, utteranceEnded: Bool, callEnded: Bool, secondsWaited: Double) -> Outcome {
        // A pause alone (utterance end with nothing after) doesn't decide it: only their next words, the call ending,
        // or the full timeout. Deepgram's 1.0 s pause call came before the timer and cut the window short.
        let decided = !later.isEmpty || callEnded || secondsWaited >= timeout
        _ = utteranceEnded
        guard decided else { return .wait }
        let whole = (pending + " " + later).trimmingCharacters(in: .whitespaces)
        return OptOut.matches(whole, isFinal: true) ? .optOut : .callback
    }
}

/// A pending goal counts down once per full prospect turn, not per transcript chunk (Fix 5).
public enum GoalPendingRule {
    public static func turnsLeft(after turnsLeft: Int, confirmed: Bool) -> Int { confirmed ? 0 : max(0, turnsLeft - 1) }
}

extension CoachController {
    /// May an interrupting line (screener, nudge) show right now? Not over the rep's speech or reading (Fix 6).
    public static func canInterrupt(signals: CoachSignals) -> Bool {
        var s = signals
        s.queuedIsForNewTopic = true
        return !s.repSpeaking && CoachMachine.canReplace(s)
    }
}


/// "Two no's and a go": one no gets one respectful question; two no's (or a no plus a sign-off) ends it (call 6).
public enum Rejection {
    // Only clear no's. Reflex brush-offs ("we're good", "I'm good") don't count: they often open up right after.
    static let nos = ["not interested", "not relevant", "no thanks", "no thank you", "not a fit",
                      "not for us", "not really interested", "doesn't apply", "not something we need"]
    static let signOffs = ["yep thanks", "yep, thanks", "bye", "take care", "have a good one", "have a good day", "have a great day",
                           "gotta go", "got to go", "thanks anyway", "thank you anyway"]

    public static func isNo(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        // "...though our CRM data is a mess": a no that opens a door isn't a no.
        if [" but ", " though", " however", " although"].contains(where: { t.contains($0) }) { return false }
        if nos.contains(where: { t.contains($0) }) { return true }
        // "I don't think this is really relevant", "this isn't relevant to us"
        let negated = ["don't think", "not", "isn't", "doesn't"].contains { t.contains($0) }
        return negated && (t.contains("relevant") || t.contains("interested") || t.contains("a fit"))
    }

    public static func isSignOff(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: ".", with: "")
        return signOffs.contains { t.contains($0) }
    }

    /// Done: two no's, or a no that comes with a sign-off.
    public static func callOver(nosSoFar: Int, latest: String) -> Bool {
        nosSoFar >= 2 || (nosSoFar >= 1 && isSignOff(latest))
    }
}

/// When to write a line from the rep's own talk (call 6: 12 wasted calls on a monologue).
public enum FollowRepLimit {
    public static let minWords = 15
    /// At most one per stretch of rep talk (until the prospect speaks again), and only after 15+ of their words.
    public static func allowed(repWordsSinceLastAsk: Int, followsThisStretch: Int) -> Bool {
        followsThisStretch == 0 && repWordsSinceLastAsk >= minWords
    }
}


/// A line with a slot still unfilled ("[Name]", "[Day]") never shows (script rule: token fill).
public enum TokenFill {
    public static func hasOpenSlot(_ line: String) -> Bool {
        line.range(of: #"\[[^\]]{1,30}\]"#, options: .regularExpression) != nil
    }
}


/// Haiku vs Sonnet scoreboard math: is a difference real or luck?
public enum ModelTest {
    /// Two-proportion z score. |z| >= 1.96 is about 95% sure the difference is real.
    public static func z(_ a: Int, of n1: Int, vs b: Int, of n2: Int) -> Double {
        guard n1 > 0, n2 > 0 else { return 0 }
        let p1 = Double(a) / Double(n1), p2 = Double(b) / Double(n2)
        let p = Double(a + b) / Double(n1 + n2)
        let se = (p * (1 - p) * (1 / Double(n1) + 1 / Double(n2))).squareRoot()
        return se == 0 ? 0 : (p1 - p2) / se
    }

    /// "Haiku wins", "Sonnet wins" or "too close to call yet".
    public static func verdict(_ a: Int, of n1: Int, vs b: Int, of n2: Int, names: (String, String)) -> String {
        let score = z(a, of: n1, vs: b, of: n2)
        if n1 < 20 || n2 < 20 { return "not enough calls yet (need 20+ each)" }
        if score >= 1.96 { return "\(names.0) wins (95% sure)" }
        if score <= -1.96 { return "\(names.1) wins (95% sure)" }
        return "too close to call yet"
    }
}
