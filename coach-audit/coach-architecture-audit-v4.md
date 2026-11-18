# Clarity Live Coach: coach architecture, audit round 4

## What this is
This is a macOS Swift app that coaches a sales rep live during cold calls.
- **Audio:** Deepgram transcribes the rep and the prospect as two separate streams.
- **Lines:** Claude Haiku 5.5 writes the next line for the rep to say.
- **Trace:** every call is logged as a JSONL trace, with millisecond timing.

Earlier rounds are summarized in `coach-audit/coach-architecture-audit-v2.md` and `-v3.md`.

**Note:** this code was pushed but its CI build hadn't finished when this pack was made. Treat compile errors as possible.

## What changed since round 3 (the round 3 audit fixes)
1. **`doNotCall` resets at the start of `nextCall()`,** before the next person's opener is prepared. The goodbye line no longer carries into the next call.
2. **The yes line and script answers call `markRequestStart()`.** They're new requests, so what the rep said earlier doesn't make them stale on arrival.
3. **Drop-on-arrival in `offer()`:**
   - Reading the shown line on script doesn't count as "moved on" (word count set to 0).
   - `followRep()` only fires on the word-count reason, never after a question or a pivot.
4. **MOVE: silent never blanks a line the rep is partway through.** `SilentRule.clearNow` returns false when the rep has started the line and hasn't finished it.
5. **`GoalEvidence`:**
   - An earlier "Sure." counts if the line before the closing line offered a time (`priorLineOfferedTime`, `checkingEarlierTurn`).
   - "great" and "perfect" were removed as single-word agreement.
   - `mentionsTime` only matches clock times like "2:30", "10 am" or "at 10", not any number.
   - A pending goal expires after 2 prospect turns.
6. **A comma at an endpoint is mid-thought** in `RepTurn.stillTalking`.
7. **A personal opener never replaces the instant one** while the rep is speaking or has interim words.
8. **The nudge and the screener line also need `CoachMachine.canReplace`,** so they respect reading time.
9. **Opt-out:**
   - Clear phrases are checked on the whole turn so far (`uncoached + chunk`), not one chunk.
   - Callback-like phrases (`OptOut.hasAmbiguous`) show no sales line and wait for Deepgram's utterance end. Then `matches(isFinal: true)` decides between an opt-out and a callback request.
   - More phrases are treated as possible callbacks ("don't call me again", "don't call again", "don't call here").

## Known limits
- **H7 is partial.** The queue state (`pending`, `seq`) and `show()` live in the app. The replay loop uses the shared decision functions, not the app's queue code.
- **Opt-out on partial words** stays on for clear phrases. That's deliberate.
- **The checks are word and heuristic rules,** not a real relevance check.
- **`holdTask` is dead code.**
- **No live call has run** on this build yet.

## What to audit
1. New bugs or races added by the round 3 fixes, especially:
   - the ambiguous opt-out wait (what if utterance end never comes, or the call ends first?)
   - the `nextCall()` reset order
   - `markRequestStart` timing
   - goal expiry
   - the `uncoached` concatenation for opt-out
2. Any remaining way to show a stale line, change the line mid-sentence, or show a line after opt-out.
3. False facts in either direction.
4. Only things worth fixing before live testing, ranked Critical, High, Medium or Low, with file and function and a concrete failure for each.


## `mac/Sources/CoachCore/CoachCore.swift`

```swift
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
    public static func readingTime(words: Int) -> Double { min(5, max(readingGrace, Double(words) / 4)) }

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
    public static let minFinishedWords = 3
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
    public static func closedQuestion(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("?") else { return nil }
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

    /// A finished line arrives. Openers, voicemails and the first line show at once; anything else
    /// only if the line on screen can be replaced now, else it waits in the queue.
    /// `staleReason`: why the rep has moved past this line since it was asked for (checked before showing too).
    public static func offer(isOpenerOrVoicemail: Bool, firstLine: Bool, holdLine: Bool, signals: CoachSignals,
                             staleReason: String? = nil) -> Offer {
        if isOpenerOrVoicemail || firstLine { return .show }
        if let why = staleReason { return .drop(why) }
        return !holdLine && CoachMachine.canReplace(signals) ? .show : .queue
    }

    /// A queued line, checked on each tick or when the rep's speech ends: wait, show, or drop as stale.
    public static func promote(holdLine: Bool, signals: CoachSignals, ageSeconds: Double, repWordsSinceQueued: Int,
                               repAskedSinceQueued: Bool, repTextSinceQueued: String) -> Promote {
        guard !holdLine, CoachMachine.canReplace(signals) else { return .wait }
        if let why = QueuedLine.staleReason(ageSeconds: ageSeconds, repWordsSinceQueued: repWordsSinceQueued,
                                            repAskedSinceQueued: repAskedSinceQueued, repTextSinceQueued: repTextSinceQueued) {
            return .drop(why)
        }
        return .show
    }
}
```

## `mac/Sources/ClarityLiveCoach/Coach.swift`

```swift
import AppKit
import CoachCore
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// The coach: one call at a time, the person on screen, and the line to say next.
/// Split by job across the CoachModel+*.swift files. Every stored property lives here.
@MainActor
final class CoachModel: ObservableObject {
    enum Status { case ready, live, paused }

    /// Where the call is, in one word. Worked out from the flags below, so it's always in step
    /// with them; views and the log read this instead of combining flags themselves.
    enum Phase: String {
        case idle = "Idle"
        case gettingReady = "Getting ready"
        case waitingForText = "Waiting for the text"
        case countdown = "Counting down"
        case dialing = "Dialing"
        case live = "On a call"
        case paused = "Paused"
    }

    var phase: Phase {
        switch status {
        case .live: return .live
        case .paused: return .paused
        case .ready: break
        }
        if dialing || pendingDialSince != nil { return .dialing }
        if autoNextIn != nil { return .countdown }
        if gettingReady != nil { return .gettingReady }
        if waitingForText { return .waitingForText }
        return .idle
    }
    /// The last phase written to the activity log.
    var loggedPhase: Phase = .idle
    enum Kind { case opener, reply, screener, voicemail }

    @Published var status: Status = .ready
    @Published var suggestion = Suggestion()
    @Published var kind: Kind = .opener
    @Published var latestProspect = ""
    /// The live transcript lives in its own small model, so a new word only redraws the
    /// transcript, not the whole screen.
    let transcript = LiveTranscript()
    var turns: [Turn] {
        get { transcript.turns }
        set { transcript.turns = newValue }
    }
    var interim: [Speaker: String] {
        get { transcript.interim }
        set { transcript.interim = newValue }
    }
    @Published var latency: Double?
    @Published var problem: String?
    @Published var thinking = false
    /// Everything about the person on screen, in one place (see `Prospect`).
    @Published var prospect = Prospect()
    var calling: String? {
        get { prospect.calling }
        set { prospect.calling = newValue }
    }
    var recordDetails: String? {
        get { prospect.details }
        set { prospect.details = newValue }
    }
    var detailsTried: Bool {
        get { prospect.detailsTried }
        set { prospect.detailsTried = newValue }
    }
    var detailsPending: Bool {
        get { prospect.detailsPending }
        set { prospect.detailsPending = newValue }
    }
    var personalOpenerFor: String? {
        get { prospect.personalOpenerFor }
        set { prospect.personalOpenerFor = newValue }
    }
    var voicemailScript: Suggestion? {
        get { prospect.voicemail }
        set { prospect.voicemail = newValue }
    }
    var voicemailFor: String? {
        get { prospect.voicemailFor }
        set { prospect.voicemailFor = newValue }
    }
    var voicemailKey: String? {
        get { prospect.voicemailKey }
        set { prospect.voicemailKey = newValue }
    }
    var voicemailUsedDetails: Bool {
        get { prospect.voicemailUsedDetails }
        set { prospect.voicemailUsedDetails = newValue }
    }

    /// A new person is on screen: their name, and nothing yet read or written for them.
    /// (Their voicemail is handled by the caller: it's sometimes kept for a redial.)
    func meet(_ record: String?) {
        calling = record
        recordDetails = nil
        detailsTried = false
        personalOpenerFor = nil
    }
    var tabTicks = 0
    var voicemailTask: Task<Void, Never>?
    var voicemailActive = false
    var mailboxFullShown = false

    // MARK: Where the call is

    /// The four steps shown at the top: Opener -> Discovery -> Value -> Close.
    static let journey = ["Opener", "Discovery", "Value", "Close"]
    @Published var journeyStep = 0
    var nextStepName: String? { journeyStep + 1 < Self.journey.count ? Self.journey[journeyStep + 1] : nil }

    /// Lines shown on this call, so Back can show the previous one.
    var history: [(s: Suggestion, kind: Kind)] = []
    @Published var historyIndex: Int?   // nil = showing the newest line
    var canGoBack: Bool { (historyIndex ?? history.count - 1) > 0 }

    /// The rep's Salesforce list, for the Next button.
    let callList = CallList()
    var detailsTask: Task<Void, Never>?
    var listWatcher: AnyCancellable?
    var leadsWatcher: AnyCancellable?
    var leadDetailsWatcher: AnyCancellable?

    // MARK: Lead list (Salesforce) and dialing (Aircall)

    /// The call list from a Salesforce list view. When active, Chrome isn't needed at all.
    let leads = LeadQueue()
    var appliedLeadID: String?
    var foreignSkippedID: String?
    var mobileSkippedID: String?
    var skipsInARow = 0
    var openerTask: Task<Void, Never>?
    // The queued line: when it was queued and what the rep has said since (it's dropped if they moved on).
    var pendingQueuedAt = Date.distantPast
    var repWordsAtQueue = 0
    var repAskedSinceQueue = false
    // Early drafts for the prospect's current turn (to stop bursts of near-identical requests).
    var lastEarlyBasis: String?
    var earlyDraftsThisTurn = 0
    var repWordsAtLastAsk = 0
    var nextIsRepLed = false
    var repLedIDs: Set<Int> = []
    var lastRepFinal = ""
    var repEndpointed = false
    var summaryInFlight = false
    var lastRepQuestionAt = Date.distantPast
    var repTextSinceAsk = ""
    var screenerWait: Task<Void, Never>?
    var yesBranchRepWords = 0
    var yesBranchWanted: String?
    var yesBranchAskedAt = Date.distantPast
    var goalPending = false
    var goalPendingTurns = 0
    var priorLineOfferedTime = false
    var pendingAmbiguousOptOut: String?
    var blockedLoggedID = 0

    /// The prospect agreed to the meeting in their own words: now it counts.
    func confirmGoalIfAgreed(_ said: String, checkingEarlierTurn: Bool = false) {
        guard goalPending, !goalHit else { return }
        // The line they answered offered a time: the current one, or (for their earlier "Sure.") the one before it.
        let offeredTime = !suggestion.offered.isEmpty || GoalEvidence.mentionsTime(suggestion.say) || (checkingEarlierTurn && priorLineOfferedTime)
        guard GoalEvidence.confirms(said, afterTimeOffer: offeredTime) else {
            if !checkingEarlierTurn { goalPendingTurns -= 1; if goalPendingTurns <= 0 { goalPending = false } } // expires
            return
        }
        goalPending = false
        goalHit = true
        meetingThisWeek = touchpoints.meetingsThisWeek() + 1 // logged when the call ends
        meetingMoments += 1
        NSSound(named: "Hero")?.play()
        CallTrace.event("goal.confirmed", ["prospect_said": said])
    }
    var recentRepChunks: [String] = [] // the rep's last two transcript chunks (a line read across two still counts)
    /// A line written ahead for "yes" to the rep's yes/no question. Never shown until they say yes.
    var yesBranch: (question: String, s: Suggestion, ready: Bool)?
    var yesBranchTask: Task<Void, Never>?
    var lastRepFinalAt = Date.distantPast
    var pendingDialSince: Date?
    @Published var dialing = false
    @Published var dialError: String?

    // MARK: Status card (Contact: Relationship Status. Lead: Lead Status.)

    /// The Contact or Lead on screen.
    @Published var statusRecordID: String?
    /// What Salesforce says right now (nil = blank or not loaded yet).
    @Published var recordStatus: String?
    /// The record whose status is being saved right now (nil = not saving).
    @Published var savingStatusFor: String?
    /// "Saving..." only for the person on screen.
    var savingStatus: Bool { savingStatusFor != nil && savingStatusFor == statusRecordID }
    @Published var statusMessage: String?

    /// "Contact" or "Lead" for the record on screen.
    var statusObject: String? { statusRecordID.flatMap(Salesforce.objectFor) }

    // MARK: Moving on after a call: send the text, load the next person, count down, dial

    /// The "Double tap" switch next to Auto-dial: on = call each lead twice (redial), off = once.
    var doubleTap: Bool {
        get { Prefs.doubleTap }
        set { Prefs.doubleTap = newValue; objectWillChange.send() }
    }
    /// Dials per lead per visit: 2 with Double tap, otherwise 1.
    var maxAttempts: Int { doubleTap ? 2 : 1 }

    /// The "Auto-dial" switch next to Aircall phone.
    var autoDial: Bool {
        get { Prefs.autoDial }
        set { Prefs.autoDial = newValue; objectWillChange.send() }
    }

    // MARK: Double dial

    /// Calls per lead today, and whether the last call reached a person.
    var attempts: [String: Int] = [:]
    @Published var currentAttemptKey: String?
    @Published var lastCallAnswered = true
    var currentAttempts: Int { currentAttemptKey.flatMap { attempts[$0] } ?? 0 }

    /// After a first try nobody answered (or voicemail), offer to call right back.
    var shouldOfferRedial: Bool {
        status == .ready && currentAttemptKey != nil && !lastCallAnswered && currentAttempts < maxAttempts
            && !(currentAttemptKey.map(DialHistory.isMaxed) ?? false) // last try: no redial
            && !(currentAttemptKey.map(RemovedList.contains) ?? false) // marked Not Quality Prospect / Negative: no redial
    }

    var lastWaitingFor = ""

    var noMobileSkips = 0
    /// People (15 characters) whose outcome was saved after their last call.
    @Published var outcomeSaved: Set<String> = []
    /// Aircall wouldn't start a call for this person: one retry, then on to the next.
    var dialRetryKey: String?
    /// The recorded voicemail was already dropped (or is being) on this call.
    var voicemailDropStarted = false
    var dropWhyLogged = false
    var dropNowRequested = false
    var phoneButtonCheck: Task<Void, Never>?
    var phoneCallSeen = 0
    var lastTickDay = 0
    /// When the prospect's last words arrived (to time how fast the coach answered).
    var lastHeardThemAt: Date?
    var phoneSawHangUp = false
    var phoneButtonGone = 0
    /// The LinkedIn note is due for this person: the next call waits until it's sent or skipped.
    @Published var waitingForLinkedIn = false
    /// What the LinkedIn bot is doing right now, for the line under the top bar.
    @Published var linkedInStatus: String?
    /// Automatic mode: notes waiting to go out, oldest first.
    var linkedInQueue: [FollowUp] = []
    /// People the bot already took on this session (once each).
    var linkedInTried: Set<String> = []
    var linkedInWaitingNote: Set<String> = []
    var linkedInWhyLogged: Set<String> = []
    var linkedInShowing: Set<String> = []
    var linkedInGapWaiting = false
    /// A short note that fades by itself ("Text sent to Neal").
    @Published var toast: String?
    var toastTask: Task<Void, Never>?
    var bgTextTask: Task<Void, Never>?
    /// Calls in a row with no break longer than 3 minutes.
    @Published var streak = 0
    var lastDialAt = Date.distantPast
    /// A 50 minute calling block, then a 10 minute break. nil = no block running.
    @Published var blockStartedAt: Date?
    @Published var breakUntil: Date?
    var autoDialBeforeBreak = true
    /// Voicemail and follow-ups written ahead of time for the next person, by record Id (15 characters).
    var prewarmed: [String: (calling: String, voicemail: Suggestion, at: Date)] = [:]
    var prewarmingKey: String?
    var prewarmTask: Task<Void, Never>?
    /// The person whose ahead-of-time voicemail is in use (their dial doesn't wait for Claude).
    var prewarmHitFor: String?
    /// People in a row who weren't ready in time and were moved to the back (stops after 5).
    var stallSkips = 0
    /// "Sending the text in 4": seconds left before the due text goes out by itself. nil = no countdown.
    @Published var textSendIn: Int?
    var textTask: Task<Void, Never>?
    /// Whose LinkedIn profile was last opened by itself, so it opens once per person.
    var linkedInOpenedFor: String?

    /// After a voicemail: the text and LinkedIn note to send. Stays after the call until checked off.
    @Published var followUp: FollowUp? { didSet { followUpChanged() } }

    /// After a call that's done (no redial): sending the text is the cue to move on.
    @Published var waitingForText = false
    var textWasDone = false

    /// Proven openers, rotated call by call, with your own scoreboard.
    let openers = OpenerBook()
    var callOpener: Opener?   // the opener used on this call
    var goalHit = false
    /// Set the moment a meeting is booked on this call: "Meeting 3 this week". Cleared on the next call.
    @Published var meetingThisWeek: Int?
    /// Goes up once per meeting booked, so the card glows exactly once.
    @Published var meetingMoments = 0
    var sawVoicemail = false
    var stagesSeen: Set<String> = []
    var screenerActive = false       // a screener is talking; wait for the real person
    var openerBeforeScreener: Suggestion?
    var firstProspectAt: Date?
    var lastWordsAt: Date?

    /// Scores every answered call and suggests script improvements over time.
    let lab = CallLab()
    /// Dials, pickups, texts, LinkedIn notes and more, counted on this Mac.
    let touchpoints = Touchpoints()
    /// Real free time from the booking calendar (Calendly or Google), for booking.
    let availability = Availability()
    /// Meeting times already offered on this call, and the next two to offer.
    var offeredTimes: Set<Date> = []
    var codeByDate: [Date: String] = [:]
    @Published var nextOffer: [Date] = []

    /// Proven openers rotate, unless this segment opens with its script's own first line.
    var openerStyle: Opener? { campaign.ownOpener ? nil : openers.current }
    /// The opener's tag on the card: "Peer name drop · 31%" (how often people kept talking after it,
    /// once it has 3 or more answered calls).
    var openerName: String? {
        guard let o = openerStyle else { return nil }
        let s = openers.scores[o.id] ?? OpenerScore()
        guard s.calls >= OpenerBook.warmUp else { return o.name }
        return "\(o.name) · \(Int((Double(s.kept) / Double(s.calls) * 100).rounded()))%"
    }

    @Published private(set) var campaign = Campaign.clarityDiscovery
    var system = CoachPrompt.system(for: .clarityDiscovery)

    func use(_ next: Campaign) {
        touchpoints.currentCampaign = next.name
        guard next != campaign else { return }
        campaign = next
        touchpoints.currentCampaign = next.name
        listDone = false
        system = CoachPrompt.system(for: next)
        if status == .ready { prepareOpener() }
    }

    let capture = CaptureEngine()
    let streams = StreamBox()
    var timer: Timer?
    var startedByHand = false
    var quietTicks = 0
    var reconnects = 0
    var useKeyterms = true // turned off if Deepgram ever rejects them

    var uncoached = ""          // prospect words not yet answered
    var seq = 0                 // newest request id; older ones are stale
    var coachTask: Task<Void, Never>?
    var shownID = 0
    var shownAt = Date.distantPast
    @Published var pending: (id: Int, suggestion: Suggestion)?
    /// The rep's words last arrived (live, even mid-sentence). The display never changes while they speak.
    var lastRepSpeechAt = Date.distantPast
    var repSpeaking: Bool { Date().timeIntervalSince(lastRepSpeechAt) < 1.5 } // a breath between sentences still counts
    /// The prospect moved on while the rep was talking: the line on screen is outdated (a new one is queued).
    @Published var lineSuperseded = false
    /// The coach's screen state (one state machine, see CoachCore).
    @Published var coachState: CoachState = .idle
    var lastProspectSpeechAt = Date.distantPast
    var prospectSpeaking: Bool { Date().timeIntervalSince(lastProspectSpeechAt) < 0.9 }
    /// What the rep has said since the line appeared (for paraphrase-friendly delivery checks).
    var repSaidSinceShown = ""
    var lineDelivered = false
    var answeredAfterDelivery = false
    /// Hold: the rep pinned the current line; nothing replaces it until they release.
    /// Questions asked, answered, interrupted, abandoned (CoachCore), from finished turns.
    var questionTracker = QuestionTracker()
    var objectionTracker = ObjectionTracker()
    @Published var holdLine = false {
        didSet { if holdLine != oldValue { CallTrace.event("manual", ["action": holdLine ? "Hold" : "Release", "line": suggestion.say]) } }
    }
    /// Approved script answers, re-read when the script changes.
    var scriptAnswersCache: (text: String, answers: ScriptAnswers)?
    var scriptAnswers: ScriptAnswers {
        let text = campaign.pastedScript
        if let c = scriptAnswersCache, c.text == text { return c.answers }
        let a = ScriptAnswers(script: text)
        scriptAnswersCache = (text, a)
        return a
    }

    /// They asked not to be called again: terminal for this call. No more drafting or sales lines.
    var doNotCall = false
    var loggedSystemHash = ""
    /// Both sides' speech as audio time ranges: turn taking vs interruption vs overlap vs backchannel.
    var timeline = SpeechTimeline()
    var supersededLogged = 0 // suggestion id whose "outdated" was already traced

    func signals() -> CoachSignals {
        let raw = timeline.now(Date().timeIntervalSinceReferenceDate)
        // Rep done? The transcriber's end-of-speech call and a sentence that isn't left hanging come
        // first; the time windows are only the fallback.
        let repTalking = RepTurn.stillTalking(wordsInTheAir: Date().timeIntervalSince(lastRepSpeechAt) < 0.35 && !repEndpointed,
                                              endpointed: repEndpointed, lastFinal: lastRepFinal,
                                              secondsSinceFinal: Date().timeIntervalSince(lastRepFinalAt), inFallbackWindow: raw.rep)
        let repInterim = !(interim[.rep] ?? "").trimmingCharacters(in: .whitespaces).isEmpty // words on the wire (H2)
        let talk = (rep: repTalking || raw.overlap || repInterim, prospect: raw.prospect && !(repTalking && RepTurn.hangs(lastRepFinal)), overlap: raw.overlap)
        return CoachSignals(hasLine: !suggestion.say.isEmpty, prospectSpeaking: talk.prospect, repSpeaking: talk.rep,
                     secondsSinceShown: Date().timeIntervalSince(shownAt), repStarted: !repSaidSinceShown.isEmpty || !(interim[.rep] ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                     delivered: lineDelivered, prospectAnsweredSince: answeredAfterDelivery,
                     queued: pending != nil, queuedIsForNewTopic: lineSuperseded,
                     lineWords: suggestion.say.split(separator: " ").count, overlapping: talk.overlap,
                     repOnLine: Delivery.onLine(line: suggestion.say, spoken: repSaidSinceShown), doNotCall: doNotCall)
    }
    var holdTask: Task<Void, Never>?
    var timedID = 0

    // Starting early: when the prospect's sentence sounds finished, Claude starts writing before
    // the transcriber confirms they stopped. The answer is held until they really stop.
    var specBasis: String?                 // the words the early answer was started on
    var specHeld: (s: Suggestion, id: Int)?
    var specTimer: Task<Void, Never>?
    var confirmedAt: Date?

    var repWordsSinceShown = 0
    var repWordsInCall = 0

    var active = false

    /// Only the visible coach screen reacts to calls (not while the audio check runs).
    func activate(_ on: Bool) {
        active = on
        BugReporter.context = { [weak self] in self?.debugSummary() ?? "" }
        if on { onAppear() } else if status != .ready { nextCall() }
    }

    func onAppear() {
        // Redraw the coach when the call list changes (it lives in its own object).
        if listWatcher == nil {
            listWatcher = callList.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            leadsWatcher = leads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            // A new lead loaded between calls: write its opener and voicemail.
            leadDetailsWatcher = leads.$details.sink { [weak self] details in
                guard let details else { return }
                Task { @MainActor in
                    guard let self, self.status == .ready, details.id != self.appliedLeadID else { return }
                    // Not a US or Canada number: skip right away, before anyone can press Call.
                    if !details.doNotCall, let n = details.foreignNumber, !self.dialing {
                        ActivityLog.add("\(details.name) isn't a US or Canada number (\(n)): skipping and removing from the list")
                        RemovedList.add(details.id)
                        self.problem = "Not a US or Canada number. Skipped, on to the next person."
                        self.nextLead(dial: Prefs.autoDial)
                        return
                    }
                    self.applyLead()
                }
            }
            Task { await leads.start() }
        }
        if suggestion.say.isEmpty, !thinking { prepareOpener() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Call lifecycle

    /// Points the coach at the record open in Chrome right now: name, opener, voicemail,
    /// follow-ups and status all for that one person. Called every second between calls,
    /// and always right before dialing, so nothing from the last person carries over.
    var lastSyncedKey: String?

    var autoHangingUp = false
    var autoHungUpThisCall = false
    /// The app hung up a 1st-try recording: redial after 1 second instead of 3.
    var redialRightAway = false

    // MARK: Auto next

    /// Seconds left before the app moves to the next lead by itself. Nil = not counting.
    @Published var autoNextIn: Int?
    var autoNextTask: Task<Void, Never>?

    /// Who's next, for the countdown banner.
    var nextLeadName: String? {
        if leads.isActive { return leads.nextRow?.name }
        if case .ready(let name, _, _) = callList.state { return name }
        return nil
    }

    var endedAt = Date.distantPast

    /// After a call ends while Chrome still holds the mic, don't treat that as a new call.
    var waitingForNewCall = false
    var callStartedAt = Date.distantPast
    var heardCallAudio = false
    var retargets = 0

    // Aircall says when the call is over. Asked every 2 seconds during a call; two "no call"
    // answers in a row end it (so one slow answer can't end a live call).
    var aircallTicks = 0
    var aircallSaysOver = 0
    var aircallSawCall = false
    var aircallCheck: Task<Void, Never>?

    var hangUpGen = 0

    // MARK: Audio and transcription

    var directAudio = false
    var directCheck: Task<Void, Never>?

    var pendingStop: Task<Void, Never>?
    var lastVoicemailError: String?
    var lastVoicemailTry = Date.distantPast
    var instantOpenerID = -1
    /// Why a call didn't start. Shown right above the Call button and never wiped by a new line.
    @Published var callMessage: String?
    /// Everyone due today on this list has been called: time to switch to the next list.
    @Published var listDone = false
    /// Calling someone the plan skips today takes a 2nd click on Call within 15 seconds.
    var callAnywayID: String?
    var callAnywayUntil = Date.distantPast

    /// Who the countdown is for.
    @Published var autoNextName: String?
    /// "Getting Burcin's script ready..." while the app waits to dial.
    @Published var gettingReady: String?
    /// What the Call button is waiting for, in a sentence (shown above the buttons).
    @Published var gettingReadyDetail: String?
    var readyTask: Task<Void, Never>?
    /// The record Next just opened, until its page is showing.
    var openingID: String?
    var openingSince = Date.distantPast

    /// Everything the prospect side has said this call (finished words only).
    var prospectSoFar: String {
        turns.filter { $0.speaker == .prospect }.map(\.text).joined(separator: " ")
    }

    /// After the rep asks a question: 6 s of silence shows "Still with me?".
    var stillWithMeTask: Task<Void, Never>?

    /// The carrier says the number doesn't work: show it, and skip voicemail and follow-ups.
    var badNumberThisCall = false
    var phoneTreeThisCall = false

    /// In a phone menu right now (until a person answers or a mailbox beep is coming).
    var phoneTreeActive = false
    var phoneTreeTask: Task<Void, Never>?

    /// The rep clicked "Press 3": sends those keys into the call (the in-app Aircall phone only).
    @Published var keysMessage: String?
    var followUpThisCall = false
    var followUpWatchdog: Task<Void, Never>?

    /// The company line from the Salesforce page, if it shows one (helps LinkedIn find the right person).
    var recordCompany: String? {
        guard let lines = recordDetails?.components(separatedBy: "\n") else { return nil }
        for (i, line) in lines.enumerated() where ["Company", "Account Name"].contains(line.trimmingCharacters(in: .whitespaces)) {
            if i + 1 < lines.count { return lines[i + 1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: Claude

    /// Everything the rep wrote in the campaign: each section, then the pasted script.
    var campaignText: String {
        (Campaign.sections.map { campaign[keyPath: $0.key] } + [campaign.pastedScript]).joined(separator: "\n\n")
    }

    /// "Clarity" from the campaign's company description.
    var shortCompany: String {
        let c = campaign.company
        if c.localizedCaseInsensitiveContains("Clarity") { return "Clarity" }
        let first = c.components(separatedBy: CharacterSet(charactersIn: ",.;:")).first ?? ""
        let words = first.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? "Clarity" : words
    }

}
```

## `mac/Sources/ClarityLiveCoach/CoachTypes.swift`

```swift
import CoachCore
import Foundation

// MARK: - What Claude sends back

struct Suggestion: Equatable {
    var say = ""
    var cue = ""
    var stage = ""
    var skip = false
    /// True once the SAY line is fully written (a line break came after it, or the answer ended).
    var sayComplete = false
    /// Codes of the meeting times this line offers or confirms, e.g. ["T3", "T5"].
    var offered: [String] = []
    /// The move Claude picked before writing the line (answer, clarify, discover...).
    var move = ""
    /// Voicemail follow-ups: a text to send and a LinkedIn connection note.
    var textMessage = ""
    var linkedin = ""
    var linkedinMessage = ""
    /// Phone tree: the keys to press now (0-9, * and #), for the one-click button.
    var keys = ""
    /// A nudge from the app ("Still with me?"), not a script line: shown softer.
    var nudge = false

    /// The script row this line came from, when the cue starts with one: "[S5 manual 2] ..." -> "S5 manual 2".
    var rowTag: String? {
        guard cue.hasPrefix("["), let close = cue.firstIndex(of: "]") else { return nil }
        let tag = cue[cue.index(after: cue.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        return tag.isEmpty || tag.count > 24 ? nil : tag
    }

    /// The cue without the row tag in front.
    var cueText: String {
        guard rowTag != nil, let close = cue.firstIndex(of: "]") else { return cue }
        return cue[cue.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    /// Claude answers in a tiny line format so words can show while they stream:
    ///   SAY: ...
    ///   CUE: ...
    ///   STAGE: ...
    ///   OFFERED: T3, T5   (only when the line offers meeting times)
    /// or SKIP when the rep needs no help.
    static func parse(_ text: String) -> Suggestion {
        var s = Suggestion()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let m = Move.parse(trimmed) {
                s.move = m.rawValue
                if m == .silent { s.skip = true } // the rep doesn't need a new line
                continue
            }
            if trimmed.hasPrefix("SAY:") {
                s.say = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !s.say.isEmpty { s.sayComplete = true } // any line after SAY means SAY is done
            if trimmed.hasPrefix("CUE:") { s.cue = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("STAGE:") { s.stage = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("SKIP") { s.skip = true }
            else if trimmed.hasPrefix("TEXT:") { s.textMessage = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("KEYS:") {
                s.keys = String(trimmed.dropFirst(5).filter { "0123456789*#".contains($0) }.prefix(12))
            }
            else if trimmed.hasPrefix("LINKEDIN MESSAGE:") { s.linkedinMessage = String(trimmed.dropFirst(17)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("LINKEDIN:") { s.linkedin = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("OFFERED:") {
                s.offered = trimmed.dropFirst(8).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            }
        }
        return s
    }
}

// MARK: - Voicemail follow-ups

struct FollowUp: Equatable {
    /// Which record this is for, so a 2nd-try voicemail keeps what the 1st try already sent.
    var key: String?
    var prospect: String?
    var text = ""
    /// The rep typed in the text box: never overwrite their words with a fresh draft.
    var textEdited = false
    var linkedin = ""
    var textDone = false
    var linkedinDone = false
    /// Their phone, from the Salesforce page; editable on the card.
    var phone = ""
    /// Their LinkedIn profile, from the Salesforce record's LinkedIn field.
    var linkedinURL: URL?
    /// A note for the text row ("Sending...", an error). nil once sent.
    var textStatus: String?
    /// The text is on its way: the Send button waits.
    var sending = false
    /// A LinkedIn direct message, for people who are already connected.
    var linkedinMessage = ""
    var linkedinMessageDone = false
    /// What the 21-day plan says to send today.
    var textDue = false
    var linkedInDue = false
    var linkedInMessageFirst = false // the last call day: a message, not a connection note
    /// Salesforce has no Mobile for them (only an office Phone): no text, ever.
    var noMobile = false

    /// Everything due today is done.
    /// Connect day: both the note and the message. Last call day: the message.
    var allDone: Bool {
        (textDone || !textDue)
            && (!linkedInDue || (linkedInMessageFirst ? linkedinMessageDone : linkedinDone && linkedinMessageDone))
    }
}

// MARK: - The person on screen

/// Everything the coach knows about the person on screen. Async work (page text, voicemail,
/// opener) checks it's still for them before writing here.
struct Prospect: Equatable {
    /// From the Salesforce tab title, e.g. Lead "Jane Doe".
    var calling: String?
    /// Text from their Salesforce page, when Chrome allows it.
    var details: String?
    /// Their page was read (or tried).
    var detailsTried = false
    /// Their page is still loading: read it once it shows.
    var detailsPending = false
    /// Who Claude's personal opener on screen is for.
    var personalOpenerFor: String?
    /// Their voicemail, written ahead of time, and who it was written for.
    var voicemail: Suggestion?
    var voicemailFor: String?
    /// The record Id the voicemail is for (matches the follow-up card's key).
    var voicemailKey: String?
    /// The voicemail was written from their Salesforce page.
    var voicemailUsedDetails = false
}

// MARK: - Call state

enum Speaker { case rep, prospect }

struct Turn: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    var text: String
}

/// Short noises that never need a new line on their own.
private let filler: Set<String> = [
    "yeah", "yep", "yes", "ok", "okay", "uh", "um", "uh-huh", "mhm", "mm-hmm", "hmm",
    "right", "sure", "got", "it", "cool", "nice", "great", "hello", "hi",
]

/// Lowercase words only, so "Sure, go ahead." matches "sure go ahead".
func normalized(_ text: String) -> String {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func isMeaningful(_ text: String) -> Bool {
    text.lowercased()
        .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
        .contains { !$0.isEmpty && !filler.contains($0) }
}

/// Holds the two transcription streams so audio threads can reach them safely.
final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rep: DeepgramStream?
    private var prospect: DeepgramStream?

    func set(rep: DeepgramStream?, prospect: DeepgramStream?) {
        lock.withLockValue { self.rep = rep; self.prospect = prospect }
    }

    func replace(_ speaker: Speaker, with stream: DeepgramStream?) {
        let old = lock.withLockValue { () -> DeepgramStream? in
            defer { if speaker == .rep { rep = stream } else { prospect = stream } }
            return speaker == .rep ? rep : prospect
        }
        old?.close()
    }

    func send(_ data: Data, isRep: Bool) {
        let stream = lock.withLockValue { isRep ? rep : prospect }
        stream?.send(data)
        if !isRep { BeepDetector.shared.feed(data); VoicemailSamples.shared.feed(data) } // the beep, and greeting samples
        AudioDebug.shared.feed(data, isRep: isRep)
    }

    func closeAll() {
        let (r, p) = lock.withLockValue { (rep, prospect) }
        r?.close()
        p?.close()
        set(rep: nil, prospect: nil)
    }
}

// MARK: - The coach

/// What's been said on this call, plus the words still coming in. Changes many times a second.
@MainActor
final class LiveTranscript: ObservableObject {
    @Published var turns: [Turn] = []
    @Published var interim: [Speaker: String] = [:]
}
```

## `mac/Sources/ClarityLiveCoach/CoachModel+Audio.swift`

```swift
import AppKit
import CoachCore
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Listening: audio capture, the two transcription streams, and what each word means.
extension CoachModel {
    func startAudio() -> Bool {
        pendingStop?.cancel() // a new call: keep the old tap from being removed later
        pendingStop = nil
        guard let deepgramKey = Keychain.read(.deepgram) else {
            problem = "Add your Deepgram key: gear > Setup > AI keys."
            return false
        }
        streams.set(rep: openStream(.rep, key: deepgramKey), prospect: openStream(.prospect, key: deepgramKey))

        // The Aircall phone inside the coach hands over the call audio itself: no Core Audio tap,
        // so nothing glitches (like the hang-up tone). If it doesn't within 4 s, use the tap.
        if AircallPhone.isOn {
            let streams = self.streams
            let phone = AircallPhone.shared
            phone.onAudio = { isRep, pcm in streams.send(pcm, isRep: isRep) }
            directAudio = true
            ActivityLog.add("Listening straight from the Aircall phone")
            let startedAt = Date()
            directCheck?.cancel()
            directCheck = Task { [weak self] in
                // Check at 4 s and again at 8 s: the other side must have real sound by then
                // (ringback or a voicemail greeting), or the phone isn't sharing the call: use the tap.
                for checkAt in [4.0, 8.0] {
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
                    if phone.lastRemoteAudio > startedAt { break }
                    if checkAt < 8 { continue }
                    phone.onAudio = nil
                    self.directAudio = false
                    ActivityLog.problem("No sound from the Aircall phone after 8 s; using the audio tap")
                    if !self.startTap() { self.stopAudio() }
                    return
                }
                guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
                if phone.lastLocalAudio < startedAt {
                    // The other side comes through, the rep's mic doesn't: add the Mac's mic.
                    phone.onAudio = { isRep, pcm in if !isRep { streams.send(pcm, isRep: false) } }
                    do {
                        try self.capture.startMicOnly { isRep, speech in
                            guard let samples = speech.int16ChannelData?[0] else { return }
                            streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: true)
                        }
                        ActivityLog.add("Rep's side: Mac mic (the phone didn't share it)")
                    } catch {
                        ActivityLog.problem("Mic failed: \(error.localizedDescription)")
                    }
                } else {
                    ActivityLog.add("Hearing both sides straight from the Aircall phone")
                }
            }
            return true
        }
        return startTap()
    }

    /// The old way: a Core Audio tap on the call app's sound, plus the mic.
    func startTap() -> Bool {
        let chrome = AudioProcess.callAudioTargets(in: AudioProcess.others())
        guard !chrome.isEmpty else {
            callMessage = "Can't hear the call yet. Open the Aircall app (or Aircall in Chrome) and start the call."
            ActivityLog.problem("Listening failed: no Aircall or Chrome audio found")
            return false
        }
        do {
            let streams = self.streams
            try capture.start(processes: chrome) { isRep, speech in
                guard let samples = speech.int16ChannelData?[0] else { return }
                streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: isRep)
            }
            ActivityLog.add("Listening to: \(Self.names(of: chrome))")
            return true
        } catch {
            streams.closeAll()
            callMessage = "The coach couldn't start listening: \(error.localizedDescription). The call still works; coaching is off for it."
            ActivityLog.problem("Listening failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Process names for the log.
    static func names(of ids: [AudioObjectID]) -> String {
        let all = AudioProcess.others()
        let names = ids.compactMap { id in all.first { $0.id == id }?.name }
        return names.isEmpty ? "\(ids.count) process(es)" : Set(names).sorted().joined(separator: ", ")
    }

    /// Listening starts a second after dialing, sometimes before Aircall's call audio exists.
    /// Once Aircall is clearly on the call, make sure that's what the app listens to.
    func followCallAudio() {
        guard !directAudio else { return } // the phone hands over its audio itself
        let processes = AudioProcess.others()
        guard AudioProcess.aircallAppOnCall(in: processes) || AudioProcess.chromeOnCall(in: processes) else { return }
        let targets = AudioProcess.callAudioTargets(in: processes)
        // Only add missing call audio (never drop what's working), and at most twice a call.
        guard retargets < 2, !targets.isEmpty, !Set(targets).isSubset(of: Set(capture.tapTargets)) else { return }
        retargets += 1
        do {
            try capture.retargetTap(processes: targets)
            ActivityLog.add("Switched listening to: \(Self.names(of: targets))")
        } catch {
            ActivityLog.add("Couldn't switch listening: \(error.localizedDescription)")
        }
    }

    /// Stops listening. Transcription stops right away, but the audio tap is removed a few
    /// seconds later: tearing it down while Aircall plays the hang-up tone makes that tone
    /// stutter and repeat.
    func stopAudio() {
        AircallPhone.shared.onAudio = nil
        directCheck?.cancel()
        directAudio = false
        streams.closeAll()
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.pendingStop = nil
            self.capture.stop()
        }
    }

    /// One line about what the app is doing, for bug reports.
    func debugSummary() -> String {
        "status=\(status) person=\(calling ?? "none") page=\(SalesforceTab.currentRecord() ?? "none") " +
        "waitingFor=\(gettingReady == nil ? "-" : waitingFor()) voicemailFor=\(voicemailFor ?? "none") " +
        "followUp=\(followUp?.prospect ?? "none") autoDial=\(autoDial) attempts=\(currentAttempts) " +
        "salesforce=\(Salesforce.isConnected) aircall=\(Aircall.canPlaceCalls)"
    }

    func openStream(_ speaker: Speaker, key: String) -> DeepgramStream {
        final class Ref: @unchecked Sendable { weak var stream: DeepgramStream? }
        let ref = Ref()
        let stream = DeepgramStream(apiKey: key, keyterms: useKeyterms ? DeepgramStream.defaultKeyterms : []) { [weak self] event in
            // When the words were spoken, on the wall clock both sides share (not when the text arrived).
            var spoken: (start: Date, end: Date)?
            if case .transcript(_, _, _, let start, let duration, _) = event, start > 0 || duration > 0,
               let s = ref.stream?.wallTime(audioSeconds: start) {
                spoken = (s, s.addingTimeInterval(duration))
            }
            Task { @MainActor in self?.handle(event, from: speaker, spoken: spoken) }
        }
        ref.stream = stream
        return stream
    }

    func handle(_ event: DeepgramStream.Event, from speaker: Speaker, spoken: (start: Date, end: Date)? = nil) {
        guard status == .live else { return }
        switch event {
        case .transcript(let text, let isFinal, let speechFinal, let audioStart, let audioDuration, let confidence):
            if !text.isEmpty {
                CallTrace.event(isFinal ? "transcript.final" : "transcript.partial", [
                    "speaker": speaker == .rep ? "rep" : "prospect", "text": text, "speech_final": speechFinal,
                    "audio_start": audioStart, "audio_end": audioStart + audioDuration, "confidence": confidence])
            }
            if speechFinal { CallTrace.event("turn.end", ["speaker": speaker == .rep ? "rep" : "prospect", "by": "speech_final"]) }
            if speaker == .prospect {
                // Check the recent words together, so a phrase split across chunks still matches.
                let recent = String(((turns.last { $0.speaker == .prospect }?.text ?? "") + " " + text).suffix(400))
                let early = repWordsInCall < 3 && Date().timeIntervalSince(firstProspectAt ?? Date()) < 15
                let firstWords = turns.contains { $0.speaker == .rep } ? "" : (prospectSoFar + " " + text)
                if BadNumber.detects(recent) {
                    if !badNumberThisCall { markBadNumber() }
                } else if phoneTreeActive {
                    // In a phone menu: no voicemail card, no auto hang-up. Only a real mailbox ends it.
                    if Voicemail.recordingPrompt(recent) {
                        phoneTreeActive = false
                        phoneTreeTask?.cancel()
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                } else if !badNumberThisCall, !phoneTreeThisCall, repWordsInCall < 5,
                          !Voicemail.recordingPrompt(recent), PhoneTree.detects(prospectSoFar + " " + text) {
                    // Work through it by default. Old behavior (disqualify + hang up) behind a setting.
                    if Prefs.hangUpPhoneTrees { markPhoneTree() } else { enterPhoneTree() }
                } else if !voicemailActive, screenerActive || stagesSeen.contains("Screener") || Screener.detects(prospectSoFar),
                          Voicemail.unavailableAfterScreen(recent) || Voicemail.numberCantTakeCall(recent) {
                    // The call screener says they won't take it: same as no answer. Hang up (redial on the
                    // 1st try, next person on a no-voicemail day). A voicemail day's last try waits for the beep.
                    ActivityLog.add("Screener said not available for \(calling ?? "?")")
                    showVoicemail(mailboxFull: false)
                    autoHangUpForRedial(why: "screener said not available")
                } else if Voicemail.detects(recent, earlyInCall: early)
                    || (!screenerActive && !Screener.detects(firstWords) && Voicemail.longGreeting(firstWords, earlyInCall: early)) {
                    if !voicemailActive || (Voicemail.mailboxFull(recent) && !mailboxFullShown) {
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                    // Surely a recording, and the rep hasn't started talking: hang up now, before the beep
                    // (redial on the 1st try; on to the next person on a no-voicemail day's last try).
                    if repWordsInCall < 3, !screenerActive, !autoHungUpThisCall,
                       let why = Voicemail.hangUpReason(recent, firstWords: firstWords, earlyInCall: early) {
                        autoHangUpForRedial(why: why)
                    }
                } else if !voicemailActive, !screenerActive, !stagesSeen.contains("Screener"), Screener.detects(recent) {
                    showScreenerLine()
                }
            }
            if !text.isEmpty {
                let wasSpeaking = speaker == .rep ? repSpeaking : prospectSpeaking
                if !wasSpeaking {
                    ActivityLog.add("Speech start (\(speaker == .rep ? "Rep" : "Them"), transcript arrival)")
                    CallTrace.event("speech.start", ["speaker": speaker == .rep ? "rep" : "prospect",
                                                     "overlap": speaker == .rep ? prospectSpeaking : repSpeaking])
                }
                if speaker == .rep { lastRepSpeechAt = Date(); repEndpointed = false } else { lastProspectSpeechAt = Date() }
                // Audio timeline: classify the turn from when words were spoken. No timestamps (rare):
                // fall back to arrival time, a short range ending now.
                let side: SpeechTimeline.Side = speaker == .rep ? .rep : .prospect
                let end = spoken?.end ?? Date()
                let start = spoken?.start ?? end.addingTimeInterval(-0.3)
                if let kind = timeline.update(side, start: start.timeIntervalSinceReferenceDate, end: end.timeIntervalSinceReferenceDate,
                                              text: text, isFinal: isFinal) {
                    CallTrace.event("turn.classified", ["speaker": side.rawValue, "kind": kind.rawValue, "text": text,
                                                        "spoken_start_ms": Int(start.timeIntervalSince1970 * 1000),
                                                        "spoken_end_ms": Int(end.timeIntervalSince1970 * 1000),
                                                        "lag_ms": Int(Date().timeIntervalSince(end) * 1000),
                                                        "timestamps": spoken == nil ? "arrival (fallback)" : "audio",
                                                        "final": isFinal])
                }
            }
            if isFinal {
                reconnects = 0
                interim[speaker] = nil
                if !text.isEmpty { addFinal(text, from: speaker) }
                // Opt-out on any prospect final, even one that doesn't end their turn (C7).
                // Clear opt-out phrases on any final, checked on the whole turn so far, not one chunk (round 3).
                if speaker == .prospect, !doNotCall, LiveCoach.isOptOut(uncoached + " " + text, isFinal: false) { handleOptOut(uncoached + " " + text) }
                if speechFinal && speaker == .prospect { prospectFinished() }
                if !speechFinal && speaker == .prospect { scheduleEarlyStart() } // a final mid-turn is a head start too (M2)
                if speechFinal && speaker == .rep { repEndpointed = true; promotePendingIfReady() } // the transcriber heard them stop (M1)
            } else {
                interim[speaker] = text
                if speaker == .prospect { scheduleEarlyStart() }
            }
        case .utteranceEnd:
            CallTrace.event("turn.end", ["speaker": speaker == .rep ? "rep" : "prospect", "by": "utterance_end"])
            if speaker == .prospect {
                // The full pause after "don't call me back": now decide if it was an opt-out or a callback request.
                if let said = pendingAmbiguousOptOut {
                    pendingAmbiguousOptOut = nil
                    let whole = (said + " " + uncoached).trimmingCharacters(in: .whitespaces)
                    if !doNotCall, LiveCoach.isOptOut(whole, isFinal: true) { handleOptOut(whole) }
                    else { uncoached = whole; CallTrace.event("optout.not", ["said": whole, "why": "a later time followed: a callback request"]) }
                }
                if !doNotCall { prospectFinished() }
            }
            if speaker == .rep { repEndpointed = true; promotePendingIfReady() } // M1: no wait for the next tick
        case .failed(let message):
            // Keep the call and the last tip; just reconnect this side.
            guard reconnects < 3, let key = Keychain.read(.deepgram) else {
                problem = "Transcription stopped: \(message)"
                return
            }
            reconnects += 1
            useKeyterms = false // reconnect with the plainest settings
            streams.replace(speaker, with: openStream(speaker, key: key))
        }
    }

    /// The rep clicked "Voicemail": the app missed it, so show the message now.
    func markVoicemail() {
        guard status == .live, !voicemailActive else { return }
        showVoicemail(mailboxFull: false)
    }

    func addFinal(_ text: String, from speaker: Speaker) {
        lastWordsAt = Date()
        defer { scheduleStillWithMe() }
        defer { if speaker == .rep { prepareWhileRepTalks(text); prepareYesBranch(text) } } // runs after the turn is recorded
        if speaker == .rep {
            let count = text.split(separator: " ").count
            repWordsSinceShown += count
            repWordsInCall += count
            lastRepFinal = text
            lastRepFinalAt = Date()
            recentRepChunks = Array((recentRepChunks + [text]).suffix(2))
        }
        if speaker == .prospect, firstProspectAt == nil { firstProspectAt = Date() }
        ActivityLog.add("Heard \(speaker == .rep ? "Rep" : "Them") (final): \(text)")
        if speaker == .rep, pending != nil, text.contains("?") { repAskedSinceQueue = true }
        if speaker == .rep, text.contains("?") || QueuedLine.repPivoted(text) { lastRepQuestionAt = Date() }
        if speaker == .rep { repTextSinceAsk += " " + text }
        if speaker == .rep, status == .live, !suggestion.say.isEmpty {
            repSaidSinceShown += " " + text
            if !lineDelivered, Delivery.delivered(line: suggestion.say, spoken: repSaidSinceShown) {
                lineDelivered = true
                let conf = Delivery.confidence(line: suggestion.say, spoken: repSaidSinceShown)
                ActivityLog.add(String(format: "Coach: line delivered (meaning %.0f%% said)", conf * 100))
                let ev = Delivery.evidence(line: suggestion.say, spoken: repSaidSinceShown)
                CoachPrompt.saidLines.append(suggestion.say)
                if !suggestion.stage.isEmpty { CoachPrompt.lastSaidStage = suggestion.stage }
                CallTrace.event("delivery", ["line": suggestion.say, "said": repSaidSinceShown, "confidence": conf,
                                             "rule": Delivery.rule(line: suggestion.say, spoken: repSaidSinceShown) ?? "none",
                                             "matched_words": ev.matched, "missing_words": ev.missing,
                                             "how": "overall: half the line's key words said; question: 60% of its question's key words"], sug: shownID)
            }
        }
        // Resolved only by a real answer: "Why?" or "What do you mean?" after the line isn't one (N1).
        if speaker == .prospect, lineDelivered, !answeredAfterDelivery, AnswerEvidence.isAnswer(text) {
            answeredAfterDelivery = true
            ActivityLog.add("Coach: they answered the delivered line (resolved)")
            CallTrace.event("resolution", ["answer": text, "how": "prospect spoke after the line was delivered"], sug: shownID)
        }
        if speaker == .prospect { lastHeardThemAt = Date(); confirmGoalIfAgreed(text) }
        if turns.last?.speaker != speaker { CallTrace.turn += 1 }
        // Cut off = this side really came in over the other in audio time (not just answered quickly).
        let kindNow = timeline.segments[speaker == .rep ? .rep : .prospect]?.last?.kind
        let overlapped = kindNow == .interruption || kindNow == .overlap
        for change in questionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, overlapped: overlapped) {
            switch change {
            case .asked(let q): CallTrace.event("question.asked", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
            case .answered(let q): CallTrace.event("question.answered", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "answer": q.answer])
            case .interrupted(let q): CallTrace.event("question.interrupted", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "cut_off_by": text])
            case .abandoned(let q): CallTrace.event("question.abandoned", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
            case .uncertain(let q): CallTrace.event("question.uncertain", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "reply": q.answer,
                                                                           "reply_kind": AnswerEvidence.kind(q.answer).rawValue])
            }
        }
        CoachPrompt.questionFacts = questionTracker.promptText // current before the next prompt is built
        for c in objectionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, turn: CallTrace.turn) {
            let o = c.objection
            CallTrace.event("objection.\(o.status.rawValue)", [
                "id": o.id, "kind": o.kind, "from": c.from?.rawValue ?? "none", "to": o.status.rawValue, "why": c.why,
                "raised": ["turn": o.raisedTurn, "text": o.raisedText],
                "addressed": ["turn": o.addressedTurn, "text": o.addressedText],
                "evidence": ["turn": o.evidenceTurn, "text": o.evidenceText]])
            ActivityLog.add("Objection \(o.kind): \(c.from?.rawValue ?? "new") -> \(o.status.rawValue)")
        }
        CoachPrompt.objectionFacts = objectionTracker.promptText
        if let last = turns.last, last.speaker == speaker {
            turns[turns.count - 1].text += " " + text
        } else {
            turns.append(Turn(speaker: speaker, text: text))
        }
        if speaker == .prospect {
            uncoached += (uncoached.isEmpty ? "" : " ") + text
        }
    }
}
```

## `mac/Sources/ClarityLiveCoach/CoachModel+Lines.swift`

```swift
import AppKit
import CoachCore
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// The coaching line on screen: asking Claude, holding a line until the rep has read it, history and journey.
extension CoachModel {
    func trackJourney(_ stage: String) {
        let step: Int?
        switch stage {
        case "Opener", "Screener", "Gatekeeper", "Voicemail": step = 0
        case "Discovery": step = 1
        case "Value": step = 2
        case "Closing", "Goal reached": step = 3
        default: step = nil // Objection, Exit: stay where we are
        }
        if let step, step > journeyStep { journeyStep = step }
    }

    /// Shows the line before the one on screen.
    func back() {
        let current = historyIndex ?? history.count - 1
        guard current > 0 else { return }
        historyIndex = current - 1
        suggestion = history[current - 1].s
        kind = history[current - 1].kind
    }

    /// Back to the newest line after looking back.
    func showLatest() {
        guard let latest = history.last else { return }
        historyIndex = nil
        suggestion = latest.s
        kind = latest.kind
    }

    /// Asks for the line that moves the call to the next step.
    func advanceStep() {
        guard let next = nextStepName else { newLine(); return }
        newLine(extra: "Move the call forward to the next step: \(next). Write the line that starts it now.")
    }

    /// The meeting times Claude may offer, with stable codes for this call, and which two to offer next.
    func bookingText() -> String? {
        let slots = availability.offerSlots()
        guard !slots.isEmpty else { return nil }
        for slot in slots where codeByDate[slot] == nil {
            codeByDate[slot] = "T\(codeByDate.count + 1)"
        }
        let next = pickNextPair(from: slots)
        nextOffer = next
        let list = slots.map { slot in
            "\(codeByDate[slot]!): \(availability.label(slot))" + (offeredTimes.contains(slot) ? " (already offered)" : "")
        }.joined(separator: "\n")
        let nextCodes = next.compactMap { codeByDate[$0] }.joined(separator: " or ")
        return """
        Meeting times open on the host's calendar (exact start times, \(availability.zoneName) time). Offer only these:
        \(list)
        When asking for the meeting, offer exactly these two next: \(nextCodes). Say them naturally, like "Tuesday at 10 or Wednesday at 2:30".
        If they turn times down, the next message gives you new ones; never re-offer a time marked already offered.
        If the prospect names a time, check the list. If it's there, confirm it. If not, offer the closest listed time.
        Whenever your SAY offers or confirms specific times, add a last line: OFFERED: <their codes, comma separated>.
        """
    }

    /// Two not-yet-offered times: the soonest, plus one on another day (or at least 3 hours apart).
    func pickNextPair(from slots: [Date]) -> [Date] {
        let fresh = slots.filter { !offeredTimes.contains($0) }
        guard let first = fresh.first else { return [] }
        let cal = Calendar.current
        let second = fresh.dropFirst().first { !cal.isDate($0, inSameDayAs: first) }
            ?? fresh.dropFirst().first { $0.timeIntervalSince(first) >= 3 * 3600 }
            ?? fresh.dropFirst().first
        return [first] + (second.map { [$0] } ?? [])
    }

    /// The rep asked for a different line right now. Skips the wait and the hold.
    func newLine(extra: String = "The rep asked for a different line than the last one.") {
        CallTrace.event("manual", ["action": "Different line", "was": suggestion.say])
        guard status == .live, !voicemailActive else { return }
        let latest = uncoached.trimmed.isEmpty ? (turns.last { $0.speaker == .prospect }?.text ?? "") : uncoached.trimmed
        uncoached = ""
        shownAt = .distantPast // no hold for a line the rep asked for
        repWordsSinceShown = 99
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: latest, calling: calling, details: recordDetails, style: callOpener,
            openTimes: bookingText()
        ) + "\n" + extra)
    }

    /// The rep clicked "Other times": count the current pair as turned down.
    func skipOfferedTimes() {
        offeredTimes.formUnion(nextOffer)
        nextOffer = pickNextPair(from: availability.offerSlots())
    }

    /// Instant line for a call screener. No Claude call, no waiting.
    func showScreenerLine() {
        // Never over the rep mid-sentence (C6): wait up to 3 s for them to stop.
        if signals().repSpeaking || !(interim[.rep] ?? "").isEmpty {
            screenerWait?.cancel()
            screenerWait = Task { [weak self] in
                for _ in 0..<33 { // up to about 10 s
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, !Task.isCancelled else { return }
                    var sig = self.signals(); sig.queuedIsForNewTopic = true
                    if !sig.repSpeaking && (self.interim[.rep] ?? "").isEmpty && CoachMachine.canReplace(sig) { self.showScreenerLineNow(); return }
                }
                // Still talking after 10 s: they're handling the screener themselves. Don't interrupt.
                CallTrace.event("suggestion.dropped", ["line": "screener", "why": "the rep kept talking"])
            }
            return
        }
        showScreenerLineNow()
    }

    private func showScreenerLineNow() {
        guard status == .live, !doNotCall else { return }
        screenerActive = true
        coachTask?.cancel()
        thinking = false
        holdTask?.cancel()
        pending = nil
        if kind == .opener { openerBeforeScreener = suggestion }
        seq += 1
        show(Suggestion(say: Screener.line(calling: calling),
                        cue: "Call screener. Say it slowly and clearly, then wait.",
                        stage: "Screener"),
             id: seq, kind: .screener)
    }

    /// If the prospect's words end like a finished sentence and hold still for a moment,
    /// start Claude now instead of waiting for the end-of-speech signal.
    func scheduleEarlyStart() {
        specTimer?.cancel()
        guard status == .live, !screenerActive, !voicemailActive, !doNotCall else { return } // prepare even while a line is up
        let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
        // "Don't call me back" mid-sentence: stop selling now, don't wait for them to finish.
        if LiveCoach.isOptOut(text, isFinal: false) { handleOptOut(text); return }
        guard isMeaningful(text) else { return }
        // Known objection mid-sentence: the approved answer is ready the moment they stop.
        if scriptAnswers.match(text) != nil {
            specTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                _ = self.instantAnswer(text)
            }
            return
        }
        // Draft early once their meaning is clear: a finished sentence (200 ms), or 6+ words that
        // stopped changing (450 ms). Each new word cancels the wait, so there's no flood of requests.
        // A yes to the rep's question, with the yes line already written: no draft needed.
        if yesBranch != nil, ProspectReply.kind(text) == .yes { return } // ready or still being written
        // One or two word fragments ("No.") almost always grow: drafting on them wastes a request.
        guard let wait = EarlyStart.delayMS(for: text),
              EarlyStart.shouldRedraft(previous: lastEarlyBasis, text: text, draftsThisTurn: earlyDraftsThisTurn) else { return }
        specTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard let self, !Task.isCancelled, !self.doNotCall,
                  EarlyStart.shouldRedraft(previous: self.lastEarlyBasis, text: text, draftsThisTurn: self.earlyDraftsThisTurn),
                  (self.uncoached + " " + (self.interim[.prospect] ?? "")).trimmed == text,
                  normalized(text) != self.specBasis else { return }
            self.ask(.reply, user: CoachPrompt.reply(
                turns: self.turns, latest: text, calling: self.calling, details: self.recordDetails, style: self.callOpener,
                openTimes: self.bookingText(), speculative: true
            ), early: text)
            self.lastEarlyBasis = text
            self.earlyDraftsThisTurn += 1
        }
    }

    /// The prospect stopped talking. Decide if the rep needs a new line.
    func prospectFinished() {
        specTimer?.cancel()
        lastEarlyBasis = nil
        earlyDraftsThisTurn = 0
        let said = uncoached.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        if doNotCall {
            uncoached = ""
            CallTrace.event("coach.suppressed", ["said": said, "why": "do not call: no more sales lines this call"])
            return
        }
        if status == .live, LiveCoach.isOptOut(said, isFinal: false) { handleOptOut(said); return } // clear phrases
        if status == .live, OptOut.hasAmbiguous(said) {
            // "Don't call me back..." might go on ("...until Tuesday"). No sales line; decide at the full pause.
            pendingAmbiguousOptOut = said
            CallTrace.event("optout.waiting", ["said": said, "why": "might be a callback request; waiting for the full pause"])
            uncoached = ""
            return
        }
        if phoneTreeActive { uncoached = ""; askPhoneTree(); return } // the menu goes on: re-plan the route
        if voicemailActive { uncoached = ""; return } // no coaching while a greeting plays
        // The rep asked a yes/no question and the line for "yes" is ready: a clear yes shows it now,
        // with no wait. No, unsure, or anything else gets a fresh answer from their real words.
        // Too old: the talk moved on since the question. Drop it and answer fresh.
        if yesBranch != nil, !YesBranchRule.usable(ageSinceQuestion: Date().timeIntervalSince(yesBranchAskedAt)) {
            CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "expired"])
            yesBranch = nil; yesBranchTask?.cancel()
        }
        if let yb = yesBranch, !yb.ready, ProspectReply.kind(said) == .yes {
            yesBranchWanted = said // nearly done: use it when it lands instead of starting over (H3)
            // ...but never dead air: after 1.2 s, give up on it and answer from their words.
            let waitFor = yb.question
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(YesBranchRule.maxWait))
                guard let self, self.yesBranchWanted == said, self.yesBranch?.question == waitFor else { return }
                self.yesBranchWanted = nil
                self.yesBranch = nil
                self.yesBranchTask?.cancel()
                CallTrace.event("yes_branch.discarded", ["question": waitFor, "why": "not ready within \(YesBranchRule.maxWait) s"])
                self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
                                                         details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
            }
            specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
            uncoached = ""
            latestProspect = said
            CallTrace.event("yes_branch.waiting", ["question": yb.question, "answer": said])
            return
        }
        if let yb = yesBranch {
            yesBranch = nil
            yesBranchTask?.cancel()
            let kind = ProspectReply.kind(said)
            if kind == .yes, yb.ready {
                CallTrace.event("yes_branch.used", ["question": yb.question, "answer": said, "line": yb.s.say])
                ActivityLog.add("Coach: they said yes, ready line shown with no wait")
                specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
                uncoached = ""
                latestProspect = said
                markRequestStart()
                seq += 1
                offer(yb.s, id: seq, kind: .reply, askedAt: Date())
                return
            }
            CallTrace.event("yes_branch.discarded", ["question": yb.question, "answer": said, "answer_kind": kind.rawValue,
                                                     "ready": yb.ready, "why": kind == .yes ? "not ready yet" : "their answer wasn't a clear yes"])
        }

        // Started early on exactly these words? Then the answer is already on its way.
        if let basis = specBasis {
            specBasis = nil
            if basis != normalized(said) {
                // Thrown out: stop it now, so it can't show later on any early return below (C5).
                coachTask?.cancel(); specHeld = nil; thinking = false
                CallTrace.event("early.wasted", ["basis": basis, "said": said, "why": "they kept talking after the early draft started"])
            }
            if basis == normalized(said) {
                CallTrace.event("early.used", ["basis": basis, "said": said, "why": "their final words matched the early draft"])
                uncoached = ""
                latestProspect = said
                confirmedAt = Date()
                if let held = specHeld {
                    specHeld = nil
                    offer(held.s, id: held.id, kind: .reply, askedAt: confirmedAt!)
                }
                return
            }
        }
        if screenerActive {
            uncoached = ""
            if Screener.detects(said) { return } // still the screener talking
            // A real person picked up after the screener: back to the opener.
            screenerActive = false
            latestProspect = said
            if let opener = openerBeforeScreener {
                seq += 1
                show(opener, id: seq, kind: .opener)
                return
            }
        }
        // Always prepare an answer. Whether it shows now or waits is the display controller's call
        // (CoachMachine.canReplace): the line being read is never swapped out from under the rep.
        uncoached = ""
        latestProspect = said
        // A plain "Hello?" is already answered by the opener on screen.
        let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
        // "Sure" or "Yes" is filler while the rep talks, but a real answer to the rep's question.
        let repAsked = turns.last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else {
            CallTrace.event("coach.skipped", ["said": said, "why": onlyGreeting ? "a plain greeting; the opener already answers it" : "not meaningful (filler)"])
            return
        }
        if instantAnswer(said) { return }
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: said, calling: calling, details: recordDetails, style: callOpener,
            openTimes: bookingText()
        ))
        updateSummaryIfDue()
    }

    /// Every 4 prospect turns, Haiku writes a short summary of the call in the background, so each live
    /// line only needs the last minute word for word.
    func updateSummaryIfDue() {
        let total = turns.count
        guard CallMemoryRules.summaryDue(totalTurns: total, summaryCovers: CoachPrompt.summaryCoversTurns, inFlight: summaryInFlight),
              let key = Keychain.read(.anthropic) else { return }
        let theirs = turns.filter { $0.speaker == .prospect }.count
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        let callID = CallTrace.callID // the summary belongs to this call only
        summaryInFlight = true
        Task {
            defer { if CallTrace.callID == callID { self.summaryInFlight = false } }
            var c = LiveCoach.client(key)
            c.maxTokens = 250
            var text = ""
            try? await c.stream(system: "Summarize a live sales call for a coach in 3 to 6 short bullets: who they are, their situation, any numbers, pains, objections raised, what was agreed. Only what was said. No preamble.",
                                user: transcript) { text = $0 }
            guard CallMemoryRules.acceptSummary(currentCallID: CallTrace.callID, summaryCallID: callID,
                                                summaryCovers: total, storedCovers: CoachPrompt.summaryCoversTurns) else {
                CallTrace.event("memory.rejected", ["why": "older than the stored summary, or from another call", "covers_turns": total])
                return
            }
            if !text.isEmpty {
                CoachPrompt.liveSummary = text
                CoachPrompt.summaryCoversTurns = total
                CallTrace.memVersion += 1
                CallTrace.event("memory.update", ["summary": text, "covers_turns": total, "prospect_turns": theirs, "evidence_chars": transcript.count])
            }
        }
    }

    /// "Take me off your list": the goodbye line, DoNotCall written in Salesforce, off every list, hang up. No AI.
    func handleOptOut(_ said: String) {
        guard !doNotCall else { return }
        doNotCall = true // terminal: every later draft, early start and queued line is blocked
        specTimer?.cancel()
        coachTask?.cancel()
        yesBranchTask?.cancel(); yesBranch = nil
        stillWithMeTask?.cancel()
        phoneTreeTask?.cancel()
        openerTask?.cancel()
        if let p = pending {
            CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "do not call"], sug: p.id)
        }
        pending = nil
        specHeld = nil
        specBasis = nil
        uncoached = ""
        thinking = false
        CallTrace.event("state", ["from": coachState.rawValue, "to": CoachState.doNotCall.rawValue,
                                  "why": "opt-out phrase", "said": said, "cancelled_request": seq])
        coachState = .doNotCall
        seq += 1
        show(Suggestion(say: LiveCoach.optOutLine, cue: "Opt out. Do not call is saved in Salesforce.", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
        guard let key = currentAttemptKey else { return }
        RemovedList.add(key)
        followUp = nil // no text, no LinkedIn
        CallTrace.event("crm.suppress", ["record": key, "actions": ["DoNotCall", "status", "off every list", "no text"]])
        outcomeSaved.insert(String(key.prefix(15))) // nothing more to log
        ActivityLog.add("Opt out from \(calling ?? key): \"\(said)\". Off every list, no text, writing DoNotCall and status")
        CallTrace.event("intent", ["intent": "opt_out", "said": said, "why": "opt-out phrase in their words", "action": "goodbye line, DoNotCall, hang up"])
        Task { [weak self] in
            do {
                try await Salesforce.setDoNotCall(key)
                ActivityLog.add("Opt out: DoNotCall saved in Salesforce for \(self?.calling ?? key)")
            } catch {
                ActivityLog.problem("Opt out: couldn't save DoNotCall in Salesforce: \(error.localizedDescription)")
            }
            // Status too: Leads go Unqualified, Contacts go Negative. Both keep them off every list.
            let status = key.hasPrefix("00Q") ? "Unqualified" : "Negative"
            do {
                try await Salesforce.setStatus(of: key, to: status, note: "Asked not to be called again: \"\(said.prefix(200))\"")
                ActivityLog.add("Opt out: status set to \(status)")
            } catch {
                ActivityLog.problem("Opt out: couldn't set status to \(status): \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(6)) // time to say goodbye
            guard let self, self.status == .live, AircallPhone.isOn else { return }
            _ = await AircallPhone.shared.hangUp()
        }
    }

    func prepareOpener() {
        // A ready-to-read line right away (from the opener template), so there's always a script
        // on screen before the phone rings. Claude's personal version replaces it when it's ready.
        seq += 1
        instantOpenerID = seq
        show(instantOpener(for: calling), id: seq, kind: .opener)
        // Claude's personal opener costs tokens: only for someone we'll really call, once they've been
        // on screen 1.5 s (a skipped person is gone by then), and one request even when several things
        // (page open, details loaded) ask for it at once.
        openerTask?.cancel()
        let key = recordKey()
        if let key, MobileOnly.excluded(key) || RemovedList.contains(key) { return }
        openerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, self.recordKey() == key,
                  self.status == .ready || (self.status == .live && self.turns.isEmpty) else { return }
            if let key, MobileOnly.excluded(key) || RemovedList.contains(key) { return }
            self.ask(.opener, user: CoachPrompt.opener(calling: self.calling, details: self.recordDetails, style: self.openerStyle,
                                                       scriptOpener: self.openerStyle == nil ? self.scriptOpenerLine() : nil))
        }
    }

    func ask(_ kind: Kind, user: String, early: String? = nil) {
        guard let key = Keychain.read(.anthropic) else {
            problem = "Add your Anthropic key: gear > Setup > AI keys."
            return
        }
        if doNotCall, kind == .reply {
            CallTrace.event("claude.blocked", ["why": "do not call", "early": early != nil])
            return
        }
        coachTask?.cancel() // a newer statement makes the old answer stale
        if kind == .reply { repWordsAtLastAsk = repWordsInCall; repTextSinceAsk = "" }
        let repLed = nextIsRepLed
        nextIsRepLed = false
        seq += 1
        let id = seq
        if repLed { repLedIDs.insert(id) }
        let askedAt = Date()
        logSystemIfChanged()
        CallTrace.event("memory.snapshot", ["summary": CoachPrompt.liveSummary, "summary_version": CallTrace.memVersion,
                                            "question_facts": CoachPrompt.questionFacts, "objection_facts": CoachPrompt.objectionFacts, "blocker_hints": CoachPrompt.blockerHints,
                                            "turns": turns.count], req: id)
        let requested = (kind == .reply ? LiveCoach.client(key) : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)).model
        if kind == .reply { ActivityLog.add("Coach #\(id): asking \(ClaudeClient.displayName(requested))\(early == nil ? "" : " early, from their words so far")") }
        else { ActivityLog.add("Coach #\(id): \(kind) from \(ClaudeClient.displayName(requested))") }
        CallTrace.event("claude.request", [
            "kind": "\(kind)", "early": early != nil, "early_basis": early ?? "",
            "system_chars": self.system.count, "system_hash": Self.stableHash(self.system),
            "user_message": user, "summary_version": CallTrace.memVersion,
            "context": kind == .reply ? CoachPrompt.lastContext : [:], "user_chars": user.count,
        ], req: id)
        specBasis = early.map(normalized)
        specHeld = nil
        confirmedAt = nil
        // Live lines: Haiku, short and fast. Voicemails also Haiku, so the message is ready before the beep.
        let client = kind == .reply ? LiveCoach.client(key)
            : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)
        let system = self.system
        thinking = true
        CallTrace.event("claude.settings", ["model": client.model, "max_tokens": client.maxTokens, "effort": client.effort,
                                            "thinking": client.thinking?["type"] ?? "default", "stream": true,
                                            "idle_timeout_s": client.idleTimeout, "total_timeout_s": client.totalTimeout], req: id)

        coachTask = Task { [weak self] in
            do {
                var finalText = ""
                let gate = LineGate()
                let started = Date()
                var firstToken = false
                try await client.stream(system: system, user: user, onText: { text in
                    if !firstToken, kind == .reply {
                        firstToken = true
                        ActivityLog.add("Coach #\(id): first words from Claude after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        Task { @MainActor in CallTrace.event("claude.first_token", ["ms": ms], req: id) }
                    }
                    finalText = text
                    let s = Suggestion.parse(text)
                    Task { @MainActor in
                        guard kind == .reply else { self?.offer(s, id: id, kind: kind, askedAt: askedAt); return }
                        // A live line shows only once it's whole and passes the house rules.
                        guard (s.sayComplete && !s.stage.isEmpty) || s.skip, !gate.checked else { if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }; return }
                        gate.checked = true
                        let problems = s.skip ? [] : Self.lineProblems(s)
                        gate.passed = problems.isEmpty
                        CallTrace.event("check.result", ["stage": "stream", "line": s.say, "skip": s.skip,
                                                         "passed": gate.passed, "problems": problems], req: id)
                        if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
                    }
                }, onUsage: { u in
                    // Token counts and cache use: cache_read > 0 means the system prompt came from cache.
                    Task { @MainActor in CallTrace.event("claude.usage", u.merging(["ms": Int(Date().timeIntervalSince(started) * 1000)]) { a, _ in a }, req: id) }
                }, onModel: { served in
                    guard served != requested, !served.hasPrefix(requested) else { return }
                    Task { @MainActor in
                        ActivityLog.add("Coach #\(id): model switched: asked \(ClaudeClient.displayName(requested)), answered by \(ClaudeClient.displayName(served)) (fallback)")
                        CallTrace.event("claude.model_switch", ["requested": requested, "served": served], req: id)
                    }
                })
                if kind == .reply { ActivityLog.add("Coach #\(id): Claude done after \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
                CallTrace.event("claude.done", ["ms": Int(Date().timeIntervalSince(started) * 1000), "output": finalText,
                                                "fresh": self?.seq == id], req: id)
                var last = Suggestion.parse(finalText)
                last.sayComplete = true
                if kind == .reply, !last.skip, !last.say.isEmpty {
                    let problems = Self.lineProblems(last)
                    CallTrace.event("check.result", ["stage": "final", "line": last.say, "passed": problems.isEmpty,
                                                     "problems": problems], req: id)
                    if !problems.isEmpty { last = await self?.fixLine(last, system: system, user: user, key: key, id: id) ?? last }
                }
                self?.offer(last, id: id, kind: kind, askedAt: askedAt)
            } catch is CancellationError {
                CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
            } catch let error as URLError where error.code == .cancelled {
                CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
            } catch {
                CallTrace.event("claude.error", ["error": error.localizedDescription], req: id)
                // Keep the last good line on screen; just flag it.
                self?.problem = "Coach hiccup: \(error.localizedDescription)"
                ActivityLog.problem("Claude error: \(error.localizedDescription)")
            }
            if self?.seq == id { self?.thinking = false }
        }
    }

    /// The house rules for a live line (offered meeting times are allowed).
    static func lineProblems(_ s: Suggestion) -> [String] {
        Guardrail.problems(s.say, endsCall: ["Exit", "Goal reached", "Voicemail"].contains(s.stage) || s.rowTag != nil, allowTimes: true)
    }

    /// A line broke the rules: Haiku tries again with the reasons, then Sonnet, then the smallest safe fix.
    func fixLine(_ bad: Suggestion, system: String, user: String, key: String, id: Int = 0) async -> Suggestion {
        var problems = Self.lineProblems(bad)
        ActivityLog.add("Line check: failed (\(problems.joined(separator: "; "))): \(bad.say)")
        CallTrace.event("check.fail", ["line": bad.say, "problems": problems], req: id)
        // Formatting only (an abbreviation like CRM, an em dash): fix it in code, no second request.
        if problems.allSatisfy({ $0.hasPrefix("abbreviation") || $0 == "em dash" || $0 == "more than one question" }),
           let fixed = LineRepair.fix(bad.say) {
            var s = bad
            s.say = fixed
            // Spelled-out words add syllables: allow half a grade of slack on a repaired line (M6).
            let left = Self.lineProblems(s).filter { !($0.hasPrefix("reading level") && ReadingLevel.grade(fixed) <= ReadingLevel.checkMax + 0.5) }
            if left.isEmpty {
                ActivityLog.add("Line check: fixed in code (no extra request)")
                CallTrace.event("check.fixed_locally", ["from": bad.say, "line": fixed], req: id)
                return s
            }
        }
        for model in ["claude-haiku-5-5"] { // one Haiku retry at most; no Sonnet on a live call (H4)
            var text = ""
            let retry = user + "\n\nYour last SAY broke these rules: \(problems.joined(separator: "; ")). It was: \"\(bad.say)\". Write it again."
            CallTrace.event("claude.retry.request", ["model": model, "user_message": retry], req: id)
            let t0 = Date()
            ActivityLog.add("Line check: asking \(ClaudeClient.displayName(model)) to fix it")
            try? await LiveCoach.client(key, model: model).stream(system: system, user: retry) { text = $0 }
            var s = Suggestion.parse(text)
            s.sayComplete = true
            let left = s.skip ? [] : Self.lineProblems(s)
            CallTrace.event("claude.retry.done", ["model": model, "ms": Int(Date().timeIntervalSince(t0) * 1000), "output": text,
                                                  "passed": !s.say.isEmpty && left.isEmpty, "problems": left], req: id)
            if s.skip || (!s.say.isEmpty && Self.lineProblems(s).isEmpty) {
                ActivityLog.add("Line check: fixed by \(model.contains("haiku") ? "Haiku" : "Sonnet")")
                CallTrace.event("check.fixed", ["model": model, "line": s.say], req: id)
                return s
            }
            if !s.say.isEmpty { problems = Self.lineProblems(s) }
        }
        var s = bad
        s.say = LiveCoach.sanitize(bad.say)
        ActivityLog.add("Line check: trimmed to fit: \(s.say)")
        CallTrace.event("check.trimmed", ["line": s.say, "from": bad.say], req: id)
        return s
    }

    /// Shows a suggestion, but never swaps a fresh line out from under the rep.
    func offer(_ s: Suggestion, id: Int, kind: Kind, askedAt: Date) {
        guard id == seq, !s.skip, !s.say.isEmpty, !doNotCall else { // do not call: nothing replaces the goodbye
            // MOVE: silent: keep the line if it still fits; clear it if the talk moved past it.
            let movedOn: Bool = {
                guard let last = turns.last, last.speaker == .prospect else { return lineSuperseded }
                let repAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
                return lineSuperseded || repAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?")
            }()
            if s.move == "silent", id == seq, !doNotCall, status == .live, !suggestion.say.isEmpty,
               SilentRule.clearNow(superseded: movedOn, delivered: lineDelivered, answered: answeredAfterDelivery, signals: signals()) {
                CallTrace.event("suggestion.cleared", ["line": suggestion.say, "why": "Claude chose silent and the line was outdated"], sug: shownID)
                suggestion = Suggestion()
                lineSuperseded = false
            }
            if s.sayComplete || s.skip {
                let why = doNotCall ? "do not call" : id != seq ? "stale: request #\(seq) is newer" : s.move == "silent" ? "Claude chose silent: no new line needed" : s.skip ? "Claude said skip" : "empty"
                CallTrace.event("suggestion.dropped", ["line": s.say, "why": why], sug: id)
            }
            return
        }
        // Easier to read live: show the line once it's whole, not word by word (setting).
        let wholeLine = Prefs.wholeLine
        if wholeLine && !s.sayComplete { return }
        if specBasis != nil {
            if s.sayComplete, specHeld?.id != id {
                CallTrace.event("suggestion.held_early", ["line": s.say, "basis": specBasis ?? "", "why": "drafted early: waits for them to stop"], sug: id)
            }
            specHeld = (s, id) // started early: wait until they really stop talking
            return
        }
        if kind == .reply, timedID != id {
            timedID = id // time from "they stopped talking" to the first words of the answer
            latency = max(0, Date().timeIntervalSince(confirmedAt ?? askedAt))
        }
        if id == shownID {
            // Once a line is whole on screen, its words are frozen: a late chunk never changes it (N2).
            if suggestion.sayComplete { return }
            if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
            var s = s
            s.say = fillTags(s.say, for: calling) // never show a bare [Name] or [SDR]
            suggestion = s // same answer, still streaming in
            note(s)
            return
        }
        // The call is live and someone already talked: keep the opener the rep is reading.
        if kind == .opener, status == .live, repWordsInCall > 0 || turns.contains(where: { $0.speaker == .prospect })
            || signals().repSpeaking || !(interim[.rep] ?? "").isEmpty {
            if s.sayComplete { CallTrace.event("suggestion.dropped", ["line": s.say, "why": "opener arrived after the talk started"], sug: id) }
            return
        }
        // The AI thinks ahead, the screen follows the conversation: never swap the line while the rep is
        // speaking. Queue it, flag the old one as outdated, and show it the moment they stop.
        // A new prospect turn since the line appeared = the conversation moved on.
        // Only a real reply moves the conversation on (3+ words or a question), not "uh-huh" or "yeah".
        // Any answer to a question you asked counts too, even "yes" or "nope", so you never have to press Next.
        let youAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        if kind == .reply, repLedIDs.contains(id), !lineSuperseded || supersededLogged != shownID {
            supersededLogged = shownID
            CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id,
                                                      "why": "the rep moved on in their own words", "delivered": lineDelivered], sug: shownID)
            lineSuperseded = true
        }
        if kind == .reply, let last = turns.last, last.speaker == .prospect,
           youAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?") {
            if !lineSuperseded || supersededLogged != shownID {
                supersededLogged = shownID
                let why = youAsked ? "they answered your question" : last.text.contains("?") ? "they asked a question" : "they said something new (3+ words)"
                CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id, "prospect_said": last.text,
                                                          "why": why, "delivered": lineDelivered], sug: shownID)
                ActivityLog.add("Coach #\(shownID): line outdated (\(why))")
            }
            lineSuperseded = true
        }
        // The rep moved past it while it was being written (asked, pivoted, or kept talking): drop it (round 2 #1).
        let readingOnScript = !lineDelivered && Delivery.onLine(line: suggestion.say, spoken: recentRepChunks.joined(separator: " "))
        let staleWhy = kind == .reply && id != shownID
            ? QueuedLine.staleReason(ageSeconds: 0, repWordsSinceQueued: readingOnScript ? 0 : repWordsInCall - repWordsAtLastAsk,
                                     repAskedSinceQueued: QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
                                                                                          lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate),
                                     repTextSinceQueued: repTextSinceAsk)
            : nil
        let decision = CoachController.offer(isOpenerOrVoicemail: kind == .opener || kind == .voicemail, firstLine: shownID == 0,
                                             holdLine: holdLine, signals: signals(), staleReason: staleWhy)
        if case .drop(let why) = decision {
            CallTrace.event("suggestion.discarded", ["line": s.say, "why": "stale on arrival: \(why)", "rule": QueuedLine.ruleKind(why)], sug: id)
            // Only when they talked on in their own words: after a question or a pivot, the prospect's answer comes next.
            if why.hasPrefix("the rep said") { followRep(why: "the line arrived after the rep moved on") }
            return
        }
        if decision == .show {
            show(s, id: id, kind: kind)
        } else {
            if pending?.id != id {
                let why = holdLine ? "held by you" : repSpeaking ? "you're speaking" : "you may be reading"
                ActivityLog.add("Coach #\(id): line queued (\(why))")
                CallTrace.event("suggestion.queued", ["line": s.say, "why": why, "signals": signals().trace], sug: id)
            }
            if let old = pending, old.id != id {
                CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer queued line replaced it"], sug: old.id)
            }
            if pending?.id != id {
                pendingQueuedAt = Date()
                repWordsAtQueue = repWordsAtLastAsk // what the rep had said when this line was asked for
                // C4: a question the rep asked while this line was still being written counts too.
                repAskedSinceQueue = QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
                                                                     lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate)
            }
            pending = (id, s)
        }
    }

    /// Same text, same hash, on every run (Swift's hashValue changes each launch).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The full system prompt goes in the trace at call start and again whenever it changes.
    func logSystemIfChanged() {
        let h = Self.stableHash(system)
        guard h != loggedSystemHash else { return }
        loggedSystemHash = h
        CallTrace.event("context.system", ["text": system, "hash": h])
    }

    /// The approved script answer for what they said, shown with no AI wait. True if one matched.
    func instantAnswer(_ said: String) -> Bool {
        guard status == .live, !doNotCall else { return false }
        let answers = scriptAnswers
        guard let e = answers.match(said) else {
            CallTrace.event("script.match", ["searched": answers.entries.count, "matched": false, "said": said])
            return false
        }
        CallTrace.event("script.match", ["searched": answers.entries.count, "matched": true, "row": e.id,
                                         "phrases": e.phrases, "said": said, "answer": e.say, "why": "a Sounds-like phrase appears in their words"])
        if suggestion.say == e.say || pending?.suggestion.say == e.say { return true } // already up
        coachTask?.cancel() // any slower AI draft for this is stale now
        thinking = false
        specBasis = nil
        specHeld = nil
        markRequestStart()
        seq += 1
        ActivityLog.add("Coach #\(seq): instant answer from your script (\(e.id)), no AI")
        offer(Suggestion(say: e.say, cue: "From your script: \(e.id)", stage: "Objection", sayComplete: true),
              id: seq, kind: .reply, askedAt: Date())
        return true
    }

    /// Called twice a second: a queued line shows once the rep stops speaking.
    func promotePendingIfReady() {
        guard status == .live, let p = pending, CoachMachine.isFresh(requestID: p.id, latestID: seq) else { return }
        let decision = CoachController.promote(holdLine: holdLine, signals: signals(),
                                               ageSeconds: Date().timeIntervalSince(pendingQueuedAt),
                                               repWordsSinceQueued: repWordsInCall - repWordsAtQueue,
                                               repAskedSinceQueued: repAskedSinceQueue, repTextSinceQueued: repTextSinceAsk)
        guard decision != .wait else {
            if blockedLoggedID != p.id { // once per queued line, not every tick
                blockedLoggedID = p.id
                CallTrace.event("promotion.blocked", ["why": holdLine ? "held by the rep" : "not safe to replace yet",
                                                      "signals": signals().trace], sug: p.id)
            }
            return
        }
        // The rep's words are the source of truth: if they moved on while this waited, it's stale.
        if case .drop(let why) = decision {
            pending = nil
            ActivityLog.add("Coach #\(p.id): queued line dropped (\(why); \(QueuedLine.ruleKind(why)) rule)")
            CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)",
                                                     "rule": QueuedLine.ruleKind(why)], sug: p.id)
            // They asked their own question: the next move is the prospect's answer. Otherwise write the
            // next line from where the rep actually is.
            if !repAskedSinceQueue { followRep() }
            return
        }
        ActivityLog.add("Coach #\(p.id): queued line shown")
        CallTrace.event("suggestion.promoted", ["why": "safe to replace now (rep stopped, line read or delivered)"], sug: p.id)
        show(p.suggestion, id: p.id, kind: .reply)
    }

    /// The rep went off script and paused without asking anything: the next line builds on what they
    /// actually said, not on what the script expected.
    func followRep(why: String = "the rep moved on from the queued line") {
        guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
              let rep = turns.last, rep.speaker == .rep else { return }
        CallTrace.event("follow_rep", ["rep_said": rep.text, "why": why])
        nextIsRepLed = true
        ask(.reply, user: CoachPrompt.reply(turns: turns, latest: rep.text, calling: calling, details: recordDetails,
                                            style: callOpener, openTimes: bookingText(), repLed: true))
    }

    /// After each thing the rep says: if they're off script, get the next line ready now, while they
    /// talk, so it's waiting when they pause. A queued line they've moved past is dropped first.
    func prepareWhileRepTalks(_ text: String) {
        guard status == .live, !doNotCall, !voicemailActive, !screenerActive, !suggestion.say.isEmpty else { return }
        let since = repWordsInCall - repWordsAtLastAsk
        guard FollowRep.shouldPrepare(repJustSaid: text, recentRepSpeech: recentRepChunks.joined(separator: " "),
                                      shownLine: suggestion.say, shownLineDelivered: lineDelivered,
                                      repWordsSinceLastAsk: since) else { return }
        if let p = pending {
            pending = nil
            let why = "the rep said \(since) words of their own since"
            ActivityLog.add("Coach #\(p.id): queued line dropped while you talk (\(why); heuristic rule)")
            CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)", "rule": "heuristic"], sug: p.id)
        }
        followRep(why: "preparing ahead: the rep is off script (\(since) words since the last request)")
    }

    /// The rep just asked a yes/no question: write the line for "yes" now, while they wait for the
    /// answer. It's held, never shown, until the prospect actually says yes. Open questions ("What do
    /// you use?") get nothing ahead: the answer comes from their real words.
    func prepareYesBranch(_ text: String) {
        // Keep the ready line through small talk; drop it for a new question or once the talk moved on (H3).
        if yesBranch != nil {
            yesBranchRepWords += text.split(separator: " ").count
            if YesBranchRule.keep(afterRepSaid: text, wordsSinceQuestion: yesBranchRepWords) { return }
            CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "the rep moved on or asked a new question"])
        }
        yesBranchTask?.cancel()
        yesBranch = nil
        yesBranchWanted = nil
        guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
              let q = RepQuestion.closedQuestion(in: text), let key = Keychain.read(.anthropic) else { return }
        yesBranchRepWords = 0
        yesBranchAskedAt = Date()
        let user = CoachPrompt.reply(turns: turns, latest: q, calling: calling, details: recordDetails, style: callOpener,
                                     openTimes: bookingText(), assumeYes: true)
        let system = self.system
        yesBranch = (q, Suggestion(say: "", cue: "", stage: ""), false)
        CallTrace.event("yes_branch.request", ["question": q, "user_message": user])
        let started = Date()
        yesBranchTask = Task { [weak self] in
            var text = ""
            try? await LiveCoach.client(key).stream(system: system, user: user, onText: { text = $0 }, onUsage: { u in
                Task { @MainActor in CallTrace.event("claude.usage", u.merging(["yes_branch": 1]) { a, _ in a }) }
            })
            guard let self, !Task.isCancelled, self.yesBranch?.question == q else { return }
            CallTrace.event("claude.done", ["yes_branch": true, "ms": Int(Date().timeIntervalSince(started) * 1000), "output": text])
            var s = Suggestion.parse(text)
            s.sayComplete = true
            let problems = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
            if !problems.isEmpty, let fixed = LineRepair.fix(s.say) { s.say = fixed }
            let left = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
            CallTrace.event("yes_branch.ready", ["question": q, "line": s.say, "ms": Int(Date().timeIntervalSince(started) * 1000),
                                                 "passed": left.isEmpty, "problems": left])
            if left.isEmpty { self.yesBranch = (q, s, true) } else { self.yesBranch = nil }
            // They already said yes while this was being written: show it now, or fall back to a normal answer.
            if let said = self.yesBranchWanted {
                self.yesBranchWanted = nil
                self.yesBranch = nil
                if left.isEmpty, self.status == .live, !self.doNotCall {
                    CallTrace.event("yes_branch.used", ["question": q, "answer": said, "line": s.say, "late": true])
                    self.markRequestStart()
                    self.seq += 1
                    self.offer(s, id: self.seq, kind: .reply, askedAt: Date())
                } else {
                    self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
                                                             details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
                }
            }
        }
    }

    /// A yes line or script answer is a new request too: what the rep said before it doesn't make it stale.
    func markRequestStart() {
        repWordsAtLastAsk = repWordsInCall
        repTextSinceAsk = ""
    }

    /// The Next button: show the queued line now.
    func promoteNow() {
        guard let p = pending else { return }
        ActivityLog.add("Coach: Next clicked, queued line shown")
        CallTrace.event("manual", ["action": "Next"], sug: p.id)
        show(p.suggestion, id: p.id, kind: .reply)
    }

    func show(_ s: Suggestion, id: Int, kind: Kind) {
        // After an opt-out, only the goodbye line may ever show (round 2 #3).
        if doNotCall, s.say != LiveCoach.optOutLine {
            CallTrace.event("suggestion.dropped", ["line": s.say, "why": "do not call", "kind": "\(kind)"], sug: id)
            return
        }
        if status == .live, !s.say.isEmpty {
            let ms = lastHeardThemAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            ActivityLog.add("Coach line shown (\(kind)\(ms.map { ", \($0) ms after their last words" } ?? "")): \(s.say)")
        }
        var s = s
        s.say = fillTags(s.say, for: calling) // [SDR], {first name} and other slots Claude copied from the script
        if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
        if let old = pending, old.id != id {
            ActivityLog.add("Coach #\(old.id): queued line discarded (newer one shown)")
            CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer line was shown"], sug: old.id)
        }
        if status == .live, kind == .reply || kind == .opener, !s.say.isEmpty {
            CoachPrompt.shownLines.append(s.say)
        }
        if status == .live {
            CallTrace.event("suggestion.shown", ["line": s.say, "cue": s.cue, "stage": s.stage, "move": s.move, "kind": "\(kind)",
                                                 "replaced": suggestion.say, "replaced_delivered": lineDelivered], sug: id)
        }
        pending = nil
        lineSuperseded = false
        if kind == .reply { repTextSinceAsk = ""; repWordsAtLastAsk = repWordsInCall } // round 2 #9
        priorLineOfferedTime = !suggestion.offered.isEmpty || GoalEvidence.mentionsTime(suggestion.say)
        // The old line: partly said in the rep's own words? Then it isn't "never said" (H1).
        if status == .live, !suggestion.say.isEmpty, !lineDelivered,
           Delivery.likelyCovered(line: suggestion.say, spoken: repSaidSinceShown),
           !CoachPrompt.likelyCoveredLines.contains(suggestion.say) {
            CoachPrompt.likelyCoveredLines.append(suggestion.say)
            CallTrace.event("delivery.likely", ["line": suggestion.say, "said": repSaidSinceShown,
                                                "confidence": Delivery.confidence(line: suggestion.say, spoken: repSaidSinceShown)], sug: shownID)
        }
        repSaidSinceShown = ""
        lineDelivered = false
        answeredAfterDelivery = false
        shownID = id
        shownAt = Date()
        repWordsSinceShown = 0
        suggestion = s
        historyIndex = nil
        if !s.say.isEmpty, s.sayComplete || kind != .reply { history.append((s: s, kind: kind)) }
        self.kind = kind
        problem = nil
        note(s)
    }

    /// Bookkeeping for what a line tells us: stage reached, times offered, goal, voicemail.
    func note(_ s: Suggestion) {
        if status != .ready, !s.stage.isEmpty {
            stagesSeen.insert(s.stage)
            trackJourney(s.stage)
        }
        if voicemailActive, !s.textMessage.isEmpty || !s.linkedin.isEmpty || !s.linkedinMessage.isEmpty { fillFollowUp(from: s) }
        // Remember which meeting times this line offered, so the next ones are different.
        if !s.offered.isEmpty {
            let dates = s.offered.compactMap { code in codeByDate.first { $0.value == code }?.key }
            offeredTimes.formUnion(dates)
            nextOffer = pickNextPair(from: availability.offerSlots())
        }
        if s.stage == "Closing" { availability.refreshIfOlder() } // fresh times while booking
        // A closing line on screen is only a pending goal; the prospect's words confirm it (N4).
        if s.stage == "Goal reached", !goalHit {
            goalPending = true
            goalPendingTurns = 2
            // They often agree first ("Tuesday works") and the closing line follows: check their last words too.
            if let last = turns.last(where: { $0.speaker == .prospect }) { confirmGoalIfAgreed(last.text, checkingEarlierTurn: true) }
        }
        if s.stage == "Voicemail" { sawVoicemail = true }
    }

    func scheduleStillWithMe() {
        stillWithMeTask?.cancel()
        guard let last = turns.last, last.speaker == .rep, last.text.trimmed.hasSuffix("?"),
              turns.contains(where: { $0.speaker == .prospect }),
              !voicemailActive, !screenerActive, !phoneTreeActive, !badNumberThisCall else { return }
        let askedAt = lastWordsAt
        stillWithMeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall, self.lastWordsAt == askedAt,
                  self.turns.last?.speaker == .rep, !self.voicemailActive,
                  (self.interim[.prospect] ?? "").isEmpty, // they're mid-answer
                  !self.signals().repSpeaking, (self.interim[.rep] ?? "").isEmpty,
                  CoachMachine.canReplace({ var x = self.signals(); x.queuedIsForNewTopic = true; return x }()) else { return } // never over the rep (C6)
            self.coachTask?.cancel()
            self.thinking = false
            self.seq += 1
            var nudge = Suggestion(say: "Still with me?", cue: "6 seconds of silence after your question.",
                                   stage: "", sayComplete: true)
            nudge.nudge = true
            self.show(nudge, id: self.seq, kind: .reply)
            self.repWordsSinceShown = 99 // a nudge, not a script line: never hold the prospect's answer for it
        }
    }

    /// Switches (or refreshes) the campaign. Takes effect right away between calls.
    /// Refreshes the opener after a setting changes (rotation, your name).
    func refreshOpener() {
        if status == .ready { prepareOpener() }
    }
}
```

## `mac/Sources/ClarityLiveCoach/CoachModel+Call.swift`

```swift
import AppKit
import CoachCore
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// A call from start to end: the tick, starting and ending calls, auto redial and auto next.
extension CoachModel {
    /// Whoever is up has a phone number outside the US and Canada: skip them, whatever loaded them.
    /// Checked every half second, so no path (first lead, Back, reload, auto next) can miss it.
    private func skipForeignLead() {
        MobileOnly.campaignID = campaign.id
        callList.pin(object: campaign.listObject, view: campaign.listViewID) // only the menu's list
        if leads.isActive, let d = leads.details { MobileOnly.record(d.id, mobile: d.mobile) }
        // Mobile numbers only: no Mobile on file, skip them for this call list.
        if MobileOnly.on, status == .ready, !dialing, let key = recordKey(), MobileOnly.excluded(key), mobileSkippedID != key {
            mobileSkippedID = key
            ActivityLog.add("\(calling ?? key) has no Mobile (Mobile numbers only is on): skipping")
            problem = "No Mobile number. Skipped (Mobile numbers only)."
            skipNext(why: "no Mobile number (Mobile numbers only is on)")
            return
        }
        // The Chrome list: someone off the list (non-US number, removed) is on screen: move on.
        if !leads.isActive, status == .ready, !dialing, let key = recordKey(), RemovedList.contains(key),
           foreignSkippedID != key {
            foreignSkippedID = key
            ActivityLog.add("\(calling ?? key) is off the list (non-US number or removed): skipping")
            problem = "Off your list. Skipped, on to the next person."
            skipNext(why: "off the list")
            return
        }
        guard status == .ready, !dialing, leads.isActive, let d = leads.details, !d.doNotCall,
              let n = d.foreignNumber, foreignSkippedID != d.id else { return }
        foreignSkippedID = d.id // once per person, so Back can still show them
        ActivityLog.add("\(d.name) isn't a US or Canada number (\(n)): skipping and removing from the list")
        RemovedList.add(d.id)
        problem = "Not a US or Canada number. Skipped, on to the next person."
        skipNext(why: "not a US or Canada number")
    }

    func tick() {
        guard active else { return }
        checkBlock()
        // Midnight: yesterday's "called today" clears, so people due today come back on the list.
        let day = Calendar.current.component(.day, from: Date())
        if day != lastTickDay {
            if lastTickDay != 0 {
                callList.resetCalledIfNewDay()
                callList.refreshUpNext()
                leads.resetIfNewDay()
                ActivityLog.add("New day: called-today list cleared")
            }
            lastTickDay = day
        }
        skipForeignLead()
        promotePendingIfReady()
        if status == .live {
            let next = CoachMachine.state(signals())
            if next != coachState {
                ActivityLog.add("Coach state: \(coachState.rawValue) -> \(next.rawValue)")
                CallTrace.event("state", ["from": coachState.rawValue, "to": next.rawValue, "signals": signals().trace])
                coachState = next
            }
        } else if coachState != .idle { coachState = .idle }
        if phase != loggedPhase {
            ActivityLog.add("Phase: \(loggedPhase.rawValue) -> \(phase.rawValue)")
            loggedPhase = phase
        }
        let onCall = AudioProcess.anyCallApp(in: AudioProcess.others())
        // Between calls, notice which record is open so the opener uses their name.
        // Dialed from the app: start listening once the Aircall app picks up the call (or after 8 s).
        if let since = pendingDialSince, status == .ready {
            // Start listening almost right away, so a "straight to voicemail" greeting is heard from word one.
            if AudioProcess.aircallAppOnCall(in: AudioProcess.others()) || Date().timeIntervalSince(since) > 1 {
                pendingDialSince = nil
                waitingForNewCall = false
                startCall()
            }
            return
        }
        if status == .ready, !leads.isActive, !onCall || waitingForNewCall {
            tabTicks += 1
            if tabTicks % 2 == 0 {
                callList.captureIfListView()
                if openingID == nil { callList.refreshUpNext() }
                syncRecord()
            }
        }
        // In-app phone, call placed on the phone itself (not the Dial button): its red hang-up
        // button showing is the sign of a real call. Its open mic alone never is.
        if status == .ready, AircallPhone.isOn, pendingDialSince == nil { checkPhoneForNewCall() }
        switch status {
        case .ready where onCall:
            if waitingForNewCall || AircallPhone.isOn {
                // In-app phone: its own mic is held open all session, so sound alone never means a call.
                // Calls start from Dial, or when Aircall itself shows a new call.
                waitingForNewCall = true
                // Chrome is still holding the last call's mic/speaker: start only when Aircall shows a new call.
                checkAircallForNewCall()
            } else {
                startCall()
            }
        case .ready:
            waitingForNewCall = false // Chrome let go, so the next time it grabs the mic is a new call
        case .live:
            if onCall { heardCallAudio = true }
            // Safety net: nobody has said a word for 90 s = the call is over (no real call is that quiet).
            let silentFor = Date().timeIntervalSince(lastWordsAt ?? callStartedAt)
            if silentFor > 90, !startedByHand {
                ActivityLog.problem("Call ended: 90 s with no words")
                endCall(); return
            }
            // Only count quiet after the call's audio has shown up once, so a call that's
            // still ringing (we start listening right after dialing) isn't ended early.
            // In-app phone: its mic is held open all session, so "the call app went quiet" means nothing.
            // The phone's hang-up button and Aircall itself say when the call ends.
            if !startedByHand, !AircallPhone.isOn, heardCallAudio || Date().timeIntervalSince(callStartedAt) > 45 {
                quietTicks = onCall ? 0 : quietTicks + 1
                if quietTicks >= 6 { endCall(); return } // Chrome let go of the call for 3 seconds
            }
            // Rang 20 seconds and nobody spoke (no person, no recording): hang up for the rep, so the
            // redial or the next person starts by itself.
            if autoDial, AircallPhone.isOn, !startedByHand, !autoHungUpThisCall, !autoHangingUp,
               !phoneTreeActive, !phoneTreeThisCall, !sawVoicemail, !screenerActive, !voicemailDropStarted,
               !turns.contains(where: { $0.speaker == .prospect }),
               Date().timeIntervalSince(callStartedAt) > ringLimit {
                hangUpUnanswered()
            }
            if sawVoicemail || voicemailActive || kind == .voicemail { scheduleVoicemailDrop() } // whichever part spotted it
            checkAircallEveryFewSeconds()
            if aircallTicks % 2 == 0, Date().timeIntervalSince(callStartedAt) < 30 { followCallAudio() }
            if AudioProcess.doubleCall(in: AudioProcess.others()) {
                problem = "Two calls at once: Aircall is signed in here and in Salesforce. Log out of the Aircall panel in Salesforce."
            }
        default:
            break
        }
    }

    /// The End call button: hangs up the phone for real (Aircall's own button), then resets the app.
    func hangUpAndEnd() {
        guard status != .ready else { return }
        autoHungUpThisCall = true
        // Reset right now, don't wait for Aircall: the hang-up click happens in the background.
        if AircallPhone.isOn { Task { _ = await AircallPhone.shared.hangUp() } }
        endCall()
    }

    /// How long to let it ring: 20 s only on the first dial when "Call twice" is on (a redial follows).
    /// Any other dial rings until their voicemail answers, so the drop can wait for the end of the greeting.
    var ringLimit: TimeInterval {
        currentAttempts < maxAttempts ? 20 : .infinity
    }

    /// 20 seconds of ringing and nobody spoke: hang up, then the normal flow (redial, or the next person).
    func hangUpUnanswered() {
        autoHungUpThisCall = true
        ActivityLog.add("Rang 20 s with no answer for \(calling ?? "?"): hanging up")
        Task { [weak self] in
            guard let self, self.status == .live else { return }
            let done = await AircallPhone.shared.hangUp()
            guard done else { ActivityLog.problem("Ringing hang-up: couldn't find Aircall's hang-up button"); return }
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1))
                if await Aircall.lineIsOnCall() == false { break }
            }
            if self.status == .live { self.endCall() }
        }
    }

    /// A short note at the top that fades by itself.
    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// The rep clicked End call (or Aircall/Chrome says it's over): reset for the next call.
    func endCall() {
        guard status != .ready else { return }
        CallTrace.endCall(["lead": calling ?? "?", "seconds": Int(Date().timeIntervalSince(callStartedAt)),
                           "voicemail": sawVoicemail, "they_spoke": turns.contains { $0.speaker == .prospect },
                           "turns": turns.count, "last_line": suggestion.say])
        let hadVoicemail = sawVoicemail // for the log
        if hadVoicemail, !(currentAttempts < maxAttempts && autoDial), !autoHungUpThisCall, repWordsInCall >= 8,
           let key = currentAttemptKey,
           Cadence.leavesVoicemail(for: key),
           let said = voicemailScript?.say, voicemailFor == calling {
            DialHistory.logVoicemail(key, body: said)
        }
        // Didn't connect: over in under 12 seconds, nobody talked, no voicemail. That's a bad
        // number's beeping tone or a dropped call, not a person who didn't pick up (that rings 20+ s).
        let quickFail = !badNumberThisCall && !startedByHand && !sawVoicemail
            && Date().timeIntervalSince(callStartedAt) < 12
            && !turns.contains { $0.speaker == .prospect }
        ActivityLog.add("Call ended: \(calling ?? "?") after \(Int(Date().timeIntervalSince(callStartedAt))) s. voicemail=\(sawVoicemail) theySpoke=\(turns.contains(where: { $0.speaker == .prospect })) bad=\(badNumberThisCall)")
        if !turns.isEmpty {
            let words = turns.map { "\($0.speaker == .rep ? "Rep" : "Them"): \($0.text)" }.joined(separator: " | ")
            ActivityLog.add("Transcript: \(words.prefix(6000))")
        }
        if quickFail, let key = currentAttemptKey {
            outcomeSaved.insert(String(key.prefix(15))) // nothing to rate
            let fails = DialHistory.logFailedConnect(key)
            if fails >= 2 { markNotQualityProspect(key, reason: "didn't connect twice") }
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true // no redial
            problem = fails >= 2 ? "Didn't connect again. Bad number: taken off your list." : "Didn't connect (bad number or network). Moving on."
            afterHangUp { [weak self] in self?.startNextSequence() }
            return
        }
        if badNumberThisCall {
            // Number doesn't work: no voicemail, no text, no redial. Off the list, on to the next.
            badNumberThisCall = false
            if let key = currentAttemptKey { outcomeSaved.insert(String(key.prefix(15))) }
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true
            problem = phoneTreeThisCall ? "Phone tree. Disqualified and taken off your list." : "Bad number. Taken off your list."
            afterHangUp { [weak self] in self?.startNextSequence() }
            return
        }
        // 2nd try went to voicemail: they've had both calls. Move on by itself.
        let moveOn = sawVoicemail && currentAttempts >= maxAttempts
        nextCall()
        waitingForNewCall = true
        endedAt = Date()
        // Didn't reach them (no answer or voicemail): the text and LinkedIn card shows after
        // every such call, even when the voicemail greeting wasn't caught.
        if !lastCallAnswered, followUp == nil || followUp?.key != currentAttemptKey {
            startFollowUp()
            ActivityLog.add("Follow-up card for \(calling ?? "?") (voicemail heard: \(hadVoicemail))")
        }
        if let key = currentAttemptKey, RemovedList.contains(key) {
            // Marked Unqualified (or Not Quality Prospect / Negative) during the call: no text, no redial.
            ActivityLog.add("Call ended for someone taken off the list: on to the next person")
            followUp = nil
            waitingForText = false
            afterHangUp { [weak self] in self?.startNextSequence() }
        } else if shouldOfferRedial, autoDial {
            // 1st try, no answer: "Calling Jane Doe again in 3", then redial the same person.
            startAutoRedial()
        } else if !shouldOfferRedial, !lastCallAnswered, let f = followUp {
            // Done with them for now (both dials): send the text, then the next call starts.
            // No wait when no text can go out: none due today, already sent, a phone tree, or no
            // Mobile (landline only). An empty phone box always means no Mobile, so the text is skipped.
            let noMobile = f.noMobile || f.phone.trimmingCharacters(in: .whitespaces).isEmpty
            if f.textDue, !f.textDone, noMobile {
                followUp?.noMobile = true
                applyPlan() // hides the text and says why
                ActivityLog.add("No Mobile for \(calling ?? "?"): text skipped, on to the next person")
            }
            if f.textDone || !f.textDue || noMobile || phoneTreeThisCall {
                afterHangUp { [weak self] in self?.startNextSequence() }
            } else if autoDial, Aircall.isSetUp, Prefs.autoText, !f.text.isEmpty {
                // The text goes out in the background while the next person loads. No waiting.
                sendTextInBackground(f)
                afterHangUp { [weak self] in self?.startNextSequence() }
            } else {
                waitingForText = true
                startTextCountdown() // waits for its words, then sends by itself in 5 seconds (or the rep sends it)
            }
        } else if lastCallAnswered, autoDial, currentAttemptKey != nil {
            // A real talk just ended: Claude fills "How did it go?" from the transcript (you can change it),
            // then 10 seconds, then the next person. Wait stops it.
            autoOutcome()
            afterHangUp { [weak self] in self?.startMoveOn(after: 10) }
        } else if moveOn {
            afterHangUp { [weak self] in self?.startNextSequence() }
        }
    }

    /// Reached a recording (100% sure: words only a machine says) and auto-dial is on:
    /// - 1st try: hang up, then redial in 1 s.
    /// - Last try on a no-voicemail day: hang up, then on to the next person (after the text, if one is due).
    /// Clicks Aircall's hang-up button and waits until Aircall says the line is free.
    /// If anything is off (no button, line still busy), it does nothing and the rep hangs up as usual.
    func autoHangUpForRedial(why: String = "beep words") {
        guard autoDial, AircallPhone.isOn, !autoHangingUp, !autoHungUpThisCall, !voicemailDropStarted, // the drop is playing
              !phoneTreeActive, !phoneTreeThisCall, // never hang up on a phone menu
              let key = currentAttemptKey, !RemovedList.contains(key) else { return }
        let redialNext = currentAttempts < maxAttempts && !DialHistory.isMaxed(key)
        let noVoicemailToday = !Cadence.leavesVoicemail(for: key)
        guard redialNext || noVoicemailToday else { return } // a voicemail day's last try: leave the message
        autoHangingUp = true
        autoHungUpThisCall = true
        ActivityLog.add(redialNext ? "Recording for sure (\(why)) on the 1st try for \(calling ?? "?"): hanging up to redial"
                                   : "Recording (\(why)) on the last try, no voicemail today, for \(calling ?? "?"): hanging up, on to the next person")
        Task { [weak self] in
            guard let self, self.status == .live else { self?.autoHangingUp = false; return }
            var done = await AircallPhone.shared.hangUp()
            if done {
                // Only end the call on our side once Aircall says the line is free (up to 5 s).
                done = false
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(1))
                    if await Aircall.lineIsOnCall() == false { done = true; break }
                }
            }
            self.autoHangingUp = false
            guard self.status == .live else { return }
            if done {
                self.redialRightAway = redialNext
                self.endCall() // last try: endCall moves on to the next person
            } else {
                ActivityLog.problem("Auto hang-up didn't finish: the rep hangs up, redial as usual")
            }
        }
    }

    /// Counts down 3 seconds (1 after an automatic hang-up), then calls the same person again. Wait stops it.
    func startAutoRedial() {
        autoNextTask?.cancel()
        autoNextName = Screener.fullName(calling).map { "\($0) again" }
        let countdown = redialRightAway ? 1 : 3
        redialRightAway = false
        autoNextTask = Task { [weak self] in
            for left in stride(from: countdown, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled, self.shouldOfferRedial else { return }
            self.autoNextIn = nil
            self.redial()
        }
    }

    /// Counts down 5 seconds, then loads the next lead (and calls them, if "Next calls right away" is on).
    func startAutoNext(seconds: Int = 1) {
        guard nextLeadName != nil else { return }
        autoNextTask?.cancel()
        autoNextTask = Task { [weak self] in
            for left in stride(from: seconds, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                // A call started some other way: stop counting.
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled else { return }
            self.nextLead()
        }
    }

    /// Counts down, then moves to the next person (and calls them). Used after a real talk and
    /// after "How did it go?" is saved. Wait stops it.
    /// Reads the call and picks "How did it go?" (Interested, Not now, Not a fit, or nothing if unclear).
    /// Saves after 4 s unless the rep picked one first. Uses Haiku: fast and cheap.
    func autoOutcome() {
        guard let key = currentAttemptKey, turns.contains(where: { $0.speaker == .prospect }) else { return }
        let object = key.hasPrefix("003") ? "Contact" : "Lead"
        let options = Outcomes.quick(object)
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Them"): \($0.text)" }.joined(separator: "\n")
        let who = calling
        Task { [weak self] in
            let system = """
            You read a finished cold call and pick how it went. Options: \(options.map(\.label).joined(separator: ", ")), or None.
            Interested: they agreed to a meeting or asked to hear more. Not now: bad timing, call back later, send an email.
            Not a fit: the right person said they're clearly not interested, wrong company, or no need. None: only a front desk, a hang-up, a wrong number or someone else answered, or too short to tell.
            If Not a fit, also pick the closest reason from: \(Salesforce.unqualifiedReasons.joined(separator: ", ")), or "".
            Return only JSON: {"outcome": "", "reason": "", "why": "one short sentence"}
            """
            guard let json = try? await CallLab.ask(system: system, user: transcript, effort: "low", model: "claude-haiku-5-5"),
                  let label = json["outcome"] as? String, let pick = options.first(where: { $0.label == label }) else {
                ActivityLog.add("How did it go: left for you (Claude wasn't sure for \(who ?? "?"))")
                return
            }
            let reason = (json["reason"] as? String).flatMap { Salesforce.unqualifiedReasons.contains($0) ? $0 : nil }
            guard let self else { return }
            ActivityLog.add("How did it go: Claude picked \(pick.label) for \(who ?? "?") (\((json["why"] as? String) ?? ""))")
            self.showToast("How did it go: \(pick.label). Saving in 4 s, click another to change.")
            try? await Task.sleep(for: .seconds(4))
            guard !self.outcomeSaved.contains(String(key.prefix(15))), self.statusRecordID?.prefix(15) == key.prefix(15), !self.savingStatus else { return }
            if pick.value == "Unqualified", object == "Lead", reason == nil { // Salesforce needs a reason
                ActivityLog.add("How did it go: Not a fit needs a reason, left for you")
                return
            }
            self.saveStatus(pick.value, unqualifiedReason: reason)
        }
    }

    func startMoveOn(after seconds: Int) {
        guard status == .ready else { return }
        autoNextTask?.cancel()
        autoNextName = nextLeadName
        autoNextTask = Task { [weak self] in
            for left in stride(from: seconds, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled else { return }
            self.autoNextIn = nil
            self.startNextSequence()
        }
    }

    /// Sends the text from a copy of the card, 3 seconds from now, while the next person loads. The
    /// card can change meanwhile. A failure shows a note and never holds up the dialing.
    func sendTextInBackground(_ f: FollowUp) {
        bgTextTask?.cancel()
        bgTextTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            ActivityLog.add("Text: sending in the background for \(f.prospect ?? "?")")
            self.sendText(f, background: true)
        }
    }

    /// A text is due: wait for its words, count down 5 seconds, then send it. Editing the text,
    /// Edit or Skip stops the countdown (the rep then sends it by hand).
    func startTextCountdown() {
        textTask?.cancel()
        guard autoDial, Aircall.isSetUp else { return }
        textTask = Task { [weak self] in
            var waited = 0
            while let self, !Task.isCancelled, self.waitingForText, self.followUp?.text.isEmpty ?? true, waited < 20 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            for left in stride(from: 5, through: 1, by: -1) {
                guard let self, !Task.isCancelled, self.waitingForText, self.status == .ready,
                      self.followUp?.textEdited != true else { self?.textSendIn = nil; return }
                self.textSendIn = left
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, self.waitingForText, self.status == .ready,
                  self.followUp?.textEdited != true else { self?.textSendIn = nil; return }
            self.textSendIn = nil
            ActivityLog.add("Text: sending by itself after the countdown")
            self.sendFollowUpText()
            // Failsafe: if nothing was sent (no text written, or it couldn't go), move on after 20 s.
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, self.waitingForText, self.status == .ready else { return }
            ActivityLog.problem("Text: nothing went out for \(self.followUp?.prospect ?? "?") after 25 s, moving on to the next person")
            self.waitingForText = false
            self.startNextSequence()
        }
    }

    func stopTextCountdown() {
        textTask?.cancel()
        textTask = nil
        textSendIn = nil
    }

    /// The rep clicked Wait (or moved on by hand).
    func cancelAutoNext() {
        stopTextCountdown()
        hangUpGen += 1
        waitingForText = false
        autoNextName = nil
        readyTask?.cancel()
        gettingReady = nil
        gettingReadyDetail = nil
        autoNextTask?.cancel()
        autoNextTask = nil
        autoNextIn = nil
    }

    func checkAircallForNewCall() {
        aircallTicks += 1
        guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
        aircallCheck = Task { [weak self] in
            let since = self?.endedAt ?? Date()
            let onCall = await Aircall.lineIsOnCall(since: since)
            guard let self else { return }
            self.aircallCheck = nil
            if onCall == true, self.status == .ready, self.waitingForNewCall {
                self.waitingForNewCall = false
                self.startCall()
            }
        }
    }

    /// Between calls: the hang-up button seen on 2 checks in a row (and not just the last call's
    /// button fading out) = a call started on the phone. Start listening.
    func checkPhoneForNewCall() {
        guard phoneButtonCheck == nil, Date().timeIntervalSince(endedAt) > 3 else { return }
        phoneButtonCheck = Task { [weak self] in
            let visible = await AircallPhone.shared.hangUpButtonVisible()
            guard let self else { return }
            self.phoneButtonCheck = nil
            guard self.status == .ready, self.pendingDialSince == nil else { return }
            self.phoneCallSeen = visible == true ? self.phoneCallSeen + 1 : 0
            if self.phoneCallSeen >= 2 {
                self.phoneCallSeen = 0
                self.waitingForNewCall = false
                ActivityLog.add("Call placed on the phone itself: listening")
                self.startCall()
            }
        }
    }

    /// A second, faster signal: the phone's red hang-up button disappears the moment the call ends.
    /// Only trusted after it has been seen once in this call, and gone for 3 checks in a row (about 1.5 s).
    func checkPhoneButton() {
        guard AircallPhone.isOn, phoneButtonCheck == nil else { return }
        phoneButtonCheck = Task { [weak self] in
            let visible = await AircallPhone.shared.hangUpButtonVisible()
            guard let self else { return }
            self.phoneButtonCheck = nil
            guard self.status == .live, let visible else { return }
            if visible { self.phoneSawHangUp = true; self.phoneButtonGone = 0; return }
            guard self.phoneSawHangUp else { return }
            self.phoneButtonGone += 1
            if self.phoneButtonGone >= 3 {
                ActivityLog.add("The phone's hang-up button is gone: the call is over")
                self.endCall()
            }
        }
    }

    func checkAircallEveryFewSeconds() {
        checkPhoneButton()
        aircallTicks += 1
        guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
        // Give Aircall a moment to register a brand-new call before trusting a "no".
        guard Date().timeIntervalSince(callStartedAt) > 5 else { return }
        aircallCheck = Task { [weak self] in
            let onCall = await Aircall.lineIsOnCall()
            guard let self else { return }
            self.aircallCheck = nil
            guard self.status == .live, let onCall else { return }
            if onCall { self.aircallSawCall = true }
            // Trust Aircall's "no call" once it has listed this call, or after 20 s if it never
            // lists it (some setups don't). But never while people are still talking.
            let age = Date().timeIntervalSince(self.callStartedAt)
            let talking = self.lastWordsAt.map { Date().timeIntervalSince($0) < 8 } ?? false
            guard self.aircallSawCall || age > 20, !talking else { self.aircallSaysOver = 0; return }
            self.aircallSaysOver = onCall ? 0 : self.aircallSaysOver + 1
            if self.aircallSaysOver >= 2 {
                ActivityLog.add("Aircall says the call is over")
                self.endCall()
            }
        }
    }

    func startByHand() {
        waitingForNewCall = false
        startedByHand = true
        startCall()
    }

    // MARK: Block timer: 50 minutes of calling, then a 10 minute break

    static let blockLength: TimeInterval = 50 * 60
    static let breakLength: TimeInterval = 10 * 60

    func startBlock() {
        blockStartedAt = Date()
        breakUntil = nil
        ActivityLog.add("Block: 50 minutes started")
    }

    func stopBlock() {
        if breakUntil != nil { autoDial = autoDialBeforeBreak }
        blockStartedAt = nil
        breakUntil = nil
    }

    /// The block ran out (and no call is on): break time. The break ran out: back to calling.
    func checkBlock() {
        if let until = breakUntil {
            if Date() >= until { endBreak() }
            return
        }
        guard let start = blockStartedAt, status == .ready, !dialing,
              Date().timeIntervalSince(start) >= Self.blockLength else { return }
        autoDialBeforeBreak = autoDial
        autoDial = false
        cancelAutoNext()
        breakUntil = Date().addingTimeInterval(Self.breakLength)
        NSSound(named: "Glass")?.play()
        ActivityLog.add("Block: done. 10 minute break")
    }

    /// Skip break, or the break is over: auto dial back on, new block, next call.
    func endBreak() {
        autoDial = autoDialBeforeBreak
        breakUntil = nil
        blockStartedAt = Date()
        ActivityLog.add("Block: break over, calling again")
        if autoDial { startNextSequence() }
    }

    /// Skip to the next person, but never run away: 3 skips in a row with no call stops auto dial
    /// and says why, instead of flipping through the list opening and closing pages.
    func skipNext(why: String) {
        skipsInARow += 1
        if skipsInARow >= 3 {
            ActivityLog.problem("Skipped \(skipsInARow) people in a row (last: \(why)). Auto dial stopped so the app doesn't flip through your list.")
            problem = "Skipped \(skipsInARow) people in a row: \(why). Auto dial stopped. Check the call list settings, then press Next."
            Prefs.autoDial = false
            skipsInARow = 0
            return
        }
        nextLead(dial: Prefs.autoDial)
    }

    func startCall() {
        skipsInARow = 0
        problem = nil
        redialRightAway = false
        autoHungUpThisCall = false
        phoneTreeThisCall = false
        phoneTreeActive = false
        phoneTreeTask?.cancel()
        keysMessage = nil
        guard startAudio() else { return }
        if !leads.isActive { callList.markCurrentCalled() } // so Next skips them today (Chrome list)
        if let key = recordKey() {
            currentAttemptKey = key
            attempts[key, default: 0] += 1
        }
        touchpoints.log(.dial)
        callMessage = nil
        pendingDialSince = nil // this dial is now the live call
        BeepDetector.shared.reset()
        CallTrace.beginCall(lead: calling, attempt: currentAttempts)
        questionTracker = QuestionTracker()
        objectionTracker = ObjectionTracker()
        CoachPrompt.objectionFacts = ""
        CoachPrompt.shownLines = []
        CoachPrompt.saidLines = []
        CoachPrompt.likelyCoveredLines = []
        recentRepChunks = []
        CoachPrompt.lastSaidStage = ""
        repEndpointed = false
        lastEarlyBasis = nil
        earlyDraftsThisTurn = 0
        repWordsAtLastAsk = 0
        repLedIDs = []
        yesBranch = nil
        yesBranchTask?.cancel()
        loggedSystemHash = ""
        logSystemIfChanged() // the full static instructions + script Claude gets this call
        phoneSawHangUp = false
        holdLine = false
        pending = nil
        phoneButtonGone = 0
        CoachPrompt.liveSummary = ""
        CoachPrompt.summaryCoversTurns = 0
        summaryInFlight = false // a summary left from the last call never blocks this one (round 2 #2)
        CoachPrompt.questionFacts = "" // never carry the last call's questions into this one
        doNotCall = false
        timeline = SpeechTimeline()
        CoachPrompt.blockerHints = BlockerBook.hints(campaign.id)
        ActivityLog.add("Call started: \(calling ?? "?") (try \(currentAttempts))")
        ActivityLog.add("Models this call: live lines \(ClaudeClient.displayName(LiveCoach.client("").model)), "
            + "opener \(ClaudeClient.displayName(CoachSpeed.current.client(apiKey: "").model)) (speed: \(CoachSpeed.current.label)), "
            + "voicemail \(ClaudeClient.displayName(CoachSpeed.fastest.client(apiKey: "").model)), "
            + "fixes Haiku 5.5 then Sonnet 5.5")
        if let key = currentAttemptKey { DialHistory.logDial(key) }
        // Calling someone new: the last person's follow-up card goes away.
        if let f = followUp, f.key != nil, f.key != currentAttemptKey { followUp = nil }
        status = .live
        streak = Date().timeIntervalSince(lastDialAt) < 180 ? streak + 1 : 1
        lastDialAt = Date()
        voicemailDropStarted = false
        dropWhyLogged = false
        if let key = currentAttemptKey { outcomeSaved.remove(String(key.prefix(15))) } // a new call: rate it again
        prewarmNext() // get the next person ready while this call rings
        quietTicks = 0
        availability.refresh() // fresh free times for this call
        callOpener = kind == .opener ? openerStyle : nil
        goalHit = false
        goalPending = false
        meetingThisWeek = nil
        sawVoicemail = false
        stagesSeen = []
        callStartedAt = Date()
        heardCallAudio = false
        retargets = 0
        aircallSaysOver = 0
        aircallSawCall = false
        aircallTicks = 0
        journeyStep = 0
        history = Array(history.suffix(1)) // keep the opener as the first line
        historyIndex = nil
        repWordsInCall = 0
        repWordsSinceShown = 0
        offeredTimes = []
        codeByDate = [:]
        nextOffer = []
        screenerActive = false
        openerBeforeScreener = nil
        voicemailActive = false
        badNumberThisCall = false
        mailboxFullShown = false
        followUpThisCall = false
        cancelAutoNext()
        if voicemailScript == nil { prepareVoicemail() }
        firstProspectAt = nil
        lastWordsAt = nil
    }

    /// Stages that only happen with the actual prospect, not a front desk or assistant.
    static let prospectStages: Set<String> = ["Discovery", "Value", "Objection", "Closing", "Goal reached"]

    /// Counts the call that just ended. Picked up = a real person talked (not voicemail, not
    /// only a screener). Conversation = they kept talking: 3+ turns, or 45+ seconds after pickup.
    func logTouchpoints(answered: Bool) {
        if sawVoicemail { touchpoints.log(.voicemail) }
        guard answered else { return }
        touchpoints.log(.pickup)
        NSSound(named: "Tink")?.play() // a soft sound: someone picked up
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        let talked = firstProspectAt.map { Date().timeIntervalSince($0) } ?? 0
        let conversation = prospectTurns >= 3 || talked >= 45
        if conversation { touchpoints.log(.conversation) }
        if goalHit { touchpoints.log(.meeting) }
        // Only a front desk or assistant talked: not the prospect. Keep them on the plan, no checkbox.
        let gatekeeperOnly = stagesSeen.contains("Gatekeeper") && stagesSeen.isDisjoint(with: Self.prospectStages)
        guard let key = currentAttemptKey, !gatekeeperOnly else {
            if gatekeeperOnly { ActivityLog.add("Front desk only for \(calling ?? "?"): stays on the plan, Picked Up Cold Call not checked") }
            return
        }
        DialHistory.logPickup(key) // the prospect picked up: the call plan stops for them
        // A real conversation with the prospect: check "Picked Up Cold Call" in Salesforce.
        guard conversation else {
            ActivityLog.add("Short pickup for \(calling ?? key) (\(prospectTurns) turns, \(Int(talked)) s): Picked Up Cold Call not checked")
            return
        }
        guard Salesforce.objectFor(id: key) != nil else {
            ActivityLog.problem("Couldn't check Picked Up Cold Call for \(calling ?? key): no Salesforce record on screen")
            return
        }
        guard Salesforce.isConnected else {
            ActivityLog.problem("Couldn't check Picked Up Cold Call: Salesforce isn't connected")
            return
        }
        let who = calling ?? key
        Task {
            do {
                try await Salesforce.markPickedUp(key)
                ActivityLog.add("Picked Up Cold Call checked for \(who)")
            } catch {
                ActivityLog.problem("Couldn't check Picked Up Cold Call for \(who): \(error.localizedDescription)")
            }
        }
    }

    /// Clears everything about this prospect and gets the next opener ready.
    func nextCall() {
        // The call is over: the next person starts clean, before their opener is prepared below (round 3).
        doNotCall = false
        pendingAmbiguousOptOut = nil
        if status != .ready {
            // Reached a person = they spoke, and it wasn't a voicemail or only a screener.
            let theySpoke = turns.contains { $0.speaker == .prospect }
            lastCallAnswered = theySpoke && !sawVoicemail && !screenerActive
            logTouchpoints(answered: lastCallAnswered)
        }
        history = []
        historyIndex = nil
        journeyStep = 0
        scoreOpener()
        stopAudio()
        coachTask?.cancel()
        holdTask?.cancel()
        startedByHand = false
        turns = []
        interim = [:]
        uncoached = ""
        latestProspect = ""
        latency = nil
        status = .ready
        if leads.isActive {
            applyLead()
        } else {
            // The call is over: the voicemail (or any mid-call line) goes away and a fresh
            // "when they pick up" opener shows right away, ready for the redial.
            prepareOpener()
            // Read Chrome a moment later, not while Aircall plays the hang-up tone.
            afterHangUp { [weak self] in self?.syncRecord() } // same person: keep their ready voicemail
        }
    }

    /// Runs work 2 seconds after a call ends. Doing it all at the hang-up moment
    /// (Chrome reads, saving, loading the next person) makes Aircall's hang-up tone skip.
    func afterHangUp(_ work: @escaping () -> Void) {
        let gen = hangUpGen
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            // Skip it if the rep already moved on by hand (Next, Redial, Call).
            guard let self, self.status == .ready, self.hangUpGen == gen else { return }
            work()
        }
    }

    /// Scores the call if a real person answered (not voicemail): credits the opener,
    /// then saves it to the Script Lab.
    func scoreOpener() {
        defer { callOpener = nil }
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        // Skip voicemails, no-answers, and calls where only a screener ever talked.
        guard status != .ready, !sawVoicemail, !screenerActive, prospectTurns > 0, let start = firstProspectAt else { return }
        let talk = max(0, (lastWordsAt ?? start).timeIntervalSince(start))
        let score = CallScore.compute(talkSeconds: talk, stages: stagesSeen, goal: goalHit)
        let usedOpener = callOpener.flatMap { $0 == openers.current ? $0 : nil }
        if usedOpener != nil {
            openers.record(score: score, kept: prospectTurns >= 3, goal: goalHit)
        }
        if let key = currentAttemptKey { DialHistory.logTalked(key) }
        let record = CallRecord(
            campaignID: campaign.id, campaignVersion: campaign.version, openerID: usedOpener?.id,
            talkSeconds: talk, prospectTurns: prospectTurns, stages: Array(stagesSeen).sorted(),
            goal: goalHit, score: score
        )
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        lab.add(record, campaign: campaign, transcript: transcript, person: calling)
    }

    func togglePause() {
        if status == .paused {
            if startAudio() { status = .live }
        } else if status == .live {
            stopAudio()
            coachTask?.cancel()
            status = .paused
        }
    }
}
```

## `mac/Sources/ClarityLiveCoach/CoachPrompt.swift`

```swift
import CoachCore
import Foundation

// MARK: - Prompt

enum CoachPrompt {
    static let stages = ["Opener", "Screener", "Gatekeeper", "Voicemail", "Discovery", "Value", "Objection", "Closing", "Goal reached", "Exit"]

    /// Stays byte-for-byte the same for a campaign, so Claude can cache it.
    static func system(for campaign: Campaign) -> String {
        """
        You are a world-class cold calling coach sitting next to a sales rep during a live phone call.
        Only the rep sees what you write; you never speak to the prospect. The rep makes about 100 dials a day
        and can get overwhelmed. Make the next sentence obvious so they can stay calm and present.

        The transcript is labeled Rep and Prospect. It is live speech-to-text, so expect small errors
        ("Claude" is often heard as "cloud" or "clod"). Read words in context.

        How to coach:
        1. One line, \(LineBudget.promptMax) words at most, easy to say out loud on the first read. End with a question unless the line ends the call or copies a script row word for word.
        2. Sound like a confident, friendly human. Plain words, contractions, no jargon, no hype. A short question beats a pitch.
        3. Answer what the prospect just said. Never contradict a need they stated or ask what they already answered.
           A direct question gets a one-sentence answer, then the next question for the stage you're in.
        4. Objections: acknowledge in a few words, then ask a curious question. Never argue.
        5. Never invent a fact, number, client name, price, offer, feature or result. Use only what the campaign gives.
        6. Move toward the campaign objective. Once reached, help the rep confirm details and wrap up. Stop selling.
        7. Two clear no's, a request not to be called, or no fit: help the rep exit politely.
        8. An automated call screener ("say your name and why you're calling"): the rep says only
           "This is [rep's first name] calling for [prospect's first name]." Then waits. Stage: Screener.
        9. If talk is flowing well or the rep is mid-thought, the move is silent.

        The campaign's script leads. Follow its lines and its order, in its words. Go off-script only when you're
        highly confident a different line moves the call toward the objective better (the prospect said something
        the script doesn't cover, or its next line no longer fits). Then write it in the script's voice and get back
        to the script as soon as you can. Everything below fills gaps; it never overrides the script.

        Scripts built as a backbone (output rules, banned words, facts, state, a pick order, and tables of
        ID or Condition / Sounds like / Say / Then): follow them exactly, like a decision tree.
        - The script's output rules, banned words and facts beat everything else in these instructions.
        - Track the script's state from the call so far: line type, stage, whether a problem was named, how many no's.
        - Each turn, walk the pick order and use the first row that matches. "Sounds like" is a meaning match, not
          exact words. Treat the script's transcript noise list as the same word.
        - SAY is that row's Say line word for word, with only the [slots] filled in ([Name], [Firm] or [Company],
          [SDR] = the rep's first name, [Day] [Time] or [SlotA] [SlotB] = the open meeting times below).
          If a slot is unknown, drop it naturally. Never show a bracket.
        - A row whose Say is "Show nothing" or EMPTY, a rule that says to return an empty string, or a
          call-screen/talk-over rule that says show nothing: the move is silent.
        - A row that says "Show <text>" in capitals (like USE NAME DIRECTORY): put that text in SAY.
        - Nothing matches: use the fallback row for the current stage.
        - CUE starts with the row's ID (or its stage, like S3) in brackets, then the row's Then
          (e.g. "[S5 manual 2] then ask how long").
        - STAGE maps the script's stages to the app's: GATE or gatekeeper = Gatekeeper, OPEN or opener = Opener,
          REASON, PROBLEM or the question = Value, PAIN or discovery = Discovery, PLAYBACK and BRIDGE = Discovery,
          any objection row = Objection, ASK = Closing, JOIN and LOCK = Goal reached once a time is picked,
          HANDOFF, exit without a meeting or end = Exit, voicemail = Voicemail, call screen = Screener.
        - Times: only the open meeting times below as [Slot A] [Slot B] [Slot C] [Slot D] (or [Day] [Time]). Never make one up.
        - "Send me info" is not a meeting yes: use the info row, then ask once for a time.

        Getting past a gatekeeper (receptionist, assistant, operator, "who's calling?"), when the script has no
        gatekeeper lines. Adapt the campaign's opener; the goal is to be put through, not to pitch:
        - Sound expected and brief. First name for the prospect, first name for the rep: "Hi, it's Mason for AJ.
          Is AJ around?" Calm, warm, a little informal, like a peer calling a peer.
        - Ask for help, don't sell. Never pitch the gatekeeper. One short, true reason only if asked, tied to the
          prospect's world in the script's words ("It's about how AJ's team handles ops admin. Easy to explain
          once we connect.").
        - "What's this regarding?": the one-line reason, then straight back to the ask: "Could you put me through?"
        - "Are they expecting your call?": honest: "Not yet. Worth a minute of AJ's time, though. Is AJ in?"
        - "They're busy / in a meeting": get the next best thing: their direct line or extension, the best time
          to call, or their email. Use the gatekeeper's name if they gave it.
        - "Send an email": "Happy to. What's the best address for AJ?" then ask when AJ is usually free.
        - Never lie, never claim a relationship or a prior conversation that didn't happen.
        - Use the prospect's name, not "he" or "she", unless the gatekeeper used one first.
        - Once the prospect is on the line: back to the script's opener.

        Cold call method (adapt it to the campaign):
        - Opener: honest that it's a cold call, ask for a few seconds. Calm and slow beats slick.
        - Reason for the call: lead with a problem their peers have, not the product. Then ask if it's true for them.
        - Value (STAGE: Value): one sentence tying the problem they named to what the campaign offers, then a question.
        - Discovery: one question at a time. Follow up on their answer before moving on. Get the cost of the problem in their words: time, money, risk.
        - Keep them talking: repeat their last few words as a question, or name what they seem to feel ("Sounds like that rollout was frustrating").
        - Early objections are usually reflexes, not decisions. Lower the pressure and ask one question. If they repeat it firmly, respect it.
        - Ask for the objective as soon as there is real interest. Don't over-discover. Make it easy: specific, short, low commitment.
        - Use their first name at most once or twice. Silence is fine; don't fill it.
        - Never suggest "Did I catch you at a bad time?" It tests as the worst opener.
        - Never pitch features on a cold call. Earn the next step.
        - "We're all good", "all taken care of", "we're set", "we already have someone": don't accept it and don't exit.
          Acknowledge it warmly, then go straight for a meeting anyway, framed as a free health check or audit of
          their systems: a second set of eyes, no cost, they keep whatever they learn. Use the script's length for
          it if it gives one. For example: "Love that. Most teams who say that still find a few gaps. Worth a free
          health check, so you know for sure?" Then offer two specific times. Only exit if they say no to the health
          check too. If the script has its own line for this, use the script's line.

        Selling AI and automation (when the campaign is about AI):
        Buyers are skeptical and busy. Talk about outcomes in their words, like hours back, cleaner data and more selling time, not about AI itself.
        - "We already use ChatGPT or Copilot": good start. Ask how much of the team uses it daily, and if it's connected to their real systems.
        - "Security, legal or IT won't allow it": very fair. Ask what they'd need to see to be comfortable.
        - "We tried AI and it didn't stick": common. Ask what got in the way. Adoption usually fails on process and habits, not tech.
        - "AI is hype": agree there's a lot of noise. Ask about one boring manual task they'd love to be gone.
        - "We're building it in-house": ask if they're building tools or driving adoption, and what's slower than hoped.
        - "Not a priority": ask what is a priority this quarter. Connect only if there's a real link.
        - "Will it replace my people?": no. It gives them time back for the work they were hired to do.

        Before writing, decide what the talk needs next: what the prospect wants or is worried about, what
        the rep already said in their own words, and the current goal. Then pick ONE move:
        answer (they asked something), clarify (they're confused), discover (learn their situation),
        acknowledge (they shared something; reflect it briefly), objection (handle their concern),
        close (ask for the meeting, or end politely), silent (the rep doesn't need a new line now:
        they're mid-thought, or the line on screen still fits).

        Answer in exactly this format and nothing else:
        MOVE: <answer, clarify, discover, acknowledge, objection, close or silent>
        STAGE: <one of: \(stages.joined(separator: ", "))>
        SAY: <the line the rep should say next>
        CUE: <why, or how to say it, under 10 words>

        For silent, write only:
        MOVE: silent

        \(campaign.promptText)
        """
    }

    static func opener(calling: String?, details: String?, style: Opener?, scriptOpener: String? = nil) -> String {
        guard let style else {
            let given = scriptOpener.map { "The script's opener, exactly as written: \"\($0)\"\n" } ?? ""
            return """
            \(about(calling, details))\(given)The call has not connected yet. Give the opener the rep should say when they pick up.
            Use the script's own opener (above, or the campaign's Opening section, or the first line of the original
            script). Say it the way the script says it: same words, same order, same tone, and nothing in front of it
            (if the script starts "Is this ___?", the line starts "Is this", not "Hi ___, this is ___").
            Fill in the blanks (___, [Name], {first name}) with their first name, the rep's name or the company.
            Then check it against what you know about this person. If a part of the script doesn't fit them, change
            only that part, as little as possible, in the script's voice. For example: the script says "a fellow
            Portland entrepreneur" but they're not in Portland or don't run a business; the script names an industry,
            role or tool that isn't theirs; the script assumes something their Salesforce page contradicts. Never
            invent facts about them. If nothing needs changing, use the script as is. Don't add a pitch or a greeting
            the script doesn't have. Only write a different opener if you're highly confident it serves the script's
            goal better for this person, and keep it as short as the script's.
            CUE: one short delivery tip from the script's tone, plus "(adjusted: <what changed>)" if you changed anything.
            """
        }
        return """
        \(about(calling, details))The call has not connected yet. Write the opener using this proven structure. \
        Keep its wording and shape; only fill in the brackets. [company] is the rep's company from the campaign. \
        [industry] is their industry from the Salesforce facts (like "accounting" or "insurance"); if unknown, drop it ("a few teams"). If the first name is unknown, leave it out naturally. If the rep's name is unknown, write [your name].
        Opener: \(style.template)
        Put the opener's name in the CUE: "\(style.name) opener".
        """
    }

    /// A phone menu is playing. Plan the best route to the owner.
    static func phoneTree(menu: String, calling: String?, details: String?, repSaid: String) -> String {
        """
        \(about(calling, details))The call reached an automated phone menu (phone tree). Everything it has said so far
        (speech-to-text, so expect small errors):
        "\(menu)"
        \(repSaid.isEmpty ? "" : "Keys or words the rep has already used: \(repSaid)\n")
        Goal: reach the person above, or if they're the owner or a decision maker, the fastest route to a live
        person who can put the rep through to them. Pick the highest-leverage option from what the menu actually
        offers. Usually best first: dial by name or the company directory (spell their last name on the keypad:
        2=ABC 3=DEF 4=GHI 5=JKL 6=MNO 7=PQRS 8=TUV 9=WXYZ), their extension if known, an option for the owner,
        management or executive office, then sales (sales lines answer fast and can transfer), then the operator
        (0). Avoid support queues, billing, hours, locations and anything that ends in a voicemail box.
        If the menu hasn't listed its options yet, say to wait for them, and what to listen for.
        If the latest words are clearly a live person, not a recording, start your answer with the line HUMAN,
        then give what the rep should say to them. A receptionist or assistant: the campaign's opener adapted for
        getting through to the person (see "Getting past a gatekeeper"), in the script's voice. The person
        themselves: the script's opener.
        Answer in this format:
        SAY: <the exact keys to press now, or what to say, and why in a few words>
        KEYS: <only the digits to press now, like 3 or 7467 (0-9, * and #); leave empty if the rep should wait or talk>
        CUE: <the backup plan if that doesn't work>
        """
    }

    /// A running summary of the call so far (written in the background every few turns).
    static var liveSummary = ""
    /// How many turns the summary covers; later turns always go word for word.
    static var summaryCoversTurns = 0
    /// What has worked on this call list's common blockers (set at call start).
    static var blockerHints = ""
    /// Open and answered questions, tracked in code (set before each request).
    static var questionFacts = ""
    /// Objections raised, answered, and what the prospect said after (tracked in code).
    static var objectionFacts = ""
    /// Lines already shown to the rep this call, and which of them the rep actually said.
    static var shownLines: [String] = []
    static var saidLines: [String] = []
    /// Shown lines the rep partly said in their own words (a paraphrase): neither confirmed nor "never said".
    static var likelyCoveredLines: [String] = []
    /// The step of the last line the rep actually said (Opener, Discovery, Value...).
    static var lastSaidStage = ""
    /// What the last reply prompt included, for the call trace.
    static var lastContext: [String: Any] = [:]

    /// `turns` are finalized transcript only. `speculative`: `latest` is still-changing partial words
    /// (an early draft), so it's labeled as not final and never written into the call as fact.
    static func reply(turns: [Turn], latest: String, calling: String?, details: String?, style: Opener?, openTimes: String?,
                      speculative: Bool = false, repLed: Bool = false, assumeYes: Bool = false) -> String {
        // Short call (12 turns or fewer, or no summary yet): every finalized turn, word for word.
        // Longer: the summary of everything before, plus the last 10 turns word for word.
        let start = CallMemoryRules.verbatimStart(totalTurns: turns.count, summaryCovers: summaryCoversTurns, hasSummary: !liveSummary.isEmpty)
        let recent = Array(turns[start...].suffix(300))
        var history = recent.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        if recent.count < turns.count { history = "Earlier in the call (summary):\n\(liveSummary)\n\nThe last minute, word for word:\n" + history }
        let repLast = turns.last { $0.speaker == .rep }?.text ?? ""
        lastContext = ["mode": recent.count < turns.count ? "summary + last 10 turns" : "full transcript",
                       "turns_total": turns.count, "turns_verbatim_from": turns.count - recent.count + 1, "turns_verbatim_to": turns.count,
                       "speculative_latest": speculative, "rep_led": repLed, "shown_lines_included": min(shownLines.count, 5)]
        let now = assumeYes
            ? "The rep just asked: \"\(latest)\"\nThe prospect hasn't answered. Write the line for if they say yes. If the rep asked permission to explain, this is the script's next approved pitch, said simply. If it was a discovery question, this is the follow-up to a yes."
            : repLed
            ? "The rep went off script and just said, in their own words: \"\(latest)\"\nThe prospect hasn't answered yet. Give the rep the next line that builds on what they just said."
            : speculative
            ? "The prospect is still talking. Heard so far (partial, may change, not confirmed): \"\(latest)\""
            : "The prospect just said: \"\(latest)\""
        // Facts only: what the rep said is done; a line shown but not said never reached the prospect.
        let said = saidLines.suffix(5).map { "- \($0)" }.joined(separator: "\n")
        let notSaid = shownLines.filter { !saidLines.contains($0) && !likelyCoveredLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
        let partly = likelyCoveredLines.filter { !saidLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
        let shown = (said.isEmpty ? "" : "Coach lines the rep actually said (done, don't repeat):\n" + said + "\n")
            + (partly.isEmpty ? "" : "Coach lines the rep partly covered in their own words (likely done; don't repeat as is):\n" + partly + "\n")
            + (notSaid.isEmpty ? "" : "Coach lines shown but NOT said (the prospect never heard them; the rep chose their own words):\n" + notSaid + "\n")
            + (lastSaidStage.isEmpty ? "" : "The last step the rep actually covered: \(lastSaidStage)\n")
        let opened = style.map { "The rep opened with the \"\($0.name)\" opener: \($0.template)\nGood follow-up for it: \($0.followUp)\n\n" } ?? ""
        let booking = openTimes.map { "\($0)\n\n" } ?? ""
        return """
        \(about(calling, details))\(opened)\(booking)Call so far, oldest first:
        \(history)

        \(repLast.isEmpty ? "" : "The rep's last words: \"\(repLast)\"\n")\(now)
        \(blockerHints.isEmpty ? "" : "\n" + blockerHints + "\n")\(questionFacts.isEmpty ? "" : "\nQuestions on this call (tracked exactly, trust these):\n" + questionFacts + "\n")\(objectionFacts.isEmpty ? "" : "\nObjections on this call (tracked from their words; answered is not the same as resolved):\n" + objectionFacts + "\n")
        \(shown)
        The rep's actual words are the truth; the script is the guide. If the rep already covered something in
        their own words (the reason for the call, the pitch, a question), it's done: never repeat it. Coach from
        where the rep really is toward the next goal of the script.
        If the prospect asked a question, the first sentence answers it plainly and directly.
        What should the rep say next? SAY is 1 to 2 short sentences, \(LineBudget.promptMax) words at most, ending in one question
        (unless the call is ending). Follow the script mostly; if you're sure a different answer breaks through
        better, use it.
        """
    }

    /// Written before the call, so it's ready the instant a voicemail greeting starts.
    static func voicemail(calling: String?, details: String?, earlierTexts: [String] = [], earlierMessages: [String] = [],
                          history: String = "", localLunch: Bool = false) -> String {
        let local = localLunch ? LocalLunch.promptNote : ""
        let past = history.isEmpty ? "" : """
        What the rep has already done with this person:
        \(history)

        """
        let earlierLinkedIn = earlierMessages.isEmpty ? "" : """
        This will be LinkedIn message number \(earlierMessages.count + 1). LinkedIn messages already sent (oldest first):
        \(earlierMessages.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
        The new LINKEDIN MESSAGE must be clearly different from every one of these: a new angle or question and new wording.

        """
        let earlier = earlierTexts.isEmpty ? "" : """
        This will be text number \(earlierTexts.count + 1) to this person. Texts already sent (oldest first):
        \(earlierTexts.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
        The new TEXT must be clearly different from every one of these: a new angle or question and new wording.
        Don't reuse their opening words. Keep it short and friendly; later texts can be lighter (for example,
        a quick "should I stop reaching out?" by the 4th or 5th text).

        """
        return """
        \(about(calling, details))\(past)\(earlier)\(earlierLinkedIn)\(local)If this call goes to voicemail, what should the rep say after the beep?
        One voice for everything you write here. The voicemail, TEXT, LINKEDIN and LINKEDIN MESSAGE all come from
        the campaign above: its opening, its angle, its offer, its tone, and any voicemail, text or LinkedIn wording
        it gives. Follow the campaign over the defaults below whenever they differ.
        Templates come first: if the campaign or its script has a voicemail script, the voicemail is that script
        word for word, with only the blanks and placeholders filled in. If the campaign or its script has a text message template (a missed call text, a text
        after a voicemail, or any text the rep sends), the TEXT line must be that template word for word, with only
        the name, rep and company placeholders filled in (for a later text, use the script's matching follow-up
        template if it has one). Same for LinkedIn: a connection note or request template goes in LINKEDIN word for
        word, a LinkedIn message template goes in LINKEDIN MESSAGE, and with no LinkedIn template, use the text
        template there too. Only write your own when the campaign has no template. Write the voicemail first, then
        make every TEXT and LinkedIn line sound like the same person who just left that voicemail: the same way the
        rep introduces themselves (if the voicemail says something like "a fellow Portland entrepreneur", so do the
        text and LinkedIn note), the same reason for reaching out, the same warmth and plainness. Never switch to
        a different pitch or a more formal, salesy tone in the written follow-ups.
        Voicemail: under 20 seconds, about 40 words. In this order: their first name; the rep's name and how the
        campaign introduces them; one reason tied to the campaign's angle and to something specific about them,
        their role or their company (from the Salesforce facts, or a common pain for their title if there are none);
        then one closing line that fits the history above:
        - No text sent yet: "I'll send you a quick text so you have my number."
        - A text was already sent: don't promise a first text again. Mention it instead, for example
          "I sent you a text the other day, so you have my number" (use the real timing: today, yesterday, a few days ago).
        - A LinkedIn connection request or message was already sent: you can mention it, for example
          "I also sent you a connection request on LinkedIn" (pick the one or two most recent touches, not a list).
        - Voicemails were already left: don't repeat them. New angle and new wording, and it can be shorter and lighter.
        The TEXT, LINKEDIN and LINKEDIN MESSAGE lines below follow the same history: e.g. the text can say
        "left you a voicemail" or "sent you a note on LinkedIn" when that's true.
        No pitch, no hype, no email.
        CUE: one short delivery tip. STAGE: Voicemail.
        Then add three more lines:
        TEXT: <the text message to send right after. Under 40 words. Sounds like a real person texting, not marketing,
        and like the voicemail above. The rep introduces themselves the same way as in the voicemail, then the same
        reason for reaching out (the campaign's angle, tied to their role or company),
        then one easy yes/no question about THEIR situation (e.g. "Is that still a headache for your team?"),
        then one short line saying what happens next, so they know they'll hear from the rep again. Make it true to
        the history: calls left = "I'll try you again tomorrow if I don't hear back." or "I'll send you a note on
        LinkedIn too."; last call = "I won't keep calling. Reach out anytime." Vary the wording each time.>
        LINKEDIN: <a LinkedIn connection request note. Under 200 characters. Same voice and intro as the voicemail.
        Says the rep just tried calling, gives the same reason, no pitch, no links, no emojis.>
        LINKEDIN MESSAGE: <a LinkedIn direct message, for when they're already connected. Under 400 characters.
        Same voice and intro as the voicemail. Says the rep just tried calling, gives the same reason, one easy
        question. No links, no emojis.>
        Rules for the voicemail, TEXT and both LinkedIn lines:
        - Never name anyone they haven't met (no "Oliver", no "my partner", no "our team lead"). They only know the rep.
        - Don't ask for a meeting, a call length or a day in a first touch. Ask about their situation instead.
          Only after earlier texts or voicemails (see the history) can a later one offer a short call, and then as
          a simple question ("Worth a quick chat?"), still without naming anyone else.
        - One idea per message. No jargon, no "quick look at yours", no hype.
        Never copy wording from these instructions; the words come from the campaign.
        """
    }

    /// The Salesforce record the rep had open: the tab title and, if allowed, the page's text.
    private static func about(_ calling: String?, _ details: String? = nil) -> String {
        var lines: [String] = []
        let rep = Prefs.repName
        if !rep.isEmpty {
            lines.append("The rep's first name is \(rep).")
        }
        if let calling {
            lines.append("Salesforce record open in the rep's browser: \(calling). Use the first name if it's a person.")
        }
        if let details {
            lines.append("Text from their Salesforce page. It includes menus and clutter; use only facts about this person and their company, and never guess:\n\(details)")
        } else if calling != nil {
            lines.append("Assume nothing else about them.")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
    }
}
```

## `mac/Sources/ClarityLiveCoach/LiveCoach.swift`

```swift
import CoachCore
import Foundation

/// The live line: Haiku, fast and short, checked in code before it shows.
enum LiveCoach {
    static func client(_ key: String, model: String = "claude-haiku-5-5") -> ClaudeClient {
        var c = ClaudeClient(apiKey: key)
        c.model = model
        c.effort = "low"
        c.maxTokens = 120          // SAY + CUE + STAGE: a 1 to 2 sentence line
        c.idleTimeout = 8
        c.totalTimeout = 15
        if model.contains("haiku") {
            c.thinking = ["type": "disabled"] // this model takes no temperature setting
        } else {
            c.thinking = ["type": "between_tools"] // Sonnet with thinking off
        }
        return c
    }

    // MARK: Opt out, handled in code (no AI)

    static func isOptOut(_ text: String, isFinal: Bool = true) -> Bool { OptOut.matches(text, isFinal: isFinal) }

    static let optOutLine = "Understood. I'll take you off our list right now. Have a good day."

    /// Last resort when a line fails the check twice: smallest safe fix.
    static func sanitize(_ say: String) -> String {
        var s = say.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: ",")
        s = LineRepair.oneQuestion(s)
        return LineRepair.trimToFit(s, max: LineBudget.checkMax) // whole sentences, never a fragment (M7)
    }
}

/// Objections this rep keeps hitting, and the answers that kept the call going. Fed to the live coach
/// on every line, and written into the script's BLOCKERS section every 20 calls.
enum BlockerBook {
    struct Entry: Codable { var objection: String; var response: String; var worked: Bool; var date: Date }

    private static func key(_ campaign: UUID) -> String { "blockers-" + campaign.uuidString }

    static func all(_ campaign: UUID) -> [Entry] {
        (UserDefaults.standard.data(forKey: key(campaign))).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    static func add(_ new: [Entry], campaign: UUID) {
        guard !new.isEmpty else { return }
        let list = Array((all(campaign) + new).suffix(400))
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(campaign))
    }

    /// The top blockers, most common first, each with the answer that worked most often.
    static func top(_ campaign: UUID, limit: Int = 8) -> [(objection: String, count: Int, worked: Int, best: String?)] {
        let groups = Dictionary(grouping: all(campaign)) { $0.objection.lowercased().trimmingCharacters(in: .whitespaces) }
        return groups.map { (_, items) in
            let wins = items.filter(\.worked)
            let best = Dictionary(grouping: wins, by: \.response).max { $0.value.count < $1.value.count }?.key
            return (items[0].objection, items.count, wins.count, best)
        }
        .sorted { $0.count > $1.count }
        .prefix(limit).map { $0 }
    }

    /// For the live coach: what's worked on this call list's blockers so far.
    static func hints(_ campaign: UUID) -> String {
        let list = top(campaign).filter { $0.count >= 2 }
        guard !list.isEmpty else { return "" }
        return "Blockers this rep keeps hitting on this call list, and what kept the call going (use when it fits, in your own words):\n"
            + list.map { b in "- \"\(b.objection)\" (\(b.count) times\(b.best.map { "; worked: \"\($0)\"" } ?? "; nothing has worked yet, try a fresh angle"))" }
                .joined(separator: "\n")
    }

    /// The BLOCKERS section for the script.
    static func section(_ campaign: UUID) -> String? {
        let list = top(campaign, limit: 12).filter { $0.count >= 2 }
        guard !list.isEmpty else { return nil }
        var lines = ["BLOCKERS (learned from your calls, updated every 20 calls)", "ID | Sounds like | Say | Then"]
        for (i, b) in list.enumerated() {
            lines.append("BLK \(i + 1) | \(b.objection) (\(b.count) times, \(b.worked) kept going) | \(b.best ?? "(no winning answer yet)") | back to the last stage question")
        }
        return lines.joined(separator: "\n")
    }
}

extension Notification.Name {
    /// userInfo: "id" (UUID), "section" (String). The app writes it into that call list's script.
    static let blockersUpdated = Notification.Name("blockersUpdated")
}
```

## `mac/Sources/ClarityLiveCoach/Guardrail.swift`

```swift
import CoachCore
import Foundation

/// The house rules for every line the rep reads, checked in code (the model sometimes breaks them).
/// Used on new scripts now; the live coach will use the same check.
enum Guardrail {
    static let banned = ["awesome", "super excited", "beautiful day", "my friend", "brother", "to be honest",
                         "selected", "assigned", "referred", "certified", "replace", "never messes up",
                         "roadmap", "transformation", "maturity", "enablement", "digital"]
    private static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                               "tomorrow", "next week"]

    /// What's wrong with a line, or [] if it's fine.
    /// - long: voicemails, texts and LinkedIn notes may run past 25 words.
    /// - endsCall: the row ends the call, so it needn't end with a question.
    static func problems(_ line: String, long: Bool = false, endsCall: Bool = false, allowTimes: Bool = false) -> [String] {
        let say = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !say.isEmpty, !say.lowercased().hasPrefix("show nothing") else { return [] }
        var out: [String] = []
        let words = say.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if !long, words > LineBudget.checkMax { out.append("\(words) words (max \(LineBudget.checkMax))") }
        let questions = say.filter { $0 == "?" }.count
        if !long, questions > 1 { out.append("more than one question") }
        if !long, !endsCall, !say.hasSuffix("?") { out.append("doesn't end with a question") }
        // All-caps abbreviations, except AI and [slots].
        let noSlots = say.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        let caps = noSlots.matches(#"\b[A-Z]{2,}\b"#).filter { $0 != "AI" }
        if !caps.isEmpty { out.append("abbreviation: " + caps.joined(separator: ", ")) }
        let lower = say.lowercased()
        let hits = banned.filter { lower.contains($0) }
        if !hits.isEmpty { out.append("banned: " + hits.joined(separator: ", ")) }
        if say.contains("$") || say.contains("%") || lower.range(of: #"\d+\s*(dollar|percent)"#, options: .regularExpression) != nil {
            out.append("money or percent")
        }
        if say.contains("\u{2014}") { out.append("em dash") }
        let grade = ReadingLevel.grade(noSlots)
        if grade > ReadingLevel.checkMax {
            out.append(String(format: "reading level grade %.1f (max %.0f): use shorter words and sentences", grade, ReadingLevel.target))
        }
        let timeLike = lower.range(of: #"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)"#, options: .regularExpression) != nil
        if !allowTimes, timeLike || days.contains(where: { noSlots.lowercased().contains($0) }) { out.append("a made-up day or time (use [Slot A])") }
        if lower.contains("show the") || lower.contains("show s") { out.append("an instruction, not a real line") }
        return out
    }

    struct Issue { let id: String; let say: String; let problems: [String] }

    /// Checks every Say line in a backbone script (rows with " | " under a header with a Say column).
    static func lint(script: String) -> [Issue] {
        var issues: [Issue] = []
        var sayCol: Int?
        var thenCol: Int?
        var long = false
        for raw in script.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.contains("VOICEMAIL") || upper.hasPrefix("TEXTS") || upper.hasPrefix("LINKEDIN") { if !line.contains("|") { long = true } }
            else if !line.contains("|"), line == upper, line.count > 2, line.count < 40 { long = false } // a new section title
            guard line.contains("|") else { continue }
            let cols = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if let i = cols.firstIndex(where: { $0 == "Say" || $0 == "Send" }) {
                sayCol = i; thenCol = cols.firstIndex(of: "Then"); continue // a header row
            }
            guard let s = sayCol, cols.count > s else { continue }
            let then = thenCol.flatMap { cols.count > $0 ? cols[$0].lowercased() : nil } ?? ""
            let ends = ["end", "show nothing", "directory", "wait"].contains { then.contains($0) }
            let p = problems(cols[s], long: long, endsCall: ends)
            if !p.isEmpty { issues.append(Issue(id: cols[0], say: cols[s], problems: p)) }
        }
        return issues
    }
}

private extension String {
    func matches(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
```

## `mac/Sources/ClarityLiveCoach/LineGate.swift`

```swift
import Foundation

/// Tracks whether a streaming live line was checked and passed (main actor only).
@MainActor
final class LineGate {
    var checked = false
    var passed = false
}
```

## `mac/Sources/ClarityLiveCoach/Claude.swift`

```swift
import CoachCore
import Foundation

/// Streams one coaching answer from the Claude API. Raw HTTPS: there is no official Swift SDK.
struct ClaudeClient {
    let apiKey: String
    var model = "claude-opus-5-5"
    var effort = "low" // fastest setting that keeps Opus-level quality
    /// Room for the answer (and thinking). Long scripts need much more than a live line.
    var maxTokens = 1500
    /// Give up if nothing arrives for this long (a stuck answer never hangs the app).
    var idleTimeout: TimeInterval = 20
    /// Give up if the whole answer takes longer than this.
    var totalTimeout: TimeInterval = 90
    /// Optional thinking setting. nil = the model's default (Opus 5.5 always thinks).
    var thinking: [String: String]?
    /// Optional sampling temperature (only sent when set).
    var temperature: Double?

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Calls onText with all the text so far, each time more arrives. Cancel the surrounding Task to stop early.
    /// onThinking gets the thinking summary so far, when `thinking` asks for display "summarized".
    func stream(system: String, user: String, onText: @escaping (String) -> Void,
                onThinking: ((String) -> Void)? = nil, onUsage: (([String: Int]) -> Void)? = nil,
                onModel: ((String) -> Void)? = nil) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "output_config": ["effort": effort],
            // The rules and campaign never change during a call, so they are cached.
            "system": [["type": "text", "text": system + "\n\n" + ReadingLevel.rule, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        if let thinking { body["thinking"] = thinking }
        // temperature is left out on purpose: the newest models reject it (error 400).
        if model.hasPrefix("claude-opus") || model.hasPrefix("claude-fable")
            || (model == "claude-sonnet-5-5" && thinking?["type"] != "between_tools") {
            // If a safety check declines, the API retries on a fallback model in the same call.
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = totalTimeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from Claude") }
        guard http.statusCode == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw APIError(message: "Claude error \(http.statusCode): \(text.prefix(300))")
        }

        var full = ""
        var thought = ""
        var usage: [String: Int] = [:]
        defer { if !usage.isEmpty { onUsage?(usage) } }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                full += text
                onText(full)
            } else if type == "content_block_delta", let onThinking,
                      let delta = json["delta"] as? [String: Any],
                      delta["type"] as? String == "thinking_delta",
                      let text = delta["thinking"] as? String {
                thought += text
                onThinking(thought)
            } else if type == "message_start", let m = json["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                // The model that actually answered (differs from the one asked for on a fallback).
                if let served = m["model"] as? String { onModel?(served) }
                // Input side: plain input, cache reads (cheap, fast) and cache writes.
                for k in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] { if let v = u[k] as? Int { usage[k] = v } }
            } else if type == "message_delta", let u = json["usage"] as? [String: Any], let out = u["output_tokens"] as? Int {
                usage["output_tokens"] = out
            } else if type == "error" {
                let error = json["error"] as? [String: Any]
                throw APIError(message: (error?["message"] as? String) ?? "Claude stream error")
            }
        }
    }
}

extension ClaudeClient {
    /// The JSON object in Claude's answer (from the first "{" to the last "}"), or nil.
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    /// Streams the whole answer and returns its JSON object. Throws if it isn't JSON.
    func json(system: String, user: String) async throws -> [String: Any] {
        var text = ""
        try await stream(system: system, user: user) { text = $0 }
        guard let json = Self.jsonObject(in: text) else {
            throw APIError(message: "Claude's answer wasn't in the expected format. Try again.")
        }
        return json
    }
}

extension ClaudeClient {
    /// "claude-haiku-5-5" -> "Haiku 5.5", for the log.
    static func displayName(_ model: String) -> String {
        let parts = model.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let name = parts.first else { return model }
        let version = parts.dropFirst().prefix(2).joined(separator: ".")
        return name.prefix(1).uppercased() + name.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}

/// How the live coach trades polish for speed. Pick in the gear menu.
enum CoachSpeed: String, CaseIterable, Identifiable {
    case best, balanced, fastest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Best lines (a bit slower)"
        case .balanced: return "Fast (best for most people)"
        case .fastest: return "Fastest"
        }
    }

    static var current: CoachSpeed {
        CoachSpeed(rawValue: UserDefaults.standard.string(forKey: PrefKey.coachSpeed) ?? "") ?? .balanced
    }

    func client(apiKey: String) -> ClaudeClient {
        var c = ClaudeClient(apiKey: apiKey)
        c.effort = "low"
        c.idleTimeout = 10 // a live line that stalls is useless; the rep keeps the last one
        c.totalTimeout = 30
        switch self {
        case .best:
            c.model = "claude-opus-5-5" // always thinks; low effort keeps it short
        case .balanced:
            c.model = "claude-sonnet-5-5"
            c.thinking = ["type": "between_tools"] // Sonnet 5.5's way to turn thinking off
        case .fastest:
            c.model = "claude-haiku-5-5"
            c.thinking = ["type": "disabled"]
        }
        return c
    }
}
```

## `mac/Sources/ClarityLiveCoach/Deepgram.swift`

```swift
import Foundation

/// One live transcription stream (one side of the call). We open two: you and the prospect.
/// Separate streams mean we always know who said what.
final class DeepgramStream: @unchecked Sendable {
    enum Event {
        case transcript(text: String, isFinal: Bool, speechFinal: Bool, start: Double, duration: Double, confidence: Double)
        case utteranceEnd
        case failed(String)
    }

    // Tuned for speed: 300 ms of silence ends a statement, words stream as they are heard.
    private static let params = [
        "model=nova-3", "encoding=linear16", "sample_rate=16000", "channels=1",
        "interim_results=true", "endpointing=300", "utterance_end_ms=1000",
        "vad_events=true", "smart_format=true",
    ]

    /// Words the transcriber should expect, so "Claude" isn't heard as "cloud".
    static let defaultKeyterms = ["Claude", "Anthropic", "Clarity", "Salesforce", "Aircall", "RevOps", "CRM", "Agentforce"]

    private static func url(keyterms: [String]) -> URL {
        let terms = keyterms.compactMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }.map { "keyterm=\($0)" }
        return URL(string: "wss://api.deepgram.com/v1/listen?" + (params + terms).joined(separator: "&"))!
    }

    private let task: URLSessionWebSocketTask
    private let onEvent: (Event) -> Void
    private let lock = NSLock()
    private var lastSend = Date()
    private var keepAlive: DispatchSourceTimer?
    private var closed = false
    private var audioSent = 0.0       // seconds of audio sent so far (Deepgram's clock)
    private var origin: Date?         // wall time of Deepgram's audio second 0

    /// Wall time of the audio at Deepgram second `t`, so both sides share one clock.
    /// Estimated from sends: a chunk can be sent late but never before it was captured, so the
    /// earliest (send time - audio sent) is the best origin. A gap in sending (audio paused) moves it on.
    func wallTime(audioSeconds t: Double) -> Date? {
        lock.withLockValue { origin.map { $0.addingTimeInterval(t) } }
    }

    init(apiKey: String, keyterms: [String] = [], onEvent: @escaping (Event) -> Void) {
        var request = URLRequest(url: Self.url(keyterms: keyterms))
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        self.onEvent = onEvent
        task.resume()
        receive()

        // Deepgram closes idle streams after ~10 s. Keep it open during silence.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLockValue { Date().timeIntervalSince(self.lastSend) > 4 }
            if idle { self.task.send(.string(#"{"type":"KeepAlive"}"#)) { _ in } }
        }
        timer.resume()
        keepAlive = timer
    }

    func send(_ pcm16: Data) {
        lock.withLockValue {
            let now = Date()
            lastSend = now
            audioSent += Double(pcm16.count) / 32000 // 16 kHz, 16-bit mono
            let estimate = now.addingTimeInterval(-audioSent)
            if let o = origin, estimate.timeIntervalSince(o) < 0.5 { origin = min(o, estimate) } else { origin = estimate }
        }
        task.send(.data(pcm16)) { _ in }
    }

    func close() {
        let wasClosed = lock.withLockValue { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        keepAlive?.cancel()
        task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [task] in
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            case .failure(let error):
                let wasClosed = self.lock.withLockValue { self.closed }
                if !wasClosed { self.onEvent(.failed(error.localizedDescription)) }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "Results":
            let channel = json["channel"] as? [String: Any]
            let alternative = (channel?["alternatives"] as? [[String: Any]])?.first
            let transcript = (alternative?["transcript"] as? String) ?? ""
            onEvent(.transcript(
                text: transcript,
                isFinal: (json["is_final"] as? Bool) ?? false,
                speechFinal: (json["speech_final"] as? Bool) ?? false,
                start: (json["start"] as? Double) ?? 0,
                duration: (json["duration"] as? Double) ?? 0,
                confidence: (alternative?["confidence"] as? Double) ?? 0
            ))
        case "UtteranceEnd":
            onEvent(.utteranceEnd)
        default:
            break
        }
    }
}

extension NSLock {
    func withLockValue<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
```

## `mac/Sources/ClarityLiveCoach/CallTrace.swift`

```swift
import AppKit
import Foundation

/// One structured, millisecond-accurate timeline per call, for an AI (or a person) to reconstruct
/// exactly what happened and why. JSON Lines: one event per line, written in the background so it
/// never slows the coach.
///
/// Every event has:
///   seq          order within the call
///   wall         wall-clock time, ms precision (for matching against other services' logs)
///   t_ms         monotonic ms since the call started (use this for latency math)
///   call         call ID;  turn: transcript turn number;  req: Claude request ID;
///   sug: suggestion ID (= the request ID that made it);  mem: memory version (call summary)
///   type         what happened (see Export README for the full list)
///   data         the actual inputs, outputs and the reason for the decision
///
/// Files: ~/Library/Logs/ClarityLiveCoach/calls/<date>/<time>-<call>.jsonl
/// Phone numbers are masked. Transcripts are kept (they stay on this Mac).
@MainActor
enum CallTrace {
    nonisolated private static let queue = DispatchQueue(label: "clarity.call-trace", qos: .utility)
    private static var file: URL?
    private static var start = ContinuousClock.now
    private static var seq = 0
    static private(set) var callID = ""
    static var turn = 0
    static var memVersion = 0
    static private(set) var lastFile: URL?

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClarityLiveCoach/calls", isDirectory: true)
    }

    static func beginCall(lead: String?, attempt: Int) {
        callID = String(UUID().uuidString.prefix(8))
        start = .now
        seq = 0
        turn = 0
        memVersion = 0
        let day = Date().formatted(.iso8601.year().month().day())
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        let dir = folder.appendingPathComponent(day, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("\(f.string(from: Date()))-\(callID).jsonl")
        lastFile = file
        event("call.start", ["lead": lead ?? "?", "attempt": attempt])
    }

    static func endCall(_ data: [String: Any]) {
        event("call.end", data)
        file = nil
    }

    /// Logs one event. Values must be JSON types (String, numbers, Bool, arrays, dictionaries).
    static func event(_ type: String, _ data: [String: Any] = [:], req: Int? = nil, sug: Int? = nil) {
        guard let file else { return }
        seq += 1
        let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
            + Double((ContinuousClock.now - start).components.seconds) * 1000
        var row: [String: Any] = [
            "seq": seq, "wall": Self.wall.string(from: Date()), "t_ms": Int(ms.rounded()),
            "call": callID, "turn": turn, "mem": memVersion, "type": type, "data": mask(data),
        ]
        if let req { row["req"] = req }
        if let sug { row["sug"] = sug }
        queue.async {
            guard let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(line); h.write(Data("\n".utf8)); try? h.close()
            } else {
                try? (line + Data("\n".utf8)).write(to: file)
            }
        }
    }

    private static let wall: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"; return f
    }()

    private static func mask(_ d: [String: Any]) -> [String: Any] {
        d.mapValues { v in (v as? String).map(ActivityLog.mask) ?? v }
    }

    // MARK: Export

    /// Builds an AI-readable bundle for the last call (or a given trace): the trace, a README that
    /// explains every event and points at the code, and the activity log around it. Opens the folder.
    static func exportLast() {
        queue.sync {} // write every pending event first, so the end of the call is in the copy (M5)
        guard let src = lastFile ?? latestTrace() else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Clarity Call Diagnostics/\(f.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("trace.jsonl"))
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? ActivityLog.recent(lines: 600).write(to: dir.appendingPathComponent("activity-log.txt"), atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(dir)
    }

    private static func latestTrace() -> URL? {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for d in days {
            if let f = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first { return f }
        }
        return nil
    }

    static let readme = """
    # Clarity Live Coach: call diagnostic bundle

    Give this folder to an AI and ask it to find the root cause of slow or poor coaching.

    ## Files
    - trace.jsonl: one JSON event per line, in order. The complete timeline of one call.
    - activity-log.txt: the app's plain log around this call (other calls too).

    ## Fields on every event
    seq (order), wall (clock time, ms), t_ms (ms since call start, monotonic: use for latency),
    call (call ID), turn (transcript turn #), req (Claude request #), sug (suggestion # = its request #),
    mem (call-summary version the coach knew), type, data.

    ## Event types (and where they come from in the code: mac/Sources/ClarityLiveCoach/)
    - call.start / call.end: CoachModel+Call.swift startCall / endCall
    - speech.start: first words of a speaker after a pause (transcript arrival time) (CoachModel+Audio.swift handle)
    - transcript.partial / transcript.final: every Deepgram result. data.audio_start / audio_end are the
      times INSIDE the audio stream (Deepgram's clock, seconds since that stream opened), separate from t_ms
      (when the app received it). data.confidence, data.speech_final. (Deepgram.swift, CoachModel+Audio.swift)
    - turn.end: Deepgram said the speaker finished (speech_final or UtteranceEnd)
    - intent: what the code detected in the prospect's words and why (voicemail, screener, phone tree,
      opt out, bad number, objection match) (CoachModel+Audio.swift, LiveCoach.swift, Screener.swift)
    - script.match: approved-answer lookup: searched (row count), matched (row ID, phrase) or none
      (CoachCore ScriptAnswers, CoachModel+Lines.swift instantAnswer)
    - claude.request: model, settings, the exact system prompt size and hash, the exact user message
      (all context Claude got), early (started before they finished) (CoachModel+Lines.swift ask)
    - claude.first_token / claude.done (full raw output, ms) / claude.error / claude.cancelled
    - check.fail / check.fixed / check.trimmed: the code check on each line (Guardrail.swift, fixLine)
    - memory.update: the call summary Haiku keeps (new version, the text, which turns it covers)
    - suggestion.shown / suggestion.queued / suggestion.discarded / suggestion.promoted: what the rep saw,
      with the reason (CoachMachine.canReplace in CoachCore)
    - delivery: the rep said the line's meaning (confidence 0..1, what they said) (CoachCore Delivery)
    - resolution: the prospect answered after delivery
    - state: screen state change (Listening, Ready, Reading, Delivering, Interrupted, Resolved, Outdated, Idle)
    - manual: Hold, Release, Next, Different line
    - question.asked / question.answered / question.interrupted / question.abandoned: tracked in code (CoachCore
      QuestionTracker) from finished turns; the open/answered list is sent to Claude as facts (see user_message)
    - early.used / early.wasted: whether a draft started before they finished was the one used (proves generating ahead)
    - context.system: the full static instructions + script Claude had for this call (once per call)
    - log: every plain activity-log line during the call, for context

    ## Latency to compute
    speech end (turn.end) -> claude.request -> claude.first_token -> claude.done -> suggestion.shown;
    turn.end -> suggestion.shown is what the rep feels. transcript audio_end vs t_ms shows transcription delay.

    ## Not captured
    Claude's hidden reasoning (thinking is off for live lines). Call audio (only saved with the separate,
    consented voicemail samples and audio debug features).
    """
}
```

## `mac/Sources/ClarityLiveCoach/Screener.swift`

```swift
import Foundation

/// Spots automated call screeners (iPhone, Google Call Screen, carrier screening) and
/// "who's calling?" gatekeepers from the prospect's words, instantly and without Claude.
enum Screener {
    private static let phrases = [
        "screening service", "call screen", "screening this call", "being screened", "screening calls",
        "person you're trying to reach",
        "say your name", "state your name", "record your name", "speak your name",
        "your name and why", "your name and the reason", "reason for your call", "reason for calling",
        "why you're calling", "why you are calling", "what you're calling about", "what this call is about",
        "google assistant", "stay on the line", "before i connect you", "see if this person is available",
        "may i ask who's calling", "may i ask who is calling", "who's calling please", "who is calling please",
        "may i tell them who's calling", "and your name",
    ]

    static func detects(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return phrases.contains { t.contains($0) }
    }

    /// "This is Mason calling for Jane."
    static func line(calling: String?) -> String {
        let rep = Prefs.repName
        return "This is \(rep.isEmpty ? "[your name]" : rep) calling for \(firstName(calling) ?? "[their name]")."
    }

    /// The full name from a record like: Lead "Jane Doe" -> Jane Doe. Any record type.
    static func fullName(_ calling: String?) -> String? {
        guard let calling, let open = calling.firstIndex(of: "\"") else { return nil }
        let rest = calling[calling.index(after: open)...]
        let inside = rest.lastIndex(of: "\"").map { rest[..<$0] } ?? rest
        let name = inside.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// First name from a record like: Lead "Jane Doe". People only, not companies.
    static func firstName(_ calling: String?) -> String? {
        guard let calling,
              ["Lead", "Contact", "Person Account"].contains(where: { calling.hasPrefix($0) }),
              let open = calling.firstIndex(of: "\""),
              let name = calling[calling.index(after: open)...].split(separator: " ").first else { return nil }
        let first = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // "Unknown" is a placeholder, not a name: callers fall back to "there".
        return first.isEmpty || Salesforce.isPlaceholderName(first) ? nil : first
    }
}

/// Spots voicemail greetings and full mailboxes from the prospect's words, instantly.
/// Strong phrases count any time. Early phrases ("you've reached", "not available") only count
/// at the start of a call before the rep has spoken, when it can't be a gatekeeper answering a question.
enum Voicemail {
    private static let strong = [
        "leave a message", "leave your message", "leave me a message", "leave a voicemail", "leave a brief message",
        "leave your name", "message after", "after the tone", "after the beep", "at the tone", "at the beep",
        "voicemail", "voice mail", "mailbox", "record your message", "please leave", "can't take your call",
        "cannot take your call", "can not take your call", "not available to take your call", "can't come to the phone",
        "cannot come to the phone", "get back to you as soon as", "return your call", "forwarded to an automated",
        "automated voice", "voice messaging", "is not available. please", "sorry i missed your call",
        "sorry i can't answer", "sorry i cannot answer", "missed your call",
        // Straight to voicemail and carrier recordings
        "record your message", "please record", "when you have finished recording", "when you're finished recording",
        "when you are finished recording", "finished recording", "press pound", "hang up or press", "for more options",
        "at the sound of the tone", "after the signal", "voice mailbox", "has a mailbox", "has been forwarded",
        "your call has been forwarded", "forwarded to voicemail", "is not accepting calls", "is not available to take",
        "this is the voicemail", "reached the voicemail", "reached the mailbox", "leave your number",
        "leave a detailed message", "leave your contact", "leave a short message", "leave a quick message",
        "i'll call you back", "i will call you back", "i'll get back to you", "i will get back to you",
        "call you back as soon", "get back to you shortly", "sorry i missed you", "sorry we missed your call",
        "can't take your call", "unable to take your call", "google subscriber", "the subscriber you",
        "the party you are trying", "the customer you are calling", "please try your call again",
        "please try again later", "send a numeric page", "to page this person",
    ]
    private static let early = [
        "you've reached", "you have reached", "not available", "unavailable", "unable to answer", "unable to take",
        "can't get to the phone", "can't answer", "away from my desk", "away from the phone", "out of the office",
        "subscriber", "wireless customer", "the person you are trying", "the person you're trying",
        "the number you have dialed", "is not reachable",
        "i'm not available right now", "i am not available right now", "not available right now",
    ]
    private static let fullPhrases = [
        "mailbox is full", "mailbox full", "cannot accept any messages", "not accepting messages",
        "has not been set up", "hasn't been set up", "not set up yet",
    ]

    /// - Parameter earlyInCall: true in the first seconds after pickup, before the rep has said anything.
    static func detects(_ text: String, earlyInCall: Bool) -> Bool {
        contains(text, strong) || mailboxFull(text) || (earlyInCall && contains(text, early))
    }

    static func mailboxFull(_ text: String) -> Bool { contains(text, fullPhrases) }

    /// Words only a recording says, never a person who picked up. Used to hang up a 1st-try
    /// voicemail by itself. Kept short on purpose: anything a live person might say is left out.
    private static let certainPhrases = [
        "after the tone", "after the beep", "at the tone", "at the beep", "at the sound of the tone",
        "after the signal", "record your message", "please record", "when you have finished recording",
        "when you're finished recording", "when you are finished recording", "voice mailbox", "forwarded to voicemail", "forwarded to an automated",
        "your call has been forwarded", "reached the voicemail", "this is the voicemail", "reached the mailbox",
        "google subscriber", "the subscriber you", "the party you are trying", "the customer you are calling",
        "send a numeric page", "to page this person",
    ]

    /// The beep is coming: only a mailbox says these (a phone menu doesn't).
    private static let recordingPhrases = [
        "after the tone", "after the beep", "at the tone", "at the beep", "at the sound of the tone",
        "after the signal", "record your message", "please record", "finished recording",
    ]
    static func recordingPrompt(_ text: String) -> Bool { contains(text, recordingPhrases) }

    /// True only when it's surely a recording (see `certainPhrases`), or the mailbox is full.
    static func certain(_ text: String) -> Bool {
        contains(text, certainPhrases) || mailboxFull(text) || numberCantTakeCall(text)
    }

    /// The carrier's "The telephone number 205 441 3049 can't take your call now." Fuzzy: a number
    /// (digits are dropped, so spoken or written both work), then within a few words "can't take your call".
    static func numberCantTakeCall(_ text: String) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(zero|oh|one|two|three|four|five|six|seven|eight|nine)\b"#, with: " ", options: .regularExpression)
        let pattern = #"\b(telephone|phone|number|caller|subscriber)\b(\s+\w+){0,6}?\s+"#
            + #"(cant|can not|cannot|unable to|isnt able to|is not able to|not able to)\s+(take|answer|accept)\s+(your|the|this)?\s*call"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// Sure enough it's a recording to hang up now, without waiting for "after the beep" at the end
    /// of the greeting. Returns why (for the log), or nil. The rep hasn't spoken yet (caller checks).
    /// - Any time: words only a machine says (`certain`).
    /// - Early in the call, nobody screening: a voicemail phrase ("you've reached Jane's voicemail",
    ///   "can't take your call", "leave a message"), or 18+ words with no pause for a reply,
    ///   or "you've reached" / "not available" plus 12+ words.
    static func hangUpReason(_ recent: String, firstWords: String, earlyInCall: Bool) -> String? {
        if certain(recent) { return "beep words" }
        guard earlyInCall, !Screener.detects(firstWords), !Screener.detects(recent) else { return nil }
        if contains(recent, strong) { return "voicemail words" }
        if longGreeting(firstWords, earlyInCall: true) { return "long greeting" }
        if contains(recent, early), firstWords.split(separator: " ").count >= 12 { return "greeting words" }
        return nil
    }

    /// After a call screener (Google, iPhone): the screener says the person won't take it.
    /// Fuzzy, since the words vary and transcripts drop or mangle some:
    /// "I'm sorry, this person is not available", "the person you're calling isn't available right now",
    /// "sorry, they can't take your call", "this person's unavailable", "they declined".
    /// A person (or "they") followed within a few words by a "can't take it" phrase.
    static func unavailableAfterScreen(_ text: String) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z ]+"#, with: " ", options: .regularExpression)
        let pattern = #"\b(person|persons|party|they|theyre|user|customer|caller)\b(\s+\w+){0,6}?\s+"#
            + #"(not available|unavailable|isnt available|not able to (take|answer|come)|cant (take|answer|come|get)|"#
            + #"cannot (take|answer|come|get)|unable to (take|answer|come)|not taking calls|declined|busy right now)"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// Real people answer short ("Hello?", "This is Jane"). A recording talks on and on.
    /// 18+ words before the rep says anything, early in the call = a voicemail greeting.
    static func longGreeting(_ text: String, earlyInCall: Bool) -> Bool {
        earlyInCall && text.split(separator: " ").count >= 18
    }

    private static func contains(_ text: String, _ list: [String]) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return list.contains { t.contains($0) }
    }
}


/// Spots carrier messages for numbers that don't work, so the app skips them instead of
/// leaving a voicemail or offering a redial.
enum BadNumber {
    private static let phrases = [
        "not in service", "no longer in service", "is not in service", "been disconnected",
        "is disconnected", "not a working number", "is not working", "cannot be completed as dialed",
        "can not be completed as dialed", "could not be completed", "call cannot be completed",
        "check the number and dial again", "check the number and try again", "please check the number",
        "not a valid number", "invalid number", "number is invalid", "number you have dialed is not",
        "number you dialed is not", "has been changed", "temporarily out of service", "is not available for calls",
        "does not accept calls", "is restricted", "not accepting calls at this time",
        // "Can't receive calls" and other carrier refusals
        "cannot receive calls", "can't receive calls", "can not receive calls", "unable to receive calls",
        "not able to receive calls", "is not able to receive", "cannot accept calls", "can't accept calls",
        "is not accepting calls", "not accepting incoming calls", "calling restrictions", "has restricted",
        "has been restricted", "no longer available", "cannot be reached", "can't be reached",
        "is not reachable at this", "call cannot be completed at this time", "your call cannot be completed",
        "your call could not be completed", "not been completed", "has been suspended", "is suspended",
        "number has been disconnected", "is no longer a working", "not a valid phone number",
        "does not exist", "doesn't exist", "do not exist", "try your call again",
        "please hang up and try again", "hang up and dial again", "is not assigned",
        "not been assigned", "unassigned number",
    ]

    static func detects(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return phrases.contains { t.contains($0) }
    }
}


/// Spots an automated phone menu ("press 1 for sales", "dial by name"). The rep doesn't work
/// those: the app hangs up and takes the person off the list.
enum PhoneTree {
    /// One of these is enough: only a phone menu says them.
    private static let strong = [
        "menu options have changed", "listen carefully as our", "dial by name", "company directory",
        "your party's extension", "party's extension", "if you know the extension", "if you know your party",
        "para español", "para espanol", "main menu", "make a selection", "please select from the following",
        "say or press", "press or say", "to repeat these options", "for all other inquiries", "for all other calls",
    ]
    /// Two of these together, one of them "press ...": "press 1 for sales, press 2 for billing".
    private static let weak = [
        "press 1", "press one", "press 2", "press two", "press 3", "press three", "press 4", "press four",
        "press 9", "press nine", "press 0", "press zero", "for sales", "for billing", "for customer service",
        "for support", "for accounts", "to speak with an operator", "to speak to an operator", "operator",
        "extension", "our hours are", "business hours",
    ]

    static func detects(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if strong.contains(where: { t.contains($0) }) { return true }
        // Two menu phrases, and at least one is "press ..." (a live receptionist never says that).
        let hits = weak.filter { t.contains($0) }
        return hits.count >= 2 && hits.contains { $0.hasPrefix("press") }
    }
}
```

## `mac/Tests/CoachCoreTests/CoachCoreTests.swift`

```swift
import XCTest
@testable import CoachCore

final class CoachCoreTests: XCTestCase {
    func sig(line: Bool = true, prospect: Bool = false, rep: Bool = false, shown: Double = 5, started: Bool = false,
             delivered: Bool = false, answered: Bool = false, queued: Bool = false, newTopic: Bool = false, words: Int = 0,
             overlap: Bool = false, onLine: Bool = true, dnc: Bool = false) -> CoachSignals {
        CoachSignals(hasLine: line, prospectSpeaking: prospect, repSpeaking: rep, secondsSinceShown: shown, repStarted: started,
                     delivered: delivered, prospectAnsweredSince: answered, queued: queued, queuedIsForNewTopic: newTopic,
                     lineWords: words, overlapping: overlap, repOnLine: onLine, doNotCall: dnc)
    }

    // Silent reading: a 20-word line is protected for ~5 s even with nobody speaking.
    // An unstarted line never times out: only something new from the prospect replaces it.
    func testUnstartedLineNeverTimesOut() {
        XCTAssertFalse(CoachMachine.canReplace(sig(shown: 60, words: 20)))
        XCTAssertFalse(CoachMachine.canReplace(sig(shown: 3, newTopic: true, words: 20))) // H2: a 20-word line needs ~5 s
        XCTAssertTrue(CoachMachine.canReplace(sig(shown: 5.5, newTopic: true, words: 20)))
    }

    // Started but not delivered, and the prospect hasn't moved on: keep it.
    func testStartedLineKeptUntilDeliveredOrMovedOn() {
        XCTAssertFalse(CoachMachine.canReplace(sig(started: true)))
        XCTAssertTrue(CoachMachine.canReplace(sig(started: true, delivered: true)))
    }

    // Asking is not the same as being answered.
    func testDeliveryAndResolutionSeparate() {
        XCTAssertEqual(CoachMachine.state(sig(started: true, delivered: true, answered: false)), .reading)
        XCTAssertEqual(CoachMachine.state(sig(started: true, delivered: true, answered: true)), .resolved)
    }

    // Both talking at once.
    func testOverlap() {
        XCTAssertEqual(CoachMachine.state(sig(prospect: true, rep: true, overlap: true)), .interrupted)
        XCTAssertFalse(CoachMachine.canReplace(sig(prospect: true, rep: true, queued: true, newTopic: true)))
    }

    // Never cut off the rep.
    func testNeverReplaceWhileRepSpeaks() {
        XCTAssertFalse(CoachMachine.canReplace(sig(rep: true, started: true, queued: true, newTopic: true)))
        XCTAssertEqual(CoachMachine.state(sig(rep: true, started: true)), .delivering)
    }

    func testProtectsFirstMomentOfReading() {
        XCTAssertFalse(CoachMachine.canReplace(sig(shown: 0.4, newTopic: true)))
        XCTAssertTrue(CoachMachine.canReplace(sig(shown: 2, newTopic: true)))
    }

    func testInterruptionFlagsOutdatedWithoutReplacingMidSentence() {
        XCTAssertEqual(CoachMachine.state(sig(prospect: true, rep: true, started: true, overlap: true)), .interrupted)
        XCTAssertEqual(CoachMachine.state(sig(started: true, queued: true, newTopic: true)), .superseded)
        XCTAssertTrue(CoachMachine.canReplace(sig(started: true, queued: true, newTopic: true)))
        // Flagged, but never swapped while the rep is still mid-sentence.
        XCTAssertFalse(CoachMachine.canReplace(sig(rep: true, started: true, queued: true, newTopic: true)))
    }

    func testResolvedAfterDeliveryAndAnswer() {
        XCTAssertEqual(CoachMachine.state(sig(started: true, delivered: true, answered: true)), .resolved)
        XCTAssertEqual(CoachMachine.state(sig(line: false)), .idle)
    }

    // Stale answers never overwrite newer ones.
    func testOutOfOrderResponsesDropped() {
        XCTAssertFalse(CoachMachine.isFresh(requestID: 4, latestID: 5))
        XCTAssertTrue(CoachMachine.isFresh(requestID: 5, latestID: 5))
    }

    // Paraphrase counts as delivery.
    func testParaphraseDelivered() {
        let line = "That makes sense. How much time does your team spend updating Salesforce after calls?"
        XCTAssertTrue(Delivery.delivered(line: line, spoken: "Got it, so roughly how much time is your team spending updating Salesforce after each call?"))
        XCTAssertFalse(Delivery.delivered(line: line, spoken: "Okay great, thanks for that."))
    }

    // Known objections answered instantly from the script.
    func testScriptObjectionMatch() {
        let script = """
        OBJECTIONS
        ID | Sounds like | Say | Then
        OBJ email | "send me an email", "just email me" | Happy to. What should it cover so it isn't generic? | back
        OBJ not interested | "not interested", "no thanks" | Fair enough. Is it the timing, or is the system working fine? | no_count +1
        """
        let a = ScriptAnswers(script: script)
        XCTAssertEqual(a.match("Look, can you just email me something?")?.id, "OBJ email")
        XCTAssertEqual(a.match("I'm really not interested")?.id, "OBJ not interested")
        XCTAssertNil(a.match("We use Salesforce for everything"))
    }
}

final class QuestionTrackerTests: XCTestCase {
    func testAskedThenAnswered() {
        var t = QuestionTracker()
        _ = t.add(turn: "How many reps are on the team?", from: .rep)
        let c = t.add(turn: "About twelve.", from: .prospect)
        XCTAssertEqual(t.questions.first?.status, .answered)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(t.promptText.contains("never ask again"))
    }

    func testUhHuhIsNotAnAnswer() {
        var t = QuestionTracker()
        _ = t.add(turn: "Who handles the CRM?", from: .rep)
        _ = t.add(turn: "Mhm", from: .prospect)
        XCTAssertEqual(t.questions.first?.status, .open)
    }

    func testInterruptedAndAbandoned() {
        var t = QuestionTracker()
        _ = t.add(turn: "Is that you guys?", from: .rep)
        _ = t.add(turn: "Wait who is this", from: .prospect, overlapped: true)
        XCTAssertEqual(t.questions.first?.status, .interrupted)
        _ = t.add(turn: "Sorry, quick one. Do you use Salesforce?", from: .rep)
        XCTAssertEqual(t.questions.first?.status, .abandoned)
        XCTAssertEqual(t.questions.last?.status, .open)
    }

    func testProspectQuestionStaysOpenUntilRepAnswers() {
        var t = QuestionTracker()
        _ = t.add(turn: "What does it cost?", from: .prospect)
        XCTAssertTrue(t.promptText.contains("NOT yet answered"))
        _ = t.add(turn: "The health check is free.", from: .rep)
        XCTAssertEqual(t.questions.first?.status, .answered)
    }
}
```

## `mac/Tests/CoachCoreTests/MoveAndFinishTests.swift`

```swift
import XCTest
@testable import CoachCore

final class MoveAndFinishTests: XCTestCase {
    func testMoveParsed() {
        XCTAssertEqual(Move.parse("MOVE: answer"), .answer)
        XCTAssertEqual(Move.parse("MOVE: Discover"), .discover)
        XCTAssertEqual(Move.parse("MOVE: handle objection"), .objection)
        XCTAssertEqual(Move.parse("MOVE: silent"), .silent)
        XCTAssertNil(Move.parse("SAY: hello"))
    }

    // The transcriber's end-of-speech call ends the turn right away: no 1.5 s wait.
    func testEndpointFirst() {
        XCTAssertFalse(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "We help sales teams.",
                                            secondsSinceFinal: 0.4, inFallbackWindow: true))
        // No end-of-speech call yet: the window is the fallback.
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: false, endpointed: false, lastFinal: "We help sales teams.",
                                           secondsSinceFinal: 0.4, inFallbackWindow: true))
        // A hanging sentence holds even after an end-of-speech call (a breath mid-thought), up to 3 s.
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "take notes and keep",
                                           secondsSinceFinal: 1.7, inFallbackWindow: false))
        XCTAssertFalse(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "take notes and keep",
                                            secondsSinceFinal: 3.2, inFallbackWindow: false))
        // Words in the air always win.
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: true, endpointed: true, lastFinal: "Done.", secondsSinceFinal: 0, inFallbackWindow: false))
    }
}
```

## `mac/Tests/CoachCoreTests/ObjectionTrackerTests.swift`

```swift
import XCTest
@testable import CoachCore

final class ObjectionTrackerTests: XCTestCase {
    func testAddressedIsNotResolved() {
        var t = ObjectionTracker()
        _ = t.add(turn: "We already use a partner for that.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .raised)
        _ = t.add(turn: "Totally fair, how's that going for your reps?", from: .rep, turn: 4)
        XCTAssertEqual(t.objections.first?.status, .addressed) // the rep's answer alone never resolves it
    }

    func testResolvedOnlyFromProspectEvidence() {
        var t = ObjectionTracker()
        _ = t.add(turn: "I'm not interested.", from: .prospect, turn: 1)
        _ = t.add(turn: "Fair enough, can I ask one quick question?", from: .rep, turn: 2)
        let c = t.add(turn: "Okay, go ahead.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .resolved)
        XCTAssertEqual(c.first?.from, .addressed)
        XCTAssertEqual(t.objections.first?.evidenceTurn, 3)
    }

    func testStillOpen() {
        var t = ObjectionTracker()
        _ = t.add(turn: "Not interested.", from: .prospect, turn: 1)
        _ = t.add(turn: "Totally get it, most leaders say that at first.", from: .rep, turn: 2)
        _ = t.add(turn: "No, like I said, not interested.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .stillOpen)
    }

    func testUncertain() {
        var t = ObjectionTracker()
        _ = t.add(turn: "We don't need that.", from: .prospect, turn: 1)
        _ = t.add(turn: "Makes sense, what do you use today for notes?", from: .rep, turn: 2)
        _ = t.add(turn: "Hmm, I'm not sure.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .uncertain)
        XCTAssertTrue(t.promptText.contains("unclear"))
    }

    func testNoObjectionNoEntry() {
        var t = ObjectionTracker()
        XCTAssertTrue(t.add(turn: "Yeah, this is Sean.", from: .prospect, turn: 1).isEmpty)
        XCTAssertTrue(t.promptText.isEmpty)
    }
}
```

## `mac/Tests/CoachCoreTests/Phase1FactsTests.swift`

```swift
import XCTest
@testable import CoachCore

/// Phase 1: the coach must never treat something as settled that the conversation hasn't settled.
/// The first four tests use only APIs that existed before the fix, so they fail on the bug itself.
final class Phase1FactsTests: XCTestCase {
    // C1: a question back is not an answer.
    func testC1_CounterQuestionIsNotAnAnswer() {
        var t = QuestionTracker()
        _ = t.add(turn: "What CRM do you use?", from: .rep)
        _ = t.add(turn: "Why are you asking?", from: .prospect)
        XCTAssertNotEqual(t.questions.first?.status, .answered)
        XCTAssertFalse(t.promptText.contains("never ask again"))
    }

    // C2: "I understand, but..." with a refusal is not resolved.
    func testC2_UnderstandButIsNotResolved() {
        var t = ObjectionTracker()
        _ = t.add(turn: "I'm not interested.", from: .prospect, turn: 1)
        _ = t.add(turn: "Totally fair, most leaders say that at first.", from: .rep, turn: 2)
        _ = t.add(turn: "I understand, but we can't do that.", from: .prospect, turn: 3)
        XCTAssertNotEqual(t.objections.first?.status, .resolved)
    }

    // N3: an unrelated rep question doesn't address a price objection.
    func testN3_UnrelatedRepQuestionDoesNotAddress() {
        var t = ObjectionTracker()
        _ = t.add(turn: "It's too expensive for us.", from: .prospect, turn: 1)
        _ = t.add(turn: "How big is your team?", from: .rep, turn: 2)
        XCTAssertEqual(t.objections.first?.status, .raised)
    }

    // H1: saying the opposite is not delivering the line.
    func testH1_NegationIsNotDelivery() {
        XCTAssertFalse(Delivery.delivered(line: "We help teams with Salesforce.", spoken: "We don't help teams with Salesforce."))
    }

    // C1: the status is .uncertain, and the prompt lists it as not answered.
    func testC1_UncertainStatusAndPrompt() {
        var t = QuestionTracker()
        _ = t.add(turn: "What CRM do you use?", from: .rep)
        _ = t.add(turn: "Why are you asking?", from: .prospect)
        XCTAssertEqual(t.questions.first?.status, .uncertain)
        XCTAssertTrue(t.promptText.contains("NOT answered"))
        // A deflection or refusal is not an answer either.
        var r = QuestionTracker()
        _ = r.add(turn: "What do you use for notes?", from: .rep)
        _ = r.add(turn: "That's not something I can discuss.", from: .prospect)
        XCTAssertEqual(r.questions.first?.status, .uncertain)
        // A real answer still counts.
        var a = QuestionTracker()
        _ = a.add(turn: "How many reps are on the team?", from: .rep)
        _ = a.add(turn: "About twelve.", from: .prospect)
        XCTAssertEqual(a.questions.first?.status, .answered)
    }

    // N1: the delivered line is only "answered" by a real answer.
    func testN1_ResolutionNeedsARealAnswer() {
        XCTAssertFalse(AnswerEvidence.isAnswer("Why?"))
        XCTAssertFalse(AnswerEvidence.isAnswer("What do you mean?"))
        XCTAssertFalse(AnswerEvidence.isAnswer("Mhm."))
        XCTAssertTrue(AnswerEvidence.isAnswer("About twelve reps."))
        XCTAssertTrue(AnswerEvidence.isAnswer("Sure."))
    }

    // C2: a clean yes still resolves; a contrast with no refusal is uncertain.
    func testC2_CleanYesResolvesContrastIsUncertain() {
        var t = ObjectionTracker()
        _ = t.add(turn: "We already use a partner for that.", from: .prospect, turn: 1)
        _ = t.add(turn: "Totally fair, how's that going for your reps?", from: .rep, turn: 2)
        _ = t.add(turn: "Okay, sure, but it's fine I think.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .uncertain)
    }

    // H1: likely covered in the rep's own words (a paraphrase), so not "never said".
    func testH1_LikelyCoveredParaphrase() {
        let line = "Does that sound familiar for your team?"
        XCTAssertTrue(Delivery.likelyCovered(line: line, spoken: "Is that something your team deals with, does it sound familiar?"))
        XCTAssertFalse(Delivery.likelyCovered(line: line, spoken: "Okay great, thanks."))
    }

    // M3: a line read across two transcript chunks is "on the line", even when the second chunk alone
    // has almost none of the line's words. No follow-the-rep request may fire mid-read.
    func testM3_LineAcrossTwoChunksIsOnScript() {
        let line = "We help sales teams get hours back by updating Salesforce after every call for you guys. Is that a pain?"
        let first = "We help sales teams get hours back by updating Salesforce after every call"
        let second = "for you guys."
        XCTAssertFalse(Delivery.onLine(line: line, spoken: second)) // the one-chunk view: looks off script
        XCTAssertFalse(FollowRep.shouldPrepare(repJustSaid: second, recentRepSpeech: first + " " + second,
                                               shownLine: line, shownLineDelivered: false, repWordsSinceLastAsk: 15))
    }
}
```

## `mac/Tests/CoachCoreTests/Phase2MemoryTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Phase2MemoryTests: XCTestCase {
    // C3: call A's late summary never lands in call B, and an older summary never replaces a newer one.
    func testC3_SummaryKeptOnlyForSameCallAndNewer() {
        XCTAssertFalse(CallMemoryRules.acceptSummary(currentCallID: "B", summaryCallID: "A", summaryCovers: 20, storedCovers: 0))
        XCTAssertFalse(CallMemoryRules.acceptSummary(currentCallID: "A", summaryCallID: "A", summaryCovers: 16, storedCovers: 20))
        XCTAssertTrue(CallMemoryRules.acceptSummary(currentCallID: "A", summaryCallID: "A", summaryCovers: 24, storedCovers: 20))
    }

    // M4: summary covers 8 turns, call is at 22: turns 9 to 22 go word for word (none dropped).
    func testM4_UncoveredTurnsStayVerbatim() {
        XCTAssertEqual(CallMemoryRules.verbatimStart(totalTurns: 22, summaryCovers: 8, hasSummary: true), 8)
        XCTAssertEqual(CallMemoryRules.verbatimStart(totalTurns: 30, summaryCovers: 28, hasSummary: true), 20) // at least the last 10
        XCTAssertEqual(CallMemoryRules.verbatimStart(totalTurns: 10, summaryCovers: 0, hasSummary: false), 0)
        XCTAssertTrue(CallMemoryRules.summaryDue(totalTurns: 22, summaryCovers: 8, inFlight: false))
        XCTAssertFalse(CallMemoryRules.summaryDue(totalTurns: 22, summaryCovers: 8, inFlight: true))
    }
}
```

## `mac/Tests/CoachCoreTests/Phase3RaceTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Phase3RaceTests: XCTestCase {
    // C4: the rep asked while the line was still being written: it's stale.
    func testC4_QuestionWhileStreamingMakesItStale() {
        XCTAssertTrue(QueuedLine.repAskedSinceRequest(requestedAt: 10.0, lastRepQuestionAt: 10.6))
        XCTAssertFalse(QueuedLine.repAskedSinceRequest(requestedAt: 10.0, lastRepQuestionAt: 9.0))
    }

    // H2: an unstarted 20-word line is not replaced at 2.5 s (it needs about 5 s to read).
    func testH2_ReadingTimeProtectsLongLines() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: false, secondsSinceShown: 2.5, repStarted: false,
                             delivered: false, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: true, lineWords: 20)
        XCTAssertFalse(CoachMachine.canReplace(s))
        var later = s; later.secondsSinceShown = 5.5
        XCTAssertTrue(CoachMachine.canReplace(later))
        // The rep's interim words are on the wire: they're talking, so no swap.
        var reading = later; reading.repStarted = true; reading.repSpeaking = true
        XCTAssertFalse(CoachMachine.canReplace(reading))
    }

    // H6: "Actually, quick question for you." (no question mark) makes the queued line stale.
    func testH6_PivotPhraseIsStale() {
        XCTAssertNotNil(QueuedLine.staleReason(ageSeconds: 1, repWordsSinceQueued: 5, repAskedSinceQueued: false,
                                               repTextSinceQueued: "Actually, quick question for you."))
        XCTAssertNil(QueuedLine.staleReason(ageSeconds: 1, repWordsSinceQueued: 2, repAskedSinceQueued: false, repTextSinceQueued: "Okay, cool."))
    }
}
```

## `mac/Tests/CoachCoreTests/Phase4LineTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Phase4LineTests: XCTestCase {
    // H4: a second "?" is fixed in code, no extra request.
    func testH4_InternalQuestionMarkFixedInCode() {
        XCTAssertEqual(LineRepair.fix("Makes sense? How many reps are on your team?"), "Makes sense. How many reps are on your team?")
    }

    // M7: a long two-sentence line keeps its question, not the last 25 words of a fragment.
    func testM7_TrimKeepsWholeSentences() {
        let long = "Lots of sales leaders we talk to tell us their reps lose hours every single week typing call notes into the system. Is that true for your team?"
        let out = LineRepair.trimToFit(long, max: 25)
        XCTAssertEqual(out, "Is that true for your team?")
        let noQ = "We help teams get hours back every week. We do it by updating Salesforce after each call for every single rep on the team today."
        XCTAssertEqual(LineRepair.trimToFit(noQ, max: 12), "We help teams get hours back every week.")
    }
}
```

## `mac/Tests/CoachCoreTests/Phase5DraftTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Phase5DraftTests: XCTestCase {
    // H3: "Can I get 30 seconds?" then "Just a quick one." keeps the yes line for "Sure."
    func testH3_YesLineSurvivesSmallTalk() {
        XCTAssertTrue(YesBranchRule.keep(afterRepSaid: "Just a quick one.", wordsSinceQuestion: 4))
        XCTAssertFalse(YesBranchRule.keep(afterRepSaid: "Does that sound familiar?", wordsSinceQuestion: 4)) // a new question
        XCTAssertFalse(YesBranchRule.keep(afterRepSaid: "We help sales teams get hours back after calls.", wordsSinceQuestion: 12))
        XCTAssertEqual(ProspectReply.kind("Sure."), .yes)
    }

    // A yes line from 20 s ago is never used, even on a clear yes; waiting for one is bounded.
    func testYesLineExpiresAndWaitIsBounded() {
        XCTAssertTrue(YesBranchRule.usable(ageSinceQuestion: 3))
        XCTAssertFalse(YesBranchRule.usable(ageSinceQuestion: 20))
        XCTAssertLessThanOrEqual(YesBranchRule.maxWait, 1.5)
    }
}
```

## `mac/Tests/CoachCoreTests/Phase6GoalTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Phase6GoalTests: XCTestCase {
    // N4: a "meeting confirmed" line on screen isn't a booked meeting. Their words must agree.
    func testN4_GoalNeedsTheirAgreement() {
        XCTAssertTrue(GoalEvidence.confirms("Tuesday at 10 works for me."))
        XCTAssertTrue(GoalEvidence.confirms("Sure.", afterTimeOffer: true)) // a plain yes only after a time was offered
        XCTAssertFalse(GoalEvidence.confirms("Maybe, let me check."))
        XCTAssertFalse(GoalEvidence.confirms("No, I'm not interested."))
        XCTAssertFalse(GoalEvidence.confirms("Sounds good but not this week."))
        XCTAssertFalse(GoalEvidence.confirms("Who is this?"))
    }
}
```

## `mac/Tests/CoachCoreTests/Phase7TraceTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Phase7TraceTests: XCTestCase {
    // M5: signals go to the trace as JSON fields.
    func testM5_SignalsAreJSON() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 1.234, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: false, lineWords: 12)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(s.trace))
        XCTAssertEqual(s.trace["rep_speaking"] as? Bool, true)
        XCTAssertEqual(s.trace["seconds_since_shown"] as? Double, 1.23)
    }
}
```

## `mac/Tests/CoachCoreTests/Phase8ControllerTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Phase8ControllerTests: XCTestCase {
    func sig(rep: Bool = false, started: Bool = true, delivered: Bool = false, newTopic: Bool = true, shown: Double = 6) -> CoachSignals {
        CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: rep, secondsSinceShown: shown, repStarted: started,
                     delivered: delivered, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: newTopic, lineWords: 15)
    }

    // H7: the real decision functions the app calls. Never over the rep mid-sentence.
    func testH7_NeverSwapWhileRepSpeaks() {
        XCTAssertEqual(CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: sig(rep: true)), .queue)
        XCTAssertEqual(CoachController.promote(holdLine: false, signals: sig(rep: true), ageSeconds: 1, repWordsSinceQueued: 0,
                                               repAskedSinceQueued: false, repTextSinceQueued: ""), .wait)
    }

    func testH7_StaleDroppedFreshShown() {
        XCTAssertEqual(CoachController.promote(holdLine: false, signals: sig(), ageSeconds: 1, repWordsSinceQueued: 2,
                                               repAskedSinceQueued: false, repTextSinceQueued: "Okay."), .show)
        if case .drop = CoachController.promote(holdLine: false, signals: sig(), ageSeconds: 1, repWordsSinceQueued: 3,
                                                repAskedSinceQueued: false, repTextSinceQueued: "Actually, one last thing.") {} else {
            XCTFail("a pivot should drop the queued line")
        }
        XCTAssertEqual(CoachController.promote(holdLine: true, signals: sig(), ageSeconds: 1, repWordsSinceQueued: 0,
                                               repAskedSinceQueued: false, repTextSinceQueued: ""), .wait)
    }
}
```

## `mac/Tests/CoachCoreTests/ReadingLevelTests.swift`

```swift
import XCTest
@testable import CoachCore

final class ReadingLevelTests: XCTestCase {
    func testPlainLinesPass() {
        XCTAssertFalse(ReadingLevel.tooHard("Hi Sean, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"))
        XCTAssertFalse(ReadingLevel.tooHard("Got it. How much time does your team spend on notes after each call?"))
        XCTAssertFalse(ReadingLevel.tooHard("Understood, Sean. You won't hear from us again. Take care."))
    }

    func testHardLinesFail() {
        XCTAssertTrue(ReadingLevel.tooHard("We facilitate comprehensive operational optimization initiatives, enabling organizations to systematically maximize productivity."))
        XCTAssertTrue(ReadingLevel.tooHard("Would implementing an automated documentation methodology meaningfully accelerate your organization's revenue generation capabilities?"))
    }

    func testNamesDontCount() {
        // A long company name alone shouldn't fail a plain line.
        XCTAssertFalse(ReadingLevel.tooHard("Is this Bartholomew from Consolidated Manufacturing International? Do you have a minute?"))
    }

    func testRuleIsInEveryPrompt() {
        XCTAssertTrue(ReadingLevel.rule.contains("5th grade"))
        XCTAssertLessThan(ReadingLevel.target, ReadingLevel.checkMax)
    }
}
```

## `mac/Tests/CoachCoreTests/Round2FixTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Round2FixTests: XCTestCase {
    // 1: a line the rep moved past while it was written is dropped, not shown.
    func testOfferDropsStaleLine() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: false, secondsSinceShown: 8, repStarted: true,
                             delivered: true, prospectAnsweredSince: true, queued: false, queuedIsForNewTopic: true, lineWords: 10)
        XCTAssertEqual(CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: s,
                                             staleReason: "the rep asked their own question since"),
                       .drop("the rep asked their own question since"))
        XCTAssertEqual(CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: s), .show)
    }

    // 4 and 5: a callback isn't an opt-out; "still" isn't "till".
    func testOptOutBoundaries() {
        XCTAssertTrue(OptOut.matches("Don't call me back, I'm still not interested."))
        XCTAssertFalse(OptOut.matches("Don't call me back till Friday."))
        XCTAssertFalse(OptOut.matches("Don't call me back", isFinal: false))
    }

    // 6: a day alone isn't a booked meeting.
    func testGoalNeedsAgreement() {
        XCTAssertFalse(GoalEvidence.confirms("Tuesday is difficult."))
        XCTAssertTrue(GoalEvidence.confirms("Tuesday works."))
        XCTAssertFalse(GoalEvidence.confirms("Yes."))
        XCTAssertTrue(GoalEvidence.confirms("Yes.", afterTimeOffer: true))
    }

    // 7: silent never clears a line the rep is reading or saying.
    func testSilentClearRespectsReading() {
        var s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 1, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: false, queuedIsForNewTopic: false, lineWords: 20)
        XCTAssertFalse(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s))
        s.repSpeaking = false; s.repStarted = false; s.secondsSinceShown = 1
        XCTAssertFalse(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s)) // still reading
        s.secondsSinceShown = 6
        XCTAssertTrue(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s))
    }

    // 8: a breath after "do" or "have" is mid-thought.
    func testMoreHangingWords() {
        XCTAssertTrue(RepTurn.hangs("so what do"))
        XCTAssertTrue(RepTurn.hangs("and we have"))
    }
}
```

## `mac/Tests/CoachCoreTests/Round3FixTests.swift`

```swift
import XCTest
@testable import CoachCore

final class Round3FixTests: XCTestCase {
    func testSilentNeverBlanksALinePartwayThrough() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: false, secondsSinceShown: 6, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: false, queuedIsForNewTopic: false, lineWords: 20)
        XCTAssertFalse(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s))
    }

    func testGoalFalsePositivesAndTimes() {
        XCTAssertFalse(GoalEvidence.confirms("Have a great day."))
        XCTAssertFalse(GoalEvidence.mentionsTime("Can I get 30 seconds?"))
        XCTAssertTrue(GoalEvidence.mentionsTime("Does Tuesday at 10 work?"))
        XCTAssertTrue(GoalEvidence.mentionsTime("How about 2:30?"))
    }

    func testCommaEndpointIsMidThought() {
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "So, essentially,",
                                           secondsSinceFinal: 0.5, inFallbackWindow: false))
    }

    func testMoreCallbackPhrases() {
        XCTAssertFalse(OptOut.matches("Don't call me again until next month."))
        XCTAssertTrue(OptOut.hasAmbiguous("don't call me back"))
        XCTAssertTrue(OptOut.matches("Stop calling me.", isFinal: false))
    }
}
```

## `mac/Tests/CoachCoreTests/SandyFullCallReplayTests.swift`

```swift
import XCTest
@testable import CoachCore

/// The whole Sandy Adkins call (2026-11-18), replayed second by second: real transcript timing,
/// the real Haiku lines and latencies from the log, the queue, and what the screen shows.
/// It drives the same CoachCore rules the app uses (canReplace, QueuedLine, FollowRep, Delivery);
/// the small loop below stands in for the app's offer/promote code. Times are seconds from the dial.
final class SandyFullCallReplayTests: XCTestCase {
    enum Who { case rep, prospect }
    struct Turn { let who: Who; let start: Double; let end: Double; let text: String }

    // From the log (13:31:07.139 = 0). start = when the words began, end = the final transcript.
    let call: [Turn] = [
        Turn(who: .prospect, start: 9.0, end: 9.63, text: "Hello?"),
        Turn(who: .rep, start: 12.2, end: 13.97, text: "Hi, Sandy."),
        Turn(who: .rep, start: 14.8, end: 16.50, text: "This is Mason at Clarity Consulting."),
        Turn(who: .rep, start: 16.9, end: 19.51, text: "I know you weren't expecting my call. Can I give you"),
        Turn(who: .rep, start: 19.6, end: 20.97, text: "can I get thirty seconds just to tell you why I called?"),
        Turn(who: .prospect, start: 22.7, end: 23.72, text: "Sure."),
        Turn(who: .rep, start: 25.0, end: 25.96, text: "Cool."),
        Turn(who: .rep, start: 28.5, end: 29.52, text: "So, essentially,"),
        Turn(who: .rep, start: 30.6, end: 31.73, text: "what we do is"),
        Turn(who: .rep, start: 33.0, end: 36.75, text: "we are... We work with sales and RevOps teams."),
        Turn(who: .rep, start: 38.0, end: 41.54, text: "To, kind of, like, uncover where missed time is."),
        Turn(who: .rep, start: 43.0, end: 45.50, text: "So what, like, CRM are you guys using?"),
        Turn(who: .prospect, start: 49.4, end: 50.49, text: "Are you talking about my employer?"),
        Turn(who: .rep, start: 52.9, end: 53.96, text: "You're the VP of sales. Yeah?"),
        Turn(who: .prospect, start: 55.6, end: 56.06, text: "Correct."),
        Turn(who: .rep, start: 58.0, end: 58.97, text: "Yeah. So"),
        Turn(who: .rep, start: 59.5, end: 62.46, text: "what what, like, system do you guys use to, like, take notes and keep"),
        Turn(who: .rep, start: 64.2, end: 67.71, text: "track of? Like, leads and things like that in your pipelines."),
        Turn(who: .prospect, start: 69.0, end: 73.04, text: "Okay. Well, that's something that we use internally. So it's not something I can discuss"),
    ]
    let callEnds = 76.97
    let opener = "Hi Sandy, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"
    // The real Haiku answers and how long each took (the employer one includes its fix).
    let haikuAfter: [String: (line: String, seconds: Double)] = [
        "Sure.": ("Thanks, Sandy. Lots of sales leaders tell us reps lose hours typing call notes. Does that sound familiar for your team?", 1.57),
        "Are you talking about my employer?": ("Sorry, Sandy, I meant your sales team's customer records system. Which tool does your team use?", 2.0),
        "Correct.": ("Thanks, Sandy. Quick reason: sales leaders tell us reps lose hours typing call notes. Does that sound familiar to you?", 0.95),
    ]
    let followLatency = 1.0
    let yesLineLatency = 1.0 // Haiku writing the "yes" line while the rep waits for the answer

    struct Shown { let at: Double; let id: Int; let line: String }
    struct Request { let id: Int; let askedAt: Double; let readyAt: Double; let line: String; let repWords: Int; let repLed: Bool }

    func testWholeCall() {
        var shownLine = opener, shownAt = 0.0, shownID = 0
        var repSaidSinceShown = "", repWordsSinceShown = 0, answeredAfterDelivery = false, superseded = false
        var repWords = 0, repWordsAtLastAsk = 0
        var repTextSinceAsk = ""
        var pending: (req: Request, queuedAt: Double, askedSince: Bool)?
        var inflight: [Request] = []
        var seq = 0
        var shown: [Shown] = [Shown(at: 0, id: 0, line: opener)]
        var events: [String] = []
        var followsWhileTalking = 0
        var yesLine: (question: String, readyAt: Double)?
        var yesUsed: [Double] = []

        func repSpeaking(_ t: Double) -> Bool {
            // The app's rule (RepTurn.stillTalking): words in the air; else the transcriber's end-of-speech
            // call (it fires after 0.3 s of silence) and whether the sentence hangs; windows only as fallback.
            if call.contains(where: { $0.who == .rep && t >= $0.start && t <= $0.end }) { return true }
            guard let i = call.lastIndex(where: { $0.who == .rep && $0.end <= t }) else { return false }
            let last = call[i]
            let nextRep = call[(i + 1)...].first { $0.who == .rep }
            let endpointed = t >= last.end + 0.3 && (nextRep.map { $0.start > last.end + 0.3 } ?? true)
            return RepTurn.stillTalking(wordsInTheAir: false, endpointed: endpointed, lastFinal: last.text,
                                        secondsSinceFinal: t - last.end, inFallbackWindow: t <= last.end + SpeechTimeline.repActiveWindow)
        }
        func prospectSpeaking(_ t: Double) -> Bool {
            call.contains { $0.who == .prospect && t >= $0.start && t <= $0.end + SpeechTimeline.prospectActiveWindow }
        }
        func signals(_ t: Double) -> CoachSignals {
            let delivered = Delivery.delivered(line: shownLine, spoken: repSaidSinceShown)
            return CoachSignals(hasLine: true, prospectSpeaking: prospectSpeaking(t), repSpeaking: repSpeaking(t),
                                secondsSinceShown: t - shownAt, repStarted: repWordsSinceShown > 0, delivered: delivered,
                                prospectAnsweredSince: answeredAfterDelivery, queued: pending != nil, queuedIsForNewTopic: superseded,
                                lineWords: shownLine.split(separator: " ").count, overlapping: false,
                                repOnLine: Delivery.onLine(line: shownLine, spoken: repSaidSinceShown))
        }
        func show(_ r: Request, _ t: Double) {
            // Never while the rep talks: the core check the replay must prove.
            XCTAssertFalse(repSpeaking(t), "line #\(r.id) changed while the rep was speaking at \(t)")
            shown.append(Shown(at: t, id: r.id, line: r.line))
            events.append(String(format: "%6.2f  SHOWN #%d: %@", t, r.id, r.line))
            shownLine = r.line; shownAt = t; shownID = r.id
            repSaidSinceShown = ""; repWordsSinceShown = 0; answeredAfterDelivery = false; superseded = false
            pending = nil
        }
        func ask(_ t: Double, line: String, latency: Double, repLed: Bool) {
            seq += 1
            repWordsAtLastAsk = repWords
            repTextSinceAsk = ""
            inflight = [Request(id: seq, askedAt: t, readyAt: t + latency, line: line, repWords: repWords, repLed: repLed)]
            events.append(String(format: "%6.2f  ask #%d%@", t, seq, repLed ? " (follow the rep)" : ""))
        }

        var t = 0.0
        var nextTurn = 0
        while t <= callEnds {
            // 1. Transcript finals that land now.
            while nextTurn < call.count, call[nextTurn].end <= t {
                let turn = call[nextTurn]; nextTurn += 1
                if turn.who == .rep {
                    let n = turn.text.split(separator: " ").count
                    repWords += n; repWordsSinceShown += n
                    repSaidSinceShown += " " + turn.text
                    repTextSinceAsk += " " + turn.text
                    if pending != nil, turn.text.contains("?") { pending!.askedSince = true }
                    // A yes/no question: the line for "yes" is written now, held, never shown before the answer.
                    yesLine = RepQuestion.closedQuestion(in: turn.text).map { (question: $0, readyAt: t + yesLineLatency) }
                    if let y = yesLine { events.append(String(format: "%6.2f  writing the yes line for: %@", t, y.question)) }
                    let delivered = Delivery.delivered(line: shownLine, spoken: repSaidSinceShown)
                    let prevRep = call.prefix(nextTurn - 1).last { $0.who == .rep }?.text ?? ""
                    if FollowRep.shouldPrepare(repJustSaid: turn.text, recentRepSpeech: prevRep + " " + turn.text, shownLine: shownLine,
                                               shownLineDelivered: delivered, repWordsSinceLastAsk: repWords - repWordsAtLastAsk) {
                        if let p = pending { events.append(String(format: "%6.2f  dropped #%d while rep talks (heuristic)", t, p.req.id)) }
                        pending = nil
                        if repSpeaking(t) { followsWhileTalking += 1 }
                        ask(t, line: "FOLLOW: builds on \"\(turn.text)\"", latency: followLatency, repLed: true)
                    }
                } else {
                    if Delivery.delivered(line: shownLine, spoken: repSaidSinceShown), AnswerEvidence.isAnswer(turn.text) { answeredAfterDelivery = true }
                    let greeting = shownID == 0 && turn.text.split(separator: " ").count <= 4 && repWords == 0
                    let kind = ProspectReply.kind(turn.text)
                    if let y = yesLine, kind == .yes, y.readyAt <= t {
                        yesLine = nil
                        seq += 1
                        repWordsAtLastAsk = repWords
                        let r = Request(id: seq, askedAt: t, readyAt: t, line: "YES LINE after \"\(y.question)\"", repWords: repWords, repLed: false)
                        superseded = true // they answered the rep's question
                        yesUsed.append(t)
                        events.append(String(format: "%6.2f  \"%@\" is a yes: ready line, no wait", t, turn.text))
                        if CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: signals(t)) == .show { show(r, t) } else { pending = (r, t, false) }
                    } else if !greeting {
                        yesLine = nil
                        let h = haikuAfter[turn.text] ?? (line: "ANSWER: \(turn.text)", seconds: 1.0)
                        ask(t, line: h.line, latency: h.seconds, repLed: false)
                    }
                }
            }
            // 2. Answers that finish now: show if safe, else queue (the app's offer()).
            if let r = inflight.first, r.readyAt <= t {
                inflight = []
                let lastProspect = call.prefix(nextTurn).last { $0.who == .prospect }
                let lastIsProspect = call.prefix(nextTurn).last?.who == .prospect
                let repAsked = call.prefix(nextTurn).dropLast().last { $0.who == .rep }?.text.hasSuffix("?") ?? false
                if r.repLed { superseded = true }
                else if lastIsProspect, let p = lastProspect,
                        repAsked || p.text.split(separator: " ").count >= 3 || p.text.contains("?") { superseded = true }
                if CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: signals(t)) == .show { show(r, t) }
                else {
                    pending = (r, t, false)
                    events.append(String(format: "%6.2f  queued #%d (rep speaking: %@)", t, r.id, repSpeaking(t) ? "yes" : "no"))
                }
            }
            // 3. Each tick: promote a waiting line if safe, unless it went stale (the app's promotePendingIfReady()).
            if let p = pending {
                // The same decision function the app's promotePendingIfReady() calls (H7).
                switch CoachController.promote(holdLine: false, signals: signals(t), ageSeconds: t - p.queuedAt,
                                               repWordsSinceQueued: repWords - p.req.repWords, repAskedSinceQueued: p.askedSince,
                                               repTextSinceQueued: repTextSinceAsk) {
                case .wait: break
                case .show: show(p.req, t)
                case .drop(let why):
                    events.append(String(format: "%6.2f  dropped #%d at the pause: %@ (%@ rule)", t, p.req.id, why, QueuedLine.ruleKind(why)))
                    pending = nil
                }
            }
            t = (t * 100 + 5).rounded() / 100 // 50 ms ticks
        }
        print("Sandy replay:\n" + events.joined(separator: "\n"))

        // A. "Sure." to "Can I get 30 seconds?": the pitch was written while the rep asked, so it shows at once.
        let afterSure = shown.first { $0.at >= 23.72 }
        XCTAssertNotNil(afterSure)
        if let a = afterSure { XCTAssertLessThan(a.at - 23.72, 0.1, "the line after Sure wasn't ready") }
        // "Correct." to "...Yeah?" (a yes/no question) also used a ready line. Open questions ("What CRM?") didn't.
        XCTAssertEqual(yesUsed.count, 2)
        // B. No stale line: queued lines only show after passing QueuedLine.staleReason (step 3), and the
        // 23 s old pitch never comes back once the rep has pitched in their own words.
        XCTAssertFalse(shown.contains { $0.line.hasPrefix("Thanks, Sandy. Lots of") },
                       "the old pitch showed after the rep had pitched in their own words")
        // C. The coach prepared lines while the rep improvised, not only after they stopped.
        XCTAssertGreaterThan(followsWhileTalking, 0, "no line was prepared while the rep was talking off script")
        // D. When the rep finished with their own question, nothing was pushed over it (they wait for the answer).
        XCTAssertFalse(shown.contains { $0.at > 45.5 && $0.at < 50.49 }, "a line was pushed while the rep waited for an answer")
        // F. Never mid-sentence: the rep paused 1.7 s inside "...take notes and keep / track of?" and
        // the first replay showed a new line right there. Nothing may show between 62.46 and 67.71.
        XCTAssertFalse(shown.contains { $0.at > 62.46 && $0.at < 67.71 }, "a line changed in the middle of the rep's sentence")
        // E. Her question about her employer got its answer on screen within about 2 s.
        let employer = shown.first { $0.line.hasPrefix("Sorry, Sandy") }
        XCTAssertNotNil(employer)
        if let e = employer { XCTAssertLessThan(e.at - 50.49, 2.6) }
    }
}
```

## `mac/Tests/CoachCoreTests/SandyReplayTests.swift`

```swift
import XCTest
@testable import CoachCore

/// Replay of the Sandy Adkins call (2026-11-18 13:31:07 to 13:32:24), step by step through the
/// coach's decisions. The rep's actual words are the source of truth; the script is the guide.
final class SandyReplayTests: XCTestCase {
    let opener = "Hi Sandy, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"

    // Was: "delivered (62%)" before the rep had asked for the 30 seconds. Now: only once the question is asked.
    func testOpenerDeliveredOnlyWhenItsQuestionIsAsked() {
        let partway = "Hi, Sandy. This is Mason at Clarity Consulting. I know you weren't expecting my call. Can I give you"
        XCTAssertFalse(Delivery.delivered(line: opener, spoken: partway))
        XCTAssertTrue(Delivery.delivered(line: opener, spoken: partway + " can I get thirty seconds just to tell you why I called?"))
    }

    // After "Sure.", the rep explains Clarity in their own words: that's the rep talking, not delivering the old line.
    func testRepExplainingAfterResolvedIsNotDelivering() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 20, repStarted: true,
                             delivered: true, prospectAnsweredSince: true, queued: true, queuedIsForNewTopic: true,
                             lineWords: 25, overlapping: false, repOnLine: true)
        XCTAssertEqual(CoachMachine.state(s), .repTalking)
    }

    // Was: the line written after "Sure." showed 23.6 s later, after the rep had pitched and asked about their CRM.
    // Now: dropped as stale. The rep asked their own question, so no new line is pushed over it.
    func testQueuedLineDroppedWhenRepMovedOn() {
        let repSince = "Cool. So, essentially, what we do is we are... We work with sales and RevOps teams. To, kind of, like, uncover where missed time is. So what, like, CRM are you guys using?"
        let words = repSince.split(separator: " ").count
        XCTAssertNotNil(QueuedLine.staleReason(ageSeconds: 23.6, repWordsSinceQueued: words, repAskedSinceQueued: true))
        // A line queued a moment ago, with the rep only saying "Cool.", still shows.
        XCTAssertNil(QueuedLine.staleReason(ageSeconds: 1.5, repWordsSinceQueued: 1, repAskedSinceQueued: false))
        // The rep pitched in their own words and paused without a question: stale, and a fresh line follows them.
        XCTAssertEqual(QueuedLine.staleReason(ageSeconds: 6, repWordsSinceQueued: 20, repAskedSinceQueued: false),
                       "the rep said 20 words of their own since")
    }

    // Was: 5 early requests (#13 to #17) in 4.5 s during one statement. Now: at most 2.
    func testEarlyDraftsDontBurst() {
        let partials = [
            "Okay. Well, that's something that we use",
            "Okay. Well, that's something that we use internally.",
            "Okay. Well, that's something that we use internally. So it's not",
            "Okay. Well, that's something that we use internally. So it's not something I can discuss",
            "Okay. Well, that's something that we use internally. So it's not something I can discuss outside of here.",
            "Okay. Well, that's something that we use internally. So it's not something I can discuss outside of here. But thank you for calling me.",
        ]
        var last: String?, drafts = 0
        for p in partials where EarlyStart.delayMS(for: p) != nil
            && EarlyStart.shouldRedraft(previous: last, text: p, draftsThisTurn: drafts) {
            last = p; drafts += 1
        }
        XCTAssertLessThanOrEqual(drafts, 2)
        XCTAssertGreaterThanOrEqual(drafts, 1)
    }

    // Was: "already have it". It's a boundary, then a polite goodbye.
    func testBoundaryAndEndingRecognized() {
        XCTAssertEqual(ObjectionTracker.detect("Okay. Well, that's something that we use internally. So it's not something I can discuss"), "won't share")
        XCTAssertEqual(ObjectionTracker.detect("But thank you for calling me. I appreciate your help."), "ending the call")
        var t = ObjectionTracker()
        _ = t.add(turn: "So it's not something I can discuss outside of here.", from: .prospect, turn: 9)
        XCTAssertTrue(t.promptText.contains("don't ask about it again"))
    }

    // Was: a second Haiku request (about 1 s) just to remove "CRM". Now fixed in code.
    func testAbbreviationFixedWithoutAnotherRequest() {
        let fixed = LineRepair.fix("Sorry, Sandy. Which CRM does your sales team use today?")
        XCTAssertNotNil(fixed)
        XCTAssertFalse(fixed!.contains("CRM"))
        XCTAssertNil(LineRepair.fix("Do you use XQZ for that?")) // unknown: still goes back to Claude
    }
}
```

## `mac/Tests/CoachCoreTests/SilentAndCallbackTests.swift`

```swift
import XCTest
@testable import CoachCore

final class SilentAndCallbackTests: XCTestCase {
    // MOVE: silent keeps a line that still fits, clears one the talk moved past.
    func testSilentKeepsUsefulClearsOutdated() {
        XCTAssertFalse(SilentRule.clearCurrent(superseded: false, delivered: false, answered: false)) // still useful
        XCTAssertTrue(SilentRule.clearCurrent(superseded: true, delivered: false, answered: false))   // they moved on
        XCTAssertTrue(SilentRule.clearCurrent(superseded: false, delivered: true, answered: true))    // said and answered
    }

    // "Don't call me back until Tuesday" is a callback request, not do-not-call.
    func testCallbackRequestIsNotOptOut() {
        XCTAssertFalse(OptOut.matches("Don't call me back until Tuesday."))
        XCTAssertFalse(OptOut.matches("don't call me back", isFinal: false)) // partial: wait for the rest
        XCTAssertTrue(OptOut.matches("No. No. Just don't call me back."))      // final, nothing after: opt-out
        XCTAssertTrue(OptOut.matches("take me off your list", isFinal: false)) // clear phrase: at once
    }
}
```

## `mac/Tests/CoachCoreTests/TurnTakingTests.swift`

```swift
import XCTest
@testable import CoachCore

/// Regression tests from the Sean Collins call (2026-11-17): turn taking, interruptions,
/// backchannels, rep talk vs delivering the line, paraphrased delivery, and do not call.
final class TurnTakingTests: XCTestCase {
    typealias T = SpeechTimeline

    // Sean: "Yes." then the rep answers right away. A normal turn, not an interruption,
    // even though the rep starts well inside the old 1.5 s "still talking" window.
    func testNormalTurnTakingIsNotInterruption() {
        var t = T()
        t.update(.prospect, start: 0, end: 1.0, text: "Yes.", isFinal: true)
        XCTAssertEqual(t.update(.rep, start: 1.1, end: 1.5, text: "Hi, Sean.", isFinal: false), .turnTaking)
        let now = t.now(1.5)
        XCTAssertTrue(now.rep); XCTAssertFalse(now.prospect); XCTAssertFalse(now.overlap)
    }

    // Deepgram boundaries jitter: a 0.1 s touch at the hand-off is still turn taking.
    func testBoundaryJitterIsTurnTaking() {
        var t = T()
        t.update(.prospect, start: 0, end: 1.0, text: "We use HubSpot.", isFinal: true)
        XCTAssertEqual(t.update(.rep, start: 0.9, end: 2.0, text: "Got it, how long?", isFinal: true), .turnTaking)
    }

    // The prospect cuts in and the rep stops: a genuine interruption.
    func testGenuineInterruption() {
        var t = T()
        t.update(.rep, start: 0, end: 2.0, text: "So the reason I'm calling is we help teams", isFinal: true)
        XCTAssertEqual(t.update(.prospect, start: 1.5, end: 2.8, text: "Wait, who is this?", isFinal: true), .interruption)
    }

    // Both keep talking: overlapping speech (crosstalk), and the state shows overlap while it lasts.
    func testOverlappingSpeech() {
        var t = T()
        t.update(.rep, start: 0, end: 4.0, text: "and what that means for your reps is more time selling", isFinal: true)
        XCTAssertEqual(t.update(.prospect, start: 1.0, end: 3.0, text: "I really don't think so", isFinal: true), .overlap)
        XCTAssertTrue(t.now(3.0).overlap)
    }

    // "Uh-huh" while the rep talks is not a turn: the rep keeps the floor.
    func testBackchannelDoesNotTakeTheTurn() {
        var t = T()
        t.update(.rep, start: 0, end: 4.0, text: "we update Salesforce after every call for you", isFinal: false)
        XCTAssertEqual(t.update(.prospect, start: 1.5, end: 1.9, text: "Uh-huh.", isFinal: true), .backchannel)
        let now = t.now(2.0)
        XCTAssertTrue(now.rep); XCTAssertFalse(now.prospect); XCTAssertFalse(now.overlap)
    }

    // A late transcript revision (their words ran longer than first heard) re-classifies the turn.
    func testRevisedBoundaryReclassifies() {
        var t = T()
        t.update(.prospect, start: 0, end: 1.0, text: "We already", isFinal: false)
        XCTAssertEqual(t.update(.rep, start: 1.2, end: 2.0, text: "So tell me", isFinal: true), .turnTaking)
        t.update(.prospect, start: 0, end: 1.6, text: "We already have a partner", isFinal: true)
        XCTAssertEqual(t.segments[.rep]?.last?.kind, .interruption)
    }

    // Rep talking is not delivering: "Okay." is unrelated to the line on screen.
    func testRepSpeechSeparateFromDelivering() {
        func sig(onLine: Bool) -> CoachSignals {
            CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 5, repStarted: true,
                         delivered: false, prospectAnsweredSince: false, queued: false, queuedIsForNewTopic: false,
                         lineWords: 20, overlapping: false, repOnLine: onLine)
        }
        XCTAssertEqual(CoachMachine.state(sig(onLine: false)), .repTalking)
        XCTAssertEqual(CoachMachine.state(sig(onLine: true)), .delivering)
        let line = "Can I get 30 seconds to tell you why I called?"
        XCTAssertFalse(Delivery.onLine(line: line, spoken: "Okay."))
        XCTAssertTrue(Delivery.onLine(line: line, spoken: "can I have thirty seconds to tell you"))
    }

    // The exact Sean opener and what the rep said: 62%, from real key words, with the evidence logged.
    func testSeanParaphraseDeliveryEvidence() {
        let line = "Hi Sean, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"
        let said = "Hi, Sean. My name is Mason. I am from Clarity Consulting. And this is a cold call. So I'm wondering if I can just have thirty seconds to tell you why."
        XCTAssertTrue(Delivery.delivered(line: line, spoken: said))
        XCTAssertEqual(Delivery.confidence(line: line, spoken: said), 8.0 / 12.0, accuracy: 0.001) // stems: call/called count once
        XCTAssertEqual(Delivery.rule(line: line, spoken: said), "question") // its question was asked
        let ev = Delivery.evidence(line: line, spoken: said)
        XCTAssertTrue(ev.matched.contains("second") && ev.matched.contains("tell") && ev.matched.contains("why"))
        XCTAssertTrue(ev.missing.contains("expect"))
        // Greeting words alone are not delivery.
        XCTAssertFalse(Delivery.delivered(line: line, spoken: "Hi Sean, Mason from Clarity Consulting."))
    }

    // "Don't call me back" is terminal: do not call state, nothing replaces the goodbye, no early draft.
    func testExplicitDoNotCall() {
        XCTAssertTrue(OptOut.matches("No. No. Just don't call me back."))
        XCTAssertTrue(OptOut.matches("just dont call me back"))
        XCTAssertTrue(OptOut.matches("Don\u{2019}t call me again"))
        XCTAssertFalse(OptOut.matches("Ever again."))
        XCTAssertFalse(OptOut.matches("Call me back next week"))
        let s = CoachSignals(hasLine: true, prospectSpeaking: true, repSpeaking: true, secondsSinceShown: 1, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: true,
                             overlapping: true, doNotCall: true)
        XCTAssertEqual(CoachMachine.state(s), .doNotCall)
        XCTAssertFalse(CoachMachine.canReplace(s))
        XCTAssertNil(EarlyStart.delayMS(for: "No. No. Just don't call me back."))
    }

    // Requests #16 and #17: drafts on "No." and "No. No." were wasted. Fragments no longer start a draft.
    func testEarlyStartSkipsFragments() {
        XCTAssertNil(EarlyStart.delayMS(for: "No."))
        XCTAssertNil(EarlyStart.delayMS(for: "No. No."))
        XCTAssertEqual(EarlyStart.delayMS(for: "I'm not interested, thanks."), 200)
        XCTAssertEqual(EarlyStart.delayMS(for: "we already use a partner for that"), 450)
    }

    // The prompt asks for fewer words than the check allows, so a 21 to 25 word line isn't re-written.
    func testPromptWordBudgetUnderCheck() {
        XCTAssertLessThan(LineBudget.promptMax, LineBudget.checkMax)
    }
}
```

## `mac/Tests/CoachCoreTests/YesLineTests.swift`

```swift
import XCTest
@testable import CoachCore

final class YesLineTests: XCTestCase {
    func testClosedVsOpenQuestions() {
        XCTAssertNotNil(RepQuestion.closedQuestion(in: "can I get thirty seconds just to tell you why I called?"))
        XCTAssertNotNil(RepQuestion.closedQuestion(in: "You're the VP of sales. Yeah?"))
        XCTAssertNotNil(RepQuestion.closedQuestion(in: "Does that sound familiar for your team?"))
        XCTAssertNil(RepQuestion.closedQuestion(in: "So what, like, CRM are you guys using?")) // open: no ready line
        XCTAssertNil(RepQuestion.closedQuestion(in: "We help sales teams."))                    // not a question
    }

    func testReplyKinds() {
        for y in ["Sure.", "Correct.", "Yeah, go ahead.", "Okay, sure.", "Yes."] { XCTAssertEqual(ProspectReply.kind(y), .yes, y) }
        for n in ["No.", "Not really.", "No, I'm good.", "I'm not interested."] { XCTAssertEqual(ProspectReply.kind(n), .no, n) }
        for u in ["Maybe.", "Hmm, not sure.", "It depends."] { XCTAssertEqual(ProspectReply.kind(u), .unsure, u) }
        // A real answer, a question back, or an interruption is not a yes: it gets a fresh line.
        XCTAssertEqual(ProspectReply.kind("Are you talking about my employer?"), .other)
        XCTAssertEqual(ProspectReply.kind("Sure, but who is this?"), .other)
    }

    func testFinishedSpeakingNotPunctuationAlone() {
        XCTAssertTrue(RepTurn.midSentence(lastFinal: "take notes and keep", secondsSince: 1.7))
        XCTAssertTrue(RepTurn.midSentence(lastFinal: "We help teams with.", secondsSince: 1.0))  // punctuated, but hanging
        XCTAssertFalse(RepTurn.midSentence(lastFinal: "What CRM do you use?", secondsSince: 0.5))
        XCTAssertFalse(RepTurn.midSentence(lastFinal: "We help sales teams.", secondsSince: 0.5))
        XCTAssertFalse(RepTurn.midSentence(lastFinal: "take notes and keep", secondsSince: 3.5))  // 3 s fallback
    }
}
```
