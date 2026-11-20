# Clarity Live Coach: full live-coach source

Commit `79d609a` on `claude/main-update`. Every file below is complete and unedited, with line numbers.

## Files

1. `mac/Sources/CoachCore/CoachCore.swift` (1304 lines)
2. `mac/Sources/CoachCore/Think.swift` (176 lines)
3. `mac/Sources/CoachCore/LineLook.swift` (40 lines)
4. `mac/Sources/CoachCore/CallAttempt.swift` (211 lines)
5. `mac/Sources/ClarityLiveCoach/CoachPrompt.swift` (380 lines)
6. `mac/Sources/ClarityLiveCoach/CoachModel+Lines.swift` (1160 lines)
7. `mac/Sources/ClarityLiveCoach/CoachModel+Audio.swift` (373 lines)
8. `mac/Sources/ClarityLiveCoach/CoachModel+Call.swift` (924 lines)
9. `mac/Sources/ClarityLiveCoach/CoachModel+Script.swift` (217 lines)
10. `mac/Sources/ClarityLiveCoach/CoachModel+FollowUp.swift` (740 lines)
11. `mac/Sources/ClarityLiveCoach/CoachModel+PhoneTree.swift` (175 lines)
12. `mac/Sources/ClarityLiveCoach/Coach.swift` (645 lines)
13. `mac/Sources/ClarityLiveCoach/CoachTypes.swift` (214 lines)
14. `mac/Sources/ClarityLiveCoach/LiveCoach.swift` (100 lines)
15. `mac/Sources/ClarityLiveCoach/Claude.swift` (163 lines)
16. `mac/Sources/ClarityLiveCoach/Guardrail.swift` (85 lines)
17. `mac/Sources/ClarityLiveCoach/ScriptPage.swift` (238 lines)
18. `mac/Sources/ClarityLiveCoach/ScriptTemplates.swift` (137 lines)
19. `mac/Sources/ClarityLiveCoach/ScriptOutlineCard.swift` (319 lines)
20. `mac/Sources/ClarityLiveCoach/Screener.swift` (229 lines)
21. `mac/Sources/ClarityLiveCoach/CoachView.swift` (2227 lines)


## `mac/Sources/CoachCore/CoachCore.swift`

```swift
    1  import Foundation
    2  
    3  // The live coach's decisions, kept small and pure so they can be tested without a call.
    4  
    5  /// What the coach screen is doing right now.
    6  public enum CoachState: String, Sendable {
    7      case listening = "Listening"       // prospect is talking; preparing
    8      case ready = "Ready"               // a fresh line is on screen
    9      case reading = "Reading"           // line shown, rep hasn't started (likely reading)
   10      case delivering = "Delivering"     // rep is speaking; line is protected
   11      case interrupted = "Interrupted"   // prospect cut in while the rep spoke
   12      case resolved = "Resolved"         // line delivered and the prospect answered
   13      case superseded = "Outdated"       // a better line is queued for this moment
   14      case repTalking = "Rep talking"    // rep is speaking, but not saying the line on screen
   15      case doNotCall = "Do not call"     // they asked not to be called: terminal, no more coaching
   16      case idle = "Idle"                 // nothing useful to say
   17  }
   18  
   19  /// Everything the state machine looks at, sampled twice a second.
   20  public struct CoachSignals: Sendable {
   21      public var hasLine: Bool
   22      public var prospectSpeaking: Bool
   23      public var repSpeaking: Bool
   24      public var secondsSinceShown: Double
   25      public var repStarted: Bool          // rep has said words since the line appeared
   26      public var delivered: Bool           // the line's meaning was said
   27      public var prospectAnsweredSince: Bool // prospect spoke after the rep delivered it
   28      public var queued: Bool              // a newer line is waiting
   29      public var queuedIsForNewTopic: Bool // the prospect moved on (interrupt/new question)
   30      public var lineWords: Int            // words in the line on screen (to protect silent reading)
   31      public var overlapping: Bool         // both sides talking at the same moment (a real interruption)
   32      public var repOnLine: Bool           // what the rep is saying matches the line on screen
   33      public var doNotCall: Bool           // they asked not to be called again
   34  
   35      public init(hasLine: Bool, prospectSpeaking: Bool, repSpeaking: Bool, secondsSinceShown: Double,
   36                  repStarted: Bool, delivered: Bool, prospectAnsweredSince: Bool, queued: Bool, queuedIsForNewTopic: Bool,
   37                  lineWords: Int = 0, overlapping: Bool = false, repOnLine: Bool = false, doNotCall: Bool = false) {
   38          self.hasLine = hasLine; self.prospectSpeaking = prospectSpeaking; self.repSpeaking = repSpeaking
   39          self.secondsSinceShown = secondsSinceShown; self.repStarted = repStarted; self.delivered = delivered
   40          self.prospectAnsweredSince = prospectAnsweredSince; self.queued = queued; self.queuedIsForNewTopic = queuedIsForNewTopic
   41          self.lineWords = lineWords
   42          self.overlapping = overlapping; self.repOnLine = repOnLine; self.doNotCall = doNotCall
   43      }
   44  }
   45  
   46  extension CoachSignals {
   47      /// For the trace, as JSON fields (not one long string).
   48      public var trace: [String: Any] {
   49          ["has_line": hasLine, "prospect_speaking": prospectSpeaking, "rep_speaking": repSpeaking,
   50           "seconds_since_shown": (secondsSinceShown * 100).rounded() / 100, "rep_started": repStarted, "delivered": delivered,
   51           "prospect_answered": prospectAnsweredSince, "queued": queued, "new_topic": queuedIsForNewTopic, "line_words": lineWords,
   52           "overlapping": overlapping, "rep_on_line": repOnLine, "do_not_call": doNotCall]
   53      }
   54  }
   55  
   56  public enum CoachMachine {
   57      /// How long a brand-new line is protected for reading before an un-started line can be swapped.
   58      public static let readingGrace = 1.2
   59  
   60      /// Silent reading can't be seen, so protect it by length: about 4 words a second, 1.2 to 5 seconds.
   61      /// Reading under pressure: about 3 words a second, plus about 1.5 s to start speaking. 2 to 6.5 s.
   62      public static func readingTime(words: Int) -> Double { min(6.5, max(2.0, Double(words) / 3 + 1.5)) }
   63  
   64      public static func state(_ s: CoachSignals) -> CoachState {
   65          if s.doNotCall { return .doNotCall }
   66          // Only real overlap is an interruption. One side answering right after the other is a normal turn.
   67          if s.overlapping { return .interrupted }
   68          // Delivering = saying the line on screen. Any other rep talk ("okay", small talk) is just talking.
   69          // Once delivered and answered, new rep talk is the rep's own words, not this line.
   70          if s.repSpeaking {
   71              let onThisLine = s.hasLine && !(s.delivered && s.prospectAnsweredSince) && (s.repOnLine || s.delivered)
   72              return onThisLine ? .delivering : .repTalking
   73          }
   74          if s.queued && s.queuedIsForNewTopic && s.repStarted && !s.delivered { return .superseded }
   75          if s.prospectSpeaking { return .listening }
   76          guard s.hasLine else { return .idle }
   77          if s.delivered && s.prospectAnsweredSince { return .resolved }
   78          if !s.repStarted { return .reading } // one steady label while it's theirs to read (no flicker)
   79          return .reading
   80      }
   81  
   82      /// May a newer line replace the one on screen right now?
   83      /// Never while the rep speaks. Not during the first moment of reading. Otherwise yes if the rep
   84      /// hasn't started it, it's been delivered, or the conversation clearly moved on.
   85      public static func canReplace(_ s: CoachSignals) -> Bool {
   86          if s.doNotCall { return false } // the goodbye line stays; nothing replaces it
   87          guard s.hasLine else { return true }
   88          if s.repSpeaking { return false }
   89          // Not started: only something new from the prospect replaces it, never the clock alone, and
   90          // never before the line has had its reading time (about 4 words a second, up to 5 s).
   91          if !s.repStarted { return s.queuedIsForNewTopic && s.secondsSinceShown >= readingTime(words: s.lineWords) }
   92          return s.delivered || s.queuedIsForNewTopic
   93      }
   94  
   95      /// Answers only count if they're for the newest request (older ones finishing late are dropped).
   96      public static func isFresh(requestID: Int, latestID: Int) -> Bool { requestID == latestID }
   97  }
   98  
   99  /// Who is talking, read from audio timestamps (when the words were spoken), not from when the
  100  /// transcript happened to arrive. Each side's speech is a list of time ranges on one shared clock.
  101  /// Deepgram revises a range while it's interim (the end grows, the start may shift), so the newest
  102  /// interim range replaces the previous interim one. A turn change is classified by how the ranges sit:
  103  ///   turn taking   the new speaker starts after the other one's words end (any gap, even 0.1 s)
  104  ///   backchannel   a short "yeah", "uh-huh", "right" over the other side: not a turn at all
  105  ///   interruption  the new speaker starts while the other is talking, and the other stops soon after
  106  ///   overlap       both keep talking at once (crosstalk)
  107  /// Time windows are only a fallback: they say whether a side is still "active" while its next
  108  /// transcript is in flight, never whether two sides overlapped.
  109  public struct SpeechTimeline: Sendable {
  110      public enum Side: String, Sendable { case rep, prospect }
  111      public enum Kind: String, Sendable { case turnTaking = "turn_taking", backchannel, interruption, overlap }
  112  
  113      public struct Segment: Sendable, Equatable {
  114          public var side: Side, start: Double, end: Double, text: String, isFinal: Bool
  115          public var kind: Kind?
  116      }
  117  
  118      /// Deepgram boundaries jitter by about a word; overlap smaller than this is a clean hand-off.
  119      public static let tolerance = 0.25
  120      /// The interrupted side stopping within this long of the newcomer's start means it yielded.
  121      public static let yieldWindow = 1.0
  122      /// Fallback only: a side counts as still talking this long after its last word, to bridge
  123      /// transcript delay and breaths. Never used to decide overlap.
  124      public static let repActiveWindow = 1.5
  125      public static let prospectActiveWindow = 0.9
  126  
  127      public static let backchannelWords: Set<String> = ["yeah", "yep", "yes", "uh-huh", "uh", "huh", "mhm", "mm", "hmm", "mm-hmm",
  128          "right", "okay", "ok", "sure", "got", "it", "gotcha", "totally", "true", "cool", "nice", "wow", "oh"]
  129  
  130      public private(set) var segments: [Side: [Segment]] = [.rep: [], .prospect: []]
  131  
  132      public init() {}
  133  
  134      public static func isBackchannel(_ text: String) -> Bool {
  135          let w = text.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted).filter { !$0.isEmpty }
  136          return !w.isEmpty && w.count <= 2 && w.allSatisfy(backchannelWords.contains)
  137      }
  138  
  139      /// Adds or revises one transcript range. Returns the segment's classification when it is new
  140      /// or changed (so the caller logs every decision once), else nil.
  141      @discardableResult
  142      public mutating func update(_ side: Side, start: Double, end: Double, text: String, isFinal: Bool) -> Kind? {
  143          var list = segments[side] ?? []
  144          var seg = Segment(side: side, start: start, end: max(end, start), text: text, isFinal: isFinal)
  145          let old: Kind?
  146          if let last = list.last, !last.isFinal { old = last.kind; list.removeLast() } else { old = nil }
  147          seg.kind = classify(seg)
  148          list.append(seg)
  149          if list.count > 40 { list.removeFirst(list.count - 40) }
  150          segments[side] = list
  151          // A newcomer can turn an earlier "interruption" of the other side into crosstalk: re-check it.
  152          reclassifyOther(than: side)
  153          return seg.kind != old ? seg.kind : nil
  154      }
  155  
  156      private func classify(_ x: Segment) -> Kind? {
  157          let other: Side = x.side == .rep ? .prospect : .rep
  158          // The other side's most recent range that started before this one.
  159          guard let y = segments[other]?.last(where: { $0.start <= x.start }) else { return nil }
  160          let overlap = min(x.end, y.end) - max(x.start, y.start)
  161          if overlap <= Self.tolerance { return .turnTaking }
  162          if Self.isBackchannel(x.text) { return .backchannel }
  163          // Did the other side keep going after this side came in?
  164          let otherKeptGoing = (segments[other] ?? []).contains { $0.end > x.start + Self.yieldWindow && $0.start < x.end }
  165          return otherKeptGoing ? .overlap : .interruption
  166      }
  167  
  168      private mutating func reclassifyOther(than side: Side) {
  169          let other: Side = side == .rep ? .prospect : .rep
  170          guard var list = segments[other], var last = list.last else { return }
  171          last.kind = classify(last)
  172          list[list.count - 1] = last
  173          segments[other] = list
  174      }
  175  
  176      /// Who holds the floor at `now` (same clock as the ranges).
  177      public func now(_ now: Double) -> (rep: Bool, prospect: Bool, overlap: Bool) {
  178          let rep = segments[.rep]?.last, pro = segments[.prospect]?.last
  179          // A backchannel never takes the turn.
  180          let repActive = rep.map { now - $0.end < Self.repActiveWindow && $0.kind != .backchannel } ?? false
  181          let proActive = pro.map { now - $0.end < Self.prospectActiveWindow && $0.kind != .backchannel } ?? false
  182          guard repActive, proActive, let r = rep, let p = pro else { return (repActive, proActive, false) }
  183          let newer = r.start >= p.start ? r : p
  184          if newer.kind == .interruption || newer.kind == .overlap {
  185              // Real overlap only while both ranges actually cross in audio time.
  186              if min(r.end, p.end) - max(r.start, p.start) > Self.tolerance { return (true, true, true) }
  187          }
  188          // Clean hand-off: whoever started last holds the turn.
  189          return newer.side == .rep ? (true, false, false) : (false, true, false)
  190      }
  191  }
  192  
  193  /// "Take me off your list", "don't call me back": matched in code, no AI.
  194  public enum OptOut {
  195      public static let phrases = ["take me off your list", "take me off the list", "remove me from your list",
  196                                   "remove me from the list", "don't call me again", "do not call me again",
  197                                   "stop calling me", "put me on your do not call", "do not call list",
  198                                   "don't ever call", "never call me", "quit calling", "lose my number",
  199                                   "don't call me back", "do not call me back", "don't call back", "don't call here",
  200                                   "don't call this number", "never call here", "never call this number", "remove my number",
  201                                   "take my number off", "delete my number", "don't contact me", "do not contact me",
  202                                   "stop contacting me", "never call again", "don't call again", "do not call again"]
  203  
  204      /// "Don't call me back" can mean "call me later" ("...until Tuesday"). Those only count on a final
  205      /// transcript, and not when a later time follows. Clear phrases ("take me off your list") count at once.
  206      static let ambiguous = ["don't call me back", "do not call me back", "don't call back", "don't call me again",
  207                              "do not call me again", "don't call again", "do not call again", "don't call here"]
  208  
  209      /// The words contain a phrase that might be a callback ("...until Tuesday"): wait for the full pause before acting.
  210      public static func hasAmbiguous(_ text: String) -> Bool {
  211          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "dont ", with: "don't ")
  212          return ambiguous.contains { t.contains($0) }
  213      }
  214      static let deferrals = ["until", "till", "later", "tomorrow", "next", "after", "monday", "tuesday", "wednesday",
  215                              "thursday", "friday", "in a few", "in an hour", "when", "this afternoon", "tonight"]
  216  
  217      public static func matches(_ text: String, isFinal: Bool = true) -> Bool {
  218          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "dont ", with: "don't ")
  219          for p in phrases where t.contains(p) {
  220              guard ambiguous.contains(p) else { return true }
  221              guard isFinal, let r = t.range(of: p) else { continue }
  222              let after = " " + t[r.upperBound...].prefix(40).split(whereSeparator: { !$0.isLetter && $0 != "'" }).joined(separator: " ") + " "
  223              if !deferrals.contains(where: { after.contains(" \($0) ") }) { return true } // whole words: "still" isn't "till"
  224          }
  225          return false
  226      }
  227  }
  228  
  229  /// MOVE: silent keeps the line on screen only if it still fits. If the talk moved past it, it's cleared.
  230  public enum SilentRule {
  231      public static func clearCurrent(superseded: Bool, delivered: Bool, answered: Bool) -> Bool {
  232          superseded || (delivered && answered)
  233      }
  234  
  235      /// The same, but never pulled from under the rep: not while they talk or are still reading it.
  236      public static func clearNow(superseded: Bool, delivered: Bool, answered: Bool, signals: CoachSignals) -> Bool {
  237          guard clearCurrent(superseded: superseded, delivered: delivered, answered: answered) else { return false }
  238          if signals.repStarted && !signals.delivered { return false } // partway through it: let them finish
  239          var s = signals
  240          s.queuedIsForNewTopic = superseded || s.queuedIsForNewTopic
  241          return CoachMachine.canReplace(s)
  242      }
  243  }
  244  
  245  /// When to start Claude before the prospect is done. A one or two word fragment ("No.") is not
  246  /// worth a request: it almost always grows ("No. No. Just don't call me back."), wasting the draft.
  247  public enum EarlyStart {
  248      public static let minFinishedWords = 4 // real words, not "I", "yeah", "so"
  249      public static let minUnfinishedWords = 6
  250  
  251      /// Another early draft for the same turn only when their meaning moved: 5+ more words, or a sentence
  252      /// finished since the last draft. Stops a burst of near-identical requests while they talk.
  253      public static let maxDraftsPerTurn = 2
  254      public static func shouldRedraft(previous: String?, text: String, draftsThisTurn: Int) -> Bool {
  255          guard draftsThisTurn < maxDraftsPerTurn else { return false }
  256          guard let previous else { return true }
  257          let grew = text.split(separator: " ").count - previous.split(separator: " ").count
  258          let finishedNow = (text.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false)
  259          let finishedBefore = (previous.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false)
  260          return grew >= 5 || (finishedNow && !finishedBefore && grew >= 2)
  261      }
  262  
  263      /// Milliseconds to wait for the words to hold still, or nil for "don't start early".
  264      public static func delayMS(for text: String) -> Int? {
  265          let t = text.trimmingCharacters(in: .whitespaces)
  266          if OptOut.matches(t) || OptOut.hasAmbiguous(t) { return nil } // handled in code, never drafted (Fix 3)
  267          let filler: Set<String> = ["i", "yeah", "so", "um", "uh", "well", "oh", "like", "okay", "ok", "and", "but", "the", "a"]
  268          let words = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).filter { !filler.contains(String($0)) }.count
  269          let finished = t.last.map { ".?!".contains($0) } ?? false
  270          if finished && words >= minFinishedWords { return 200 }
  271          if words >= minUnfinishedWords { return 450 }
  272          return nil
  273      }
  274  }
  275  
  276  /// Reading level for every word the rep reads or a prospect hears: 1st to 5th grade.
  277  /// Flesch-Kincaid grade, with names left out (a name like "Clarity Consulting" is read once,
  278  /// not sounded out, and shouldn't push a plain line over).
  279  public enum ReadingLevel {
  280      /// The prompt asks for grade 1 to 5. The check allows one grade of slack, since the formula
  281      /// is noisy on one or two short sentences.
  282      public static let target = 5.0
  283      public static let checkMax = 6.0
  284  
  285      public static let rule = """
  286      Reading level, always: every word the rep will say, read or send (lines, scripts, voicemails, texts, notes)
  287      is at a 1st to 5th grade reading level. Short, common words of one or two syllables. Short sentences,
  288      under 12 words each. No jargon, no long words when a short one works ("use" not "utilize", "help" not
  289      "facilitate", "about" not "approximately"). Names of people and companies are fine as they are.
  290      """
  291  
  292      static func syllables(_ word: String) -> Int {
  293          let w = word.lowercased().filter { $0.isLetter }
  294          guard !w.isEmpty else { return 0 }
  295          if w.count <= 3 { return 1 }
  296          let vowels = Set("aeiouy")
  297          var count = 0, prev = false
  298          for c in w { let v = vowels.contains(c); if v && !prev { count += 1 }; prev = v }
  299          if w.hasSuffix("e"), !w.hasSuffix("le"), count > 1 { count -= 1 }
  300          if w.hasSuffix("ed"), count > 1, !(w.hasSuffix("ted") || w.hasSuffix("ded")) { count -= 1 }
  301          return max(1, count)
  302      }
  303  
  304      /// Flesch-Kincaid grade level. Capitalized words after a sentence's first word count as names (1 syllable).
  305      public static func grade(_ text: String) -> Double {
  306          let sentences = text.split(whereSeparator: { ".?!".contains($0) })
  307              .map { $0.split(separator: " ").map(String.init).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) } }
  308              .filter { !$0.isEmpty }
  309          let words = sentences.reduce(0) { $0 + $1.count }
  310          guard words > 0 else { return 0 }
  311          var syl = 0
  312          for s in sentences {
  313              for (i, w) in s.enumerated() {
  314                  let isName = i > 0 && (w.first?.isUppercase ?? false) && w != "I" && !w.hasPrefix("I'")
  315                  syl += isName ? 1 : (w.allSatisfy({ $0.isNumber || ",.".contains($0) }) ? 2 : syllables(w))
  316              }
  317          }
  318          return 0.39 * Double(words) / Double(sentences.count) + 11.8 * Double(syl) / Double(words) - 15.59
  319      }
  320  
  321      public static func tooHard(_ text: String) -> Bool { grade(text) > checkMax }
  322  }
  323  
  324  /// Live line length. The prompt asks for fewer words than the check allows, so a line that runs a
  325  /// word long passes instead of costing a second fixing it.
  326  public enum LineBudget {
  327      public static let checkMax = 25
  328      public static let promptMax = 20
  329  }
  330  
  331  /// Did the rep get the line's meaning across? Paraphrase-friendly: compares meaningful words, and the
  332  /// line's question counts as delivered once the rep asks a question with its key words.
  333  public enum Delivery {
  334      private static let stop: Set<String> = ["the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "is",
  335          "are", "it", "that", "this", "you", "your", "we", "our", "i", "me", "my", "so", "just", "do", "does", "with",
  336          "at", "be", "can", "if", "about", "as", "have", "has", "was", "they", "them", "their", "would"]
  337      // Question words (what, how, who, when, why) are kept: they carry the point of a question.
  338  
  339      /// A light stem, so "updating"/"updated"/"updates" and "calls"/"called" match.
  340      static func stem(_ w: String) -> String {
  341          if w.count > 5, w.hasSuffix("ing") { return String(w.dropLast(3)) }
  342          if w.count > 4, w.hasSuffix("ed") { return String(w.dropLast(2)) }
  343          if w.count > 4, w.hasSuffix("ly") { return String(w.dropLast(2)) }
  344          if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast(1)) }
  345          return w
  346      }
  347  
  348      static func words(_ text: String) -> [String] {
  349          text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 && !stop.contains($0) }.map(stem)
  350      }
  351  
  352      static let negations: Set<String> = ["not", "no", "never", "don't", "doesn't", "didn't", "won't", "can't", "isn't", "aren't",
  353                                           "wasn't", "haven't", "hasn't", "dont", "cant", "wont", "nobody", "nothing"]
  354  
  355      /// The rep said the opposite: a negation the line doesn't have, right before one of the line's words.
  356      static func negated(line: String, spoken: String) -> Bool {
  357          func tokens(_ s: String) -> [String] {
  358              s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
  359                  .map { $0.replacingOccurrences(of: "\u{2019}", with: "'") }
  360          }
  361          let lineTokens = Set(tokens(line))
  362          let key = Set(words(line))
  363          let t = tokens(spoken)
  364          for (i, w) in t.enumerated() where negations.contains(w) && !lineTokens.contains(w) {
  365              if t[(i + 1)..<min(t.count, i + 4)].contains(where: { key.contains(stem($0)) }) { return true }
  366          }
  367          return false
  368      }
  369  
  370      /// 0 to 1: share of the line's meaningful words the rep said. 0 if they said the opposite.
  371      public static func confidence(line: String, spoken: String) -> Double {
  372          let want = Set(words(line))
  373          guard !want.isEmpty, !negated(line: line, spoken: spoken) else { return 0 }
  374          let said = Set(words(spoken))
  375          return Double(want.intersection(said).count) / Double(want.count)
  376      }
  377  
  378      /// Partly said in the rep's own words (a paraphrase): not confirmed delivery, but not "never said" either.
  379      public static func likelyCovered(line: String, spoken: String) -> Bool {
  380          evidence(line: line, spoken: spoken).matched.count >= 2 && confidence(line: line, spoken: spoken) >= 0.35
  381      }
  382  
  383      /// The words behind a delivery score, for the trace: which of the line's key words were said.
  384      public static func evidence(line: String, spoken: String) -> (matched: [String], missing: [String]) {
  385          let said = Set(words(spoken))
  386          var seen = Set<String>(), matched: [String] = [], missing: [String] = []
  387          for w in words(line) where seen.insert(w).inserted { if said.contains(w) { matched.append(w) } else { missing.append(w) } }
  388          return (matched, missing)
  389      }
  390  
  391      /// Is the rep on the line at all (enough to call it delivering, not just talking)?
  392      public static func onLine(line: String, spoken: String) -> Bool {
  393          evidence(line: line, spoken: spoken).matched.count >= 2 || confidence(line: line, spoken: spoken) >= 0.25
  394      }
  395  
  396      /// Which rule (if any) counted it delivered: "overall" or "question".
  397      /// A line with a question is delivered when its question is asked (or nearly all of it is said):
  398      /// half the words of the intro is not the point of the line.
  399      public static func rule(line: String, spoken: String) -> String? {
  400          if line.contains("?") {
  401              if let q = line.split(separator: "?").first.map(String.init),
  402                 let lastSentence = q.split(whereSeparator: { ".!".contains($0) }).last.map(String.init),
  403                 confidence(line: lastSentence, spoken: spoken) >= 0.6 { return "question" }
  404              return confidence(line: line, spoken: spoken) >= 0.8 ? "overall" : nil
  405          }
  406          return confidence(line: line, spoken: spoken) >= 0.5 ? "overall" : nil
  407      }
  408  
  409      public static func delivered(line: String, spoken: String) -> Bool { rule(line: line, spoken: spoken) != nil }
  410  }
  411  
  412  /// Approved answers from the script (objections, questions, blockers), matched in code: no AI wait.
  413  public struct ScriptAnswers: Sendable {
  414      public struct Entry: Sendable, Equatable { public let id: String; public let phrases: [String]; public let say: String }
  415      public let entries: [Entry]
  416  
  417      public init(entries: [Entry]) { self.entries = entries }
  418  
  419      /// Reads every table row with a "Sounds like" and a "Say" column (" | " or tab separated).
  420      public init(script: String) {
  421          var out: [Entry] = []
  422          var soundsCol: Int?, sayCol: Int?
  423          for raw in script.components(separatedBy: "\n") {
  424              let line = raw.trimmingCharacters(in: .whitespaces)
  425              let sep = line.contains("|") ? "|" : (line.contains("\t") ? "\t" : nil)
  426              guard let sep else { continue }
  427              let cols = line.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
  428              if let s = cols.firstIndex(where: { $0.lowercased() == "sounds like" }), let y = cols.firstIndex(where: { $0.lowercased() == "say" }) {
  429                  soundsCol = s; sayCol = y; continue
  430              }
  431              guard let s = soundsCol, let y = sayCol, cols.count > max(s, y) else { continue }
  432              let say = cols[y].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  433              guard !say.isEmpty, !say.lowercased().hasPrefix("show"), !say.contains("(") else { continue }
  434              let phrases = cols[s].lowercased()
  435                  .components(separatedBy: CharacterSet(charactersIn: ",;/\"“”"))
  436                  .map { $0.trimmingCharacters(in: .whitespaces) }
  437                  .filter { $0.split(separator: " ").count >= 2 } // two words or more: safe to match
  438              guard !phrases.isEmpty else { continue }
  439              out.append(Entry(id: cols[0], phrases: phrases, say: say))
  440          }
  441          entries = out
  442      }
  443  
  444      /// The approved answer whose "sounds like" phrase appears in what they said (longest match wins).
  445      public func match(_ said: String) -> Entry? { bestMatch(said)?.entry }
  446  
  447      func bestMatch(_ said: String) -> (entry: Entry, phrase: String)? {
  448          let t = said.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  449          var best: (Entry, String)?
  450          for e in entries {
  451              for p in e.phrases where t.contains(p) {
  452                  if best == nil || p.count > best!.1.count { best = (e, p) }
  453              }
  454          }
  455          return best.map { ($0.0, $0.1) }
  456      }
  457  
  458      /// The instant answer only when it fits what they meant, not just shared words (Nov 20: "What is this
  459      /// about?" got a discovery row; "I'm not the right fit" got "Pain nothing"). nil + why when it's blocked.
  460      public func matchInContext(_ said: String, answeredQuestions: [String] = []) -> (entry: Entry?, why: String) {
  461          guard let (entry, phrase) = bestMatch(said) else { return (nil, "no Sounds-like phrase in their words") }
  462          switch ConversationIntent.classify(said) {
  463          case .optOut, .ending: return (nil, "they're ending the call: higher-priority rule")
  464          case .question: return (nil, "they asked a direct question: answer it first, not a script row")
  465          case .rejection:
  466              // A clear no gets no sales question: only a row that just acknowledges (or offers one email) may answer it.
  467              let kind = ObjectionTracker.detect(said)
  468              guard kind != nil, ObjectionTracker.detect(phrase) == kind else {
  469                  return (nil, "they declined; the matched row (\(entry.id)) isn't about that")
  470              }
  471              let low = entry.say.lowercased()
  472              if entry.say.contains("?"), !low.contains("email") {
  473                  return (nil, "they clearly declined; row \(entry.id) asks another sales question")
  474              }
  475          case .objection:
  476              // An objection may get the row written for that same objection.
  477              let kind = ObjectionTracker.detect(said)
  478              guard kind != nil, ObjectionTracker.detect(phrase) == kind else {
  479                  return (nil, "they raised an objection; the matched row (\(entry.id)) isn't about it")
  480              }
  481          case .other: break
  482          }
  483          // High confidence only: the phrase must be most of what they said. A short phrase inside a longer
  484          // sentence is a word overlap, not their meaning ("I don't know" in "I don't know that I'm the right fit").
  485          let saidWords = Delivery.words(said).count
  486          let phraseWords = Delivery.words(phrase).count
  487          if saidWords > 14 { return (nil, "too long to be a one-line answer to a script row") }
  488          if saidWords > 3, Double(phraseWords) / Double(saidWords) < 0.5 {
  489              return (nil, "\"\(phrase)\" is only a small part of what they said")
  490          }
  491          // The row's own line asks something already answered on this call: don't ask it again.
  492          if let repeated = answeredQuestions.first(where: { Repeats.same($0, entry.say) }) {
  493              return (nil, "row \(entry.id) repeats a question already answered: \"\(repeated)\"")
  494          }
  495          return (entry, "\"\(phrase)\" matches what they meant")
  496      }
  497  }
  498  
  499  /// Questions asked on the call and what happened to each, tracked in code from the transcript
  500  /// (not inferred by the model). Fed to Haiku as facts: what's still open, what's already answered.
  501  public struct QuestionTracker: Sendable {
  502      public enum Speaker: String, Sendable { case rep, prospect }
  503      public enum Status: String, Sendable { case open, answered, interrupted, abandoned, uncertain }
  504      public struct Question: Sendable, Equatable {
  505          public let id: Int
  506          public let asker: Speaker
  507          public let text: String
  508          public var status: Status
  509          public var answer: String
  510      }
  511      public enum Change: Sendable, Equatable {
  512          case asked(Question), answered(Question), interrupted(Question), abandoned(Question), uncertain(Question)
  513      }
  514  
  515      public private(set) var questions: [Question] = []
  516      private var nextID = 1
  517      public init() {}
  518  
  519      private static let filler: Set<String> = ["uh", "um", "hmm", "mm", "mhm", "uh-huh", "huh"]
  520      private static let starts = ["who", "what", "when", "where", "why", "how", "do", "does", "did", "is", "are", "can",
  521                                   "could", "would", "will", "should", "have", "has", "any", "which"]
  522  
  523      /// The questions in a turn: sentences ending in "?" (or starting like a question when no punctuation came through).
  524      public static func questions(in text: String) -> [String] {
  525          var out: [String] = []
  526          var current = ""
  527          for ch in text {
  528              current.append(ch)
  529              if ".?!".contains(ch) {
  530                  let s = current.trimmingCharacters(in: .whitespaces)
  531                  if ch == "?" { out.append(s) }
  532                  current = ""
  533              }
  534          }
  535          if out.isEmpty, !text.contains("."), let first = text.lowercased().split(separator: " ").first,
  536             starts.contains(String(first)), text.split(separator: " ").count >= 4 {
  537              out.append(text.trimmingCharacters(in: .whitespaces))
  538          }
  539          return out
  540      }
  541  
  542      /// One finished turn. `overlapped`: the other person was still talking when this turn started.
  543      public mutating func add(turn text: String, from speaker: Speaker, overlapped: Bool = false) -> [Change] {
  544          var changes: [Change] = []
  545          let words = text.lowercased().split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
  546          let substantive = words.contains { !Self.filler.contains($0) && !$0.isEmpty }
  547          // The other side's open questions: answered only by a real answer. A question back, a
  548          // deflection or a refusal leaves it uncertain (still not answered). Cut off if talked over.
  549          for i in questions.indices where questions[i].asker != speaker
  550              && (questions[i].status == .open || questions[i].status == .uncertain) && substantive {
  551              if overlapped, questions[i].status == .open {
  552                  questions[i].status = .interrupted
  553                  changes.append(.interrupted(questions[i]))
  554              } else if AnswerEvidence.isAnswer(text) {
  555                  questions[i].status = .answered
  556                  questions[i].answer = text
  557                  changes.append(.answered(questions[i]))
  558              } else if questions[i].status == .open {
  559                  questions[i].status = .uncertain
  560                  questions[i].answer = text
  561                  changes.append(.uncertain(questions[i]))
  562              }
  563          }
  564          let asked = Self.questions(in: text)
  565          // Asking again before getting an answer abandons the earlier one.
  566          if !asked.isEmpty {
  567              for i in questions.indices where questions[i].asker == speaker
  568                  && (questions[i].status == .open || questions[i].status == .interrupted || questions[i].status == .uncertain) {
  569                  questions[i].status = .abandoned
  570                  changes.append(.abandoned(questions[i]))
  571              }
  572          }
  573          for q in asked {
  574              let new = Question(id: nextID, asker: speaker, text: q, status: .open, answer: "")
  575              nextID += 1
  576              questions.append(new)
  577              changes.append(.asked(new))
  578          }
  579          return changes
  580      }
  581  
  582      /// Rep questions not to ask again: answered, or deflected and declined. A clarification ("What do you
  583      /// mean?") is not on it: a clearer rephrase is the right move there.
  584      public var doNotRepeat: [String] {
  585          questions.filter { $0.asker == .rep && ($0.status == .answered || ($0.status == .uncertain && !Self.isClarification($0.answer))) }
  586              .map(\.text)
  587      }
  588  
  589      static func isClarification(_ reply: String) -> Bool {
  590          let t = reply.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  591          return ["what do you mean", "sorry?", "say that again", "didn't catch", "come again", "pardon", "what was that",
  592                  "i don't follow", "can you repeat"].contains { t.contains($0) }
  593      }
  594  
  595      /// A reply that shares meaning with the question, or says enough to be a real answer.
  596      static func isConfirmed(_ q: Question) -> Bool {
  597          let n = Delivery.words(q.answer).count
  598          if n >= 8 { return true }
  599          let shared = Repeats.meaning(q.text).intersection(Repeats.meaning(q.answer)).count
  600          return n >= 3 && shared >= 1
  601      }
  602  
  603      /// For the model: facts about questions tracked by rules from the transcript.
  604      public var promptText: String {
  605          let repAnswered = questions.filter { $0.asker == .rep && $0.status == .answered }
  606          let theirsOpen = questions.filter { $0.asker == .prospect && $0.status == .open }
  607          let repOpen = questions.filter { $0.asker == .rep && ($0.status == .open || $0.status == .interrupted) }
  608          let repUncertain = questions.filter { $0.asker == .rep && $0.status == .uncertain }
  609          var lines: [String] = []
  610          if !theirsOpen.isEmpty { lines.append("Prospect questions NOT yet answered (answer these first): " + theirsOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
  611          if !repOpen.isEmpty { lines.append("Rep questions still waiting for an answer: " + repOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
  612          if !repUncertain.isEmpty { lines.append("Rep questions NOT answered (they asked back, deflected or declined; don't treat as answered, don't push): " + repUncertain.map { "\"\($0.text)\" -> they said \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
  613          // Answered is judged by simple rules (the next reply looked like an answer), so it comes in two strengths.
  614          let confirmed = repAnswered.filter { Self.isConfirmed($0) }
  615          let probable = repAnswered.filter { !Self.isConfirmed($0) }
  616          if !confirmed.isEmpty { lines.append("Asked AND answered, their words show it (never ask again): " + confirmed.map { "\"\($0.text)\" -> \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
  617          if !probable.isEmpty { lines.append("Probably answered (a short or indirect reply; never ask again, but don't treat their answer as settled): " + probable.map { "\"\($0.text)\" -> \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
  618          return lines.joined(separator: "\n")
  619      }
  620  }
  621  
  622  /// Objections on this call, tracked in code from the transcript (no AI).
  623  /// Addressed is not resolved: "addressed" only means the rep answered it. Only the prospect's
  624  /// next words can mark it resolved, still open, or uncertain.
  625  public struct ObjectionTracker: Sendable {
  626      public enum Status: String, Sendable { case raised, addressed, resolved, stillOpen = "still_open", uncertain }
  627      public struct Objection: Sendable, Equatable {
  628          public let id: Int
  629          public let kind: String          // e.g. "not interested"
  630          public let raisedText: String    // their exact words
  631          public let raisedTurn: Int       // transcript turn number
  632          public var status: Status
  633          public var addressedText = ""    // the rep's answer
  634          public var addressedTurn = 0
  635          public var evidenceText = ""     // the prospect's words that decided resolved / still open / uncertain
  636          public var evidenceTurn = 0
  637      }
  638      public struct Change: Sendable, Equatable {
  639          public let objection: Objection
  640          public let from: Status?
  641          public let why: String
  642      }
  643  
  644      /// Common cold-call objections: a name and the phrases that mean it.
  645      public static let kinds: [(String, [String])] = [
  646          ("won't share", ["can't discuss", "cannot discuss", "not something i can discuss", "can't share", "cannot share",
  647                           "not something i can share", "confidential", "can't talk about", "not able to discuss", "not at liberty"]),
  648          ("ending the call", ["thank you for calling", "thanks for calling", "thanks for the call", "have a good day",
  649                               "have a great day", "i have to go", "i've got to go", "gotta go", "i need to go"]),
  650          ("not interested", ["not interested", "no interest", "not for us", "we're good", "we are good", "i'm good", "pass on",
  651                              "don't know that i'm interested", "don't think i'm interested", "not the right fit",
  652                              "right fit for this", "not a good fit", "not a fit"]),
  653          ("no time", ["no time", "too busy", "i'm busy", "in a meeting", "bad time", "not a good time", "driving",
  654                       "don't have time", "do not have time", "can't talk", "busy right now"]),
  655          ("send info", ["send me an email", "send me something", "send me info", "email me", "send it over", "send me some"]),
  656          ("already have it", ["we already have", "we already use", "we use another", "we use a ", "already working with", "we have a partner", "we have someone", "in house", "in-house"]),
  657          ("happy as is", ["happy with", "it's working", "works fine", "we're fine", "don't need", "do not need", "no need",
  658                           "all set", "we're set", "we are set", "all good", "taken care of"]),
  659          ("price", ["too expensive", "no budget", "can't afford", "cost too much", "costs too much", "not in the budget"]),
  660          ("wrong person", ["not the right person", "not my area", "not my department", "talk to someone else", "i don't handle"]),
  661          ("call later", ["call me later", "call back later", "call me next", "reach out next", "maybe later", "not right now",
  662                          "call me back", "try me later", "another time", "try me tomorrow"]),
  663          ("trust", ["how did you get my number", "who gave you", "is this a sales call", "is this a scam"]),
  664      ]
  665      static let stillOpenWords = ["no", "nope", "still not", "not interested", "i said", "like i said", "already told you", "not really", "i don't think so",
  666                                   "can't do", "cannot do", "won't work", "not looking", "not a priority", "no thanks"]
  667      static let contrastWords = ["but", "however", "though", "although"]
  668      /// Words that show the rep spoke to this kind of objection (plus general acknowledgments).
  669      static let addressCues: [String: [String]] = [
  670          "not interested": ["interested", "fair", "understand", "get it", "makes sense", "hear you"],
  671          "no time": ["quick", "time", "seconds", "minute", "busy", "later", "call back"],
  672          "send info": ["email", "send", "info"],
  673          "already have it": ["already", "use", "using", "partner", "tool", "today", "working", "current"],
  674          "happy as is": ["fine", "working", "need", "happy", "good", "today"],
  675          "price": ["cost", "price", "budget", "free", "expensive", "money", "invest", "spend"],
  676          "wrong person": ["right person", "who", "handles", "point me", "best person", "in charge"],
  677          "call later": ["later", "when", "better time", "call back", "tomorrow", "next week"],
  678          "trust": ["number", "list", "linkedin", "found", "sales call", "honest", "research"],
  679          "won't share": ["no problem", "understand", "fair", "of course", "totally"],
  680          "ending the call": [],
  681      ]
  682      static let acknowledgments = ["fair", "understand", "totally get", "get it", "makes sense", "hear you", "appreciate", "no problem", "of course"]
  683  
  684      /// Did the rep's words speak to this objection? Not just any 3 words: words tied to it, or an acknowledgment.
  685      static func addresses(kind: String, text: String) -> Bool {
  686          has(text, (addressCues[kind] ?? []) + acknowledgments)
  687      }
  688      static let resolvedWords = ["sure", "okay", "ok", "go ahead", "yeah", "yes", "tell me", "what is it", "how does", "how much", "what do you",
  689                                  "that's fair", "fair enough", "makes sense", "i guess so", "interesting", "send it", "let's do", "that works"]
  690      static let uncertainWords = ["hmm", "maybe", "i don't know", "not sure", "we'll see", "possibly", "i guess"]
  691  
  692      public private(set) var objections: [Objection] = []
  693      private var nextID = 1
  694      public init() {}
  695  
  696      /// The objection kind in these words, or nil. Script "sounds like" phrases can add their own kinds.
  697      public static func detect(_ text: String, extra: [(String, [String])] = []) -> String? {
  698          let t = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
  699          return (extra + kinds).first { $0.1.contains { t.contains($0) } }?.0
  700      }
  701  
  702      static func has(_ text: String, _ words: [String]) -> Bool {
  703          let t = " " + text.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted).joined(separator: " ") + " "
  704          return words.contains { t.contains(" \($0) ") }
  705      }
  706  
  707      /// Feed each finalized turn. `turn` is the transcript turn number (for evidence in the trace).
  708      public mutating func add(turn text: String, from speaker: QuestionTracker.Speaker, turn: Int,
  709                               extra: [(String, [String])] = []) -> [Change] {
  710          var out: [Change] = []
  711          func set(_ i: Int, _ s: Status, why: String) {
  712              let from = objections[i].status
  713              objections[i].status = s
  714              out.append(Change(objection: objections[i], from: from, why: why))
  715          }
  716          if speaker == .rep {
  717              // The rep answered any objection still waiting. Addressed, not resolved.
  718              for i in objections.indices where [.raised, .stillOpen].contains(objections[i].status)
  719                  && Self.addresses(kind: objections[i].kind, text: text) {
  720                  objections[i].addressedText = text
  721                  objections[i].addressedTurn = turn
  722                  set(i, .addressed, why: "rep answered it (turn \(turn)); waiting on the prospect")
  723              }
  724              return out
  725          }
  726          // Prospect: first judge any objection the rep just addressed, from their words only.
  727          let newKind = Self.detect(text, extra: extra)
  728          for i in objections.indices where objections[i].status == .addressed {
  729              objections[i].evidenceText = text
  730              objections[i].evidenceTurn = turn
  731              if newKind == objections[i].kind || Self.has(text, Self.stillOpenWords) {
  732                  set(i, .stillOpen, why: "prospect pushed back again (turn \(turn))")
  733              } else if Self.has(text, Self.uncertainWords) {
  734                  set(i, .uncertain, why: "prospect's answer is unsure (turn \(turn))")
  735              } else if Self.has(text, Self.resolvedWords) && !Self.has(text, Self.contrastWords) {
  736                  set(i, .resolved, why: "prospect agreed (turn \(turn))")
  737              } else if Self.has(text, Self.contrastWords) {
  738                  set(i, .uncertain, why: "prospect agreed but added a 'but' (turn \(turn))")
  739              } else {
  740                  set(i, .uncertain, why: "prospect's answer doesn't settle it (turn \(turn))")
  741              }
  742          }
  743          // A new objection (not one already open of the same kind).
  744          if let kind = newKind, !objections.contains(where: { $0.kind == kind && $0.status != .resolved }) {
  745              objections.append(Objection(id: nextID, kind: kind, raisedText: text, raisedTurn: turn, status: .raised))
  746              nextID += 1
  747              out.append(Change(objection: objections[objections.count - 1], from: nil, why: "prospect raised it (turn \(turn))"))
  748          }
  749          return out
  750      }
  751  
  752      /// For Claude's context. Empty when there are none.
  753      public var promptText: String {
  754          objections.map { o in
  755              var line = "- \(o.kind) (turn \(o.raisedTurn), \"\(o.raisedText)\"): "
  756              switch o.status {
  757              case .raised where o.kind == "won't share": line += "they won't share this. Respect it: don't ask about it again"
  758              case .raised where o.kind == "ending the call": line += "they're ending the call. Thank them and close politely, no more questions"
  759              case .raised: line += "NOT answered yet"
  760              case .addressed: line += "rep answered it, prospect hasn't responded yet. NOT resolved"
  761              case .resolved: line += "resolved: they said \"\(o.evidenceText)\""
  762              case .stillOpen: line += "STILL OPEN after the rep's answer: they said \"\(o.evidenceText)\""
  763              case .uncertain: line += "unclear: they said \"\(o.evidenceText)\""
  764              }
  765              return line
  766          }.joined(separator: "\n")
  767      }
  768  }
  769  
  770  
  771  /// A line waiting in the queue (held while the rep talked) is only shown if it still fits.
  772  /// The rep's own words are the source of truth: if they've moved on, the old line is dropped.
  773  public enum QueuedLine {
  774      public static let maxAge = 8.0
  775      public static let maxRepWords = 8
  776  
  777      /// "heuristic" (the word or time limit, a safety net) or "conversation" (the rep asked their own
  778      /// question, a real change in the talk). Logged with every drop so the two can be told apart.
  779      public static func ruleKind(_ reason: String) -> String {
  780          reason.contains("asked") || reason.contains("pivot") ? "conversation" : "heuristic"
  781      }
  782  
  783      /// Phrases a rep uses to change direction, with or without a question mark.
  784      static let pivots = ["quick question", "before i let you go", "one last thing", "actually", "let me ask", "can i ask", "curious"]
  785  
  786      /// The rep changed direction in their own words: an unpunctuated question or a pivot phrase.
  787      public static func repPivoted(_ text: String) -> Bool {
  788          let t = text.lowercased()
  789          return pivots.contains(where: { t.contains($0) }) || !QuestionTracker.questions(in: text).isEmpty
  790      }
  791  
  792      /// C4: the rep asked a question after this line was requested (even while it was still being written).
  793      public static func repAskedSinceRequest(requestedAt: Double, lastRepQuestionAt: Double) -> Bool {
  794          lastRepQuestionAt > requestedAt
  795      }
  796  
  797      /// Why it's stale, or nil if it can still be shown.
  798      public static func staleReason(ageSeconds: Double, repWordsSinceQueued: Int, repAskedSinceQueued: Bool,
  799                                     repTextSinceQueued: String = "") -> String? {
  800          if repAskedSinceQueued { return "the rep asked their own question since" }
  801          if repPivoted(repTextSinceQueued) { return "the rep pivoted in their own words since" }
  802          if repWordsSinceQueued >= maxRepWords { return "the rep said \(repWordsSinceQueued) words of their own since" }
  803          if ageSeconds > maxAge { return String(format: "waited %.0f s; the talk moved on", ageSeconds) }
  804          return nil
  805      }
  806  }
  807  
  808  /// Small, safe fixes done in code, so a line isn't sent back to Claude (about a second) for formatting.
  809  public enum LineRepair {
  810      public static let abbreviations: [String: String] = [
  811          "CRM": "customer system", "ROI": "return", "SDR": "rep", "SDRs": "reps", "BDR": "rep", "BDRs": "reps",
  812          "AE": "account rep", "AEs": "account reps", "KPI": "goal", "KPIs": "goals", "RevOps": "revenue team",
  813          "SaaS": "software", "B2B": "business", "ASAP": "soon", "FYI": "just so you know",
  814      ]
  815  
  816      /// The line with known abbreviations spelled out and em dashes turned to commas, or nil if an
  817      /// all-caps word we don't know is left (that one still goes back to Claude).
  818      public static func fix(_ line: String) -> String? {
  819          var out = line.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: ",")
  820          out = oneQuestion(out)
  821          for (abbr, plain) in abbreviations {
  822              out = out.replacingOccurrences(of: "\\b\(abbr)\\b", with: plain, options: .regularExpression)
  823          }
  824          let leftover = out.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 && $0.allSatisfy(\.isUppercase) && $0 != "AI" }
  825          return leftover.isEmpty ? out : nil
  826      }
  827  
  828      /// "Makes sense? How many reps?" -> "Makes sense. How many reps?": only the last question keeps its "?" (H4).
  829      public static func oneQuestion(_ line: String) -> String {
  830          guard let last = line.lastIndex(of: "?") else { return line }
  831          var out = ""
  832          for (i, ch) in zip(line.indices, line) { out.append(ch == "?" && i != last ? "." : ch) }
  833          return out
  834      }
  835  
  836      /// Fit a long line to `max` words without leaving a fragment (M7): keep the trailing question if it
  837      /// fits, else whole sentences from the start, else the first `max` words.
  838      public static func trimToFit(_ line: String, max: Int) -> String {
  839          let words = line.split(separator: " ")
  840          guard words.count > max else { return line }
  841          let sentences = line.split(omittingEmptySubsequences: true, whereSeparator: { ".!?".contains($0) })
  842          var ends: [String] = []
  843          var rest = Substring(line)
  844          for s in sentences {
  845              guard let r = rest.range(of: s) else { break }
  846              let after = rest[r.upperBound...]
  847              let punct = after.prefix(while: { ".!?".contains($0) })
  848              ends.append((s + punct).trimmingCharacters(in: .whitespaces))
  849              rest = after.dropFirst(punct.count)
  850          }
  851          if let q = ends.last, q.hasSuffix("?"), q.split(separator: " ").count <= max { return q }
  852          var kept: [String] = []
  853          for s in ends {
  854              if (kept + [s]).joined(separator: " ").split(separator: " ").count > max { break }
  855              kept.append(s)
  856          }
  857          return kept.isEmpty ? words.prefix(max).joined(separator: " ") : kept.joined(separator: " ")
  858      }
  859  }
  860  
  861  
  862  /// Prepare the next line while the rep is still talking off script, so it's ready the moment they
  863  /// pause (instead of dropping the old line at the pause and making them wait for a new one).
  864  public enum FollowRep {
  865      /// Should a new rep-led line be requested now, after the rep's latest words?
  866      /// - Not when they just asked a question (the prospect's answer comes next).
  867      /// - Not while they're reading the line on screen (they're on script).
  868      /// - Only once they've said 8+ of their own words since the last request.
  869      /// - `recentRepSpeech`: the rep's last couple of transcript chunks, so a line read across two
  870      ///   chunks still counts as on the line.
  871      public static func shouldPrepare(repJustSaid: String, recentRepSpeech: String, shownLine: String,
  872                                       shownLineDelivered: Bool, repWordsSinceLastAsk: Int) -> Bool {
  873          if repJustSaid.contains("?") { return false }
  874          if Delivery.onLine(line: shownLine, spoken: recentRepSpeech) && !shownLineDelivered { return false }
  875          return repWordsSinceLastAsk >= QueuedLine.maxRepWords
  876      }
  877  }
  878  
  879  
  880  /// The rep paused mid-sentence ("...take notes and keep"): they're still talking, even if the pause
  881  /// is longer than the usual 1.5 s window. A line never changes in the middle of their sentence.
  882  public enum RepTurn {
  883      public static let midSentenceHold = 3.0
  884      /// Words that leave a sentence hanging ("...take notes and keep", "...so", "...to the").
  885      public static let danglingWords: Set<String> = ["and", "or", "but", "so", "to", "the", "a", "an", "of", "with",
  886          "for", "in", "on", "at", "because", "like", "that", "which", "if", "then", "keep", "is", "are", "was",
  887          "we", "you", "i", "my", "your", "our", "um", "uh", "just", "kind", "sort", "what", "how",
  888          "do", "does", "have", "has", "get", "make", "need", "want", "be", "been", "about", "from", "by", "as", "really",
  889          "also", "very", "can", "could", "would", "will", "into", "onto", "our", "their", "this", "these", "those"]
  890  
  891      /// Still mid-sentence? Two signals, not punctuation alone: the transcriber's punctuation, and
  892      /// whether the last word leaves the sentence hanging. 3 s of silence ends it either way.
  893      public static func midSentence(lastFinal: String, secondsSince: Double) -> Bool {
  894          let t = lastFinal.trimmingCharacters(in: .whitespaces)
  895          guard !t.isEmpty, secondsSince < midSentenceHold else { return false }
  896          if t.hasSuffix("?") { return false } // a question is a finished turn
  897          let lastWord = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
  898          if danglingWords.contains(lastWord) { return true }
  899          return !(t.last.map { ".!".contains($0) } ?? true)
  900      }
  901  }
  902  
  903  
  904  /// The rep asked a yes/no question ("Can I get 30 seconds?", "Does that sound familiar?", "...yeah?"):
  905  /// the line for "yes" can be written before they answer. Open questions ("What do you use?") aren't.
  906  public enum RepQuestion {
  907      static let closedStarts: Set<String> = ["can", "could", "would", "will", "do", "does", "did", "is", "are", "was",
  908          "were", "have", "has", "mind", "may", "should", "okay", "ok", "sound", "fair", "right", "yeah", "correct", "cool", "make"]
  909  
  910      /// The last question in what the rep said, if it's a yes/no question.
  911      /// Check-ins ("Still with me?") aren't a real ask: a "yeah" to them isn't a yes to anything.
  912      static let checkIns = ["still with me", "you there", "can you hear me", "are you there", "did i lose you", "still there"]
  913  
  914      /// Questions often come through with no "?" ("You guys use Salesforce right"). Treat a tag ending as one.
  915      public static func asQuestion(_ text: String) -> String {
  916          let t = text.trimmingCharacters(in: .whitespaces)
  917          guard !t.hasSuffix("?") else { return t }
  918          let l = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!, "))
  919          let tags = [" right", " correct", " yeah", " yes", " no", " true", " fair"]
  920          return tags.contains(where: { l.hasSuffix($0) }) ? l + "?" : t
  921      }
  922  
  923      public static func closedQuestion(in raw: String) -> String? {
  924          let t = asQuestion(raw)
  925          guard t.hasSuffix("?") else { return nil }
  926          if checkIns.contains(where: { t.lowercased().contains($0) }) { return nil }
  927          let sentence = t.dropLast().split(whereSeparator: { ".?!".contains($0) }).last.map(String.init) ?? ""
  928          var words = sentence.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
  929          while let w = words.first, ["so", "and", "but", "well", "hey", "um", "uh", "like", "just"].contains(w) { words.removeFirst() }
  930          guard let first = words.first else { return nil }
  931          // A tag question ("You guys use Salesforce, right") is yes/no whatever its first word.
  932          let tagged = ["right", "correct", "yeah", "true", "huh"].contains(words.last ?? "") && words.count > 2
  933          return tagged || closedStarts.contains(first) ? sentence.trimmingCharacters(in: .whitespaces) + "?" : nil
  934      }
  935  }
  936  
  937  /// What kind of answer the prospect gave to the rep's yes/no question. Only a clear yes uses the
  938  /// line written ahead; no, unsure, or anything else gets a fresh answer from their real words.
  939  public enum ProspectReply {
  940      public enum Kind: String, Sendable { case yes, no, unsure, other }
  941      static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "correct", "right", "absolutely",
  942          "definitely", "totally", "go", "ahead", "fire", "away", "shoot", "of", "course", "please", "alright", "fine", "i", "guess", "it", "does", "is", "true"]
  943  
  944      public static func kind(_ text: String) -> Kind {
  945          let t = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
  946          let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
  947          guard !words.isEmpty else { return .other }
  948          if ["not sure", "maybe", "depends", "hmm", "i don't know", "kind of", "sort of", "we'll see"].contains(where: { t.contains($0) }) { return .unsure }
  949          if words.contains("no") || words.contains("nope") || words.contains("nah") || t.contains("not really")
  950              || t.contains("not interested") || t.contains("i'm good") || t.contains("don't") || t.contains("not now") { return .no }
  951          if words.count <= 5, words.allSatisfy(yesWords.contains),
  952             words.contains(where: { ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "correct", "right", "absolutely", "definitely", "go", "shoot", "alright", "fine", "true"].contains($0) }) {
  953              return .yes
  954          }
  955          return .other
  956      }
  957  }
  958  
  959  
  960  /// The conversational move Claude picks before writing the line. "silent" means the rep doesn't need
  961  /// a new line right now (they're mid-thought, or the line on screen still fits).
  962  public enum Move: String, CaseIterable, Sendable {
  963      case answer, clarify, discover, acknowledge, objection, close, silent
  964  
  965      /// "MOVE: discover" -> .discover. nil if the line isn't a MOVE line.
  966      public static func parse(_ line: String) -> Move? {
  967          let t = line.trimmingCharacters(in: .whitespaces)
  968          guard t.uppercased().hasPrefix("MOVE:") else { return nil }
  969          let word = t.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
  970              .split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
  971          return Move(rawValue: word) ?? (word == "handle" ? .objection : nil)
  972      }
  973  }
  974  
  975  extension RepTurn {
  976      /// The last word leaves the sentence hanging ("...and keep", "...so").
  977      public static func hangs(_ lastFinal: String) -> Bool {
  978          let t = lastFinal.trimmingCharacters(in: .whitespaces)
  979          if t.hasSuffix("?") { return false }
  980          let lastWord = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
  981          return danglingWords.contains(lastWord)
  982      }
  983  
  984      /// Is the rep still talking? Primary signals: words in the air, the transcriber's own end-of-speech
  985      /// call (it hears the pause in the audio), and whether the sentence is left hanging. The fixed
  986      /// windows (1.5 s after the last word, 3 s for an unfinished sentence) are only the fallback when
  987      /// the transcriber hasn't called it.
  988      public static func stillTalking(wordsInTheAir: Bool, endpointed: Bool, lastFinal: String,
  989                                      secondsSinceFinal: Double, inFallbackWindow: Bool) -> Bool {
  990          if wordsInTheAir { return true }
  991          let t = lastFinal.trimmingCharacters(in: .whitespaces)
  992          if hangs(lastFinal) { return secondsSinceFinal < midSentenceHold }
  993          if t.hasSuffix(",") { return secondsSinceFinal < midSentenceHold } // "So, essentially," is mid-thought
  994          if endpointed { return false }
  995          return inFallbackWindow || midSentence(lastFinal: lastFinal, secondsSince: secondsSinceFinal)
  996      }
  997  }
  998  
  999  
 1000  /// Is the prospect's reply an answer? A question back, a deflection or a refusal is not.
 1001  public enum AnswerEvidence {
 1002      public enum Kind: String, Sendable { case answer, counterQuestion, deflection, unsure, filler }
 1003      static let filler: Set<String> = ["uh", "um", "hmm", "mm", "mhm", "uh-huh", "huh"]
 1004      static let deflections = ["why are you asking", "why do you ask", "what do you mean", "who is this", "who's this",
 1005          "can't discuss", "cannot discuss", "not something i can", "rather not", "none of your", "not going to share",
 1006          "can't share", "cannot share", "why do you want to know", "what's this about", "what is this about", "can't say"]
 1007      static let unsure = ["not sure", "i don't know", "no idea", "hard to say", "it depends", "depends"]
 1008      static let whStarts: Set<String> = ["why", "what", "who", "how", "huh", "meaning", "sorry"]
 1009  
 1010      public static func kind(_ text: String) -> Kind {
 1011          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
 1012          let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
 1013          if words.isEmpty || words.allSatisfy(filler.contains) { return .filler }
 1014          if deflections.contains(where: { t.contains($0) }) { return .deflection }
 1015          if unsure.contains(where: { t.contains($0) }) { return .unsure }
 1016          if t.contains("?") { return .counterQuestion }
 1017          if words.count <= 3, let first = words.first, whStarts.contains(first) { return .counterQuestion }
 1018          return .answer
 1019      }
 1020  
 1021      public static func isAnswer(_ text: String) -> Bool { kind(text) == .answer }
 1022  }
 1023  
 1024  
 1025  /// Call memory rules (C3, M4).
 1026  public enum CallMemoryRules {
 1027      /// A background summary is kept only for the same call, and only if it covers more turns than the one stored.
 1028      public static func acceptSummary(currentCallID: String, summaryCallID: String, summaryCovers: Int, storedCovers: Int) -> Bool {
 1029          currentCallID == summaryCallID && summaryCovers > storedCovers
 1030      }
 1031  
 1032      /// First turn (index) sent word for word: everything the summary doesn't cover, and never fewer than the last `minRecent`.
 1033      public static func verbatimStart(totalTurns: Int, summaryCovers: Int, hasSummary: Bool, minRecent: Int = 10) -> Int {
 1034          guard hasSummary, totalTurns > 12 else { return 0 }
 1035          return max(0, min(summaryCovers, totalTurns - minRecent))
 1036      }
 1037  
 1038      /// Ask for a fresh summary when 6+ turns aren't covered (a late or failed one is retried).
 1039      public static func summaryDue(totalTurns: Int, summaryCovers: Int, inFlight: Bool) -> Bool {
 1040          !inFlight && totalTurns > 12 && totalTurns - summaryCovers >= 6
 1041      }
 1042  }
 1043  
 1044  
 1045  /// When to keep or drop the line written ahead for "yes" (H3).
 1046  public enum YesBranchRule {
 1047      /// Keep it through small talk after the question ("Just a quick one."); drop it for a new yes/no
 1048      /// question (a new one is written) or once the rep has said 8+ more words (the context moved on).
 1049      public static func keep(afterRepSaid text: String, wordsSinceQuestion: Int) -> Bool {
 1050          RepQuestion.closedQuestion(in: text) == nil && wordsSinceQuestion < QueuedLine.maxRepWords
 1051      }
 1052  
 1053      /// A ready yes line expires: older than this since the question, it's not used, even on a clear yes.
 1054      public static let maxAge = 12.0
 1055      /// If they say yes while it's still being written, wait at most this long, then answer fresh.
 1056      public static let maxWait = 1.2
 1057      public static func usable(ageSinceQuestion: Double) -> Bool { ageSinceQuestion <= maxAge }
 1058  }
 1059  
 1060  
 1061  /// The meeting is only "booked" when the prospect's words agree, not when a closing line is shown (N4).
 1062  public enum GoalEvidence {
 1063      static let agree = ["works for me", "that works", "sounds good", "send the invite", "send me the invite", "let's do",
 1064                          "book it", "put me down", "i'm in", "see you then", "that's perfect", "perfect, send"]
 1065      static let times = ["monday", "tuesday", "wednesday", "thursday", "friday", "tomorrow", "next week", " am", " pm", "o'clock"]
 1066  
 1067      public static func mentionsTime(_ text: String) -> Bool {
 1068          let t = " " + text.lowercased() + " "
 1069          // A clock time, not any number ("30 seconds" isn't a meeting time).
 1070          let clock = #"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s?(am|pm|a\.m\.|p\.m\.)|\bat \d{1,2}\b"#
 1071          return times.contains(where: { t.contains($0) }) || t.range(of: clock, options: .regularExpression) != nil
 1072      }
 1073  
 1074      static let negative = ["difficult", "can't", "cannot", "won't", "busy", "bad", "doesn't work", "don't", "tough", "booked", "out of"]
 1075      static let positive = ["works", "good", "fine", "great", "perfect", "okay", "ok", "sure", "yes", "yeah"]
 1076  
 1077      /// `afterTimeOffer`: the line they answered offered a time, so a plain "sure" agrees to it.
 1078      public static func confirms(_ prospectSaid: String, afterTimeOffer: Bool = false) -> Bool {
 1079          let t = " " + prospectSaid.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
 1080          let kind = ProspectReply.kind(prospectSaid)
 1081          if kind == .no || kind == .unsure { return false }
 1082          if t.contains(" but ") || t.contains("not ") || negative.contains(where: { t.contains($0) }) { return false }
 1083          if agree.contains(where: { t.contains($0) }) { return true }
 1084          // A day or time alone isn't agreement ("Tuesday is difficult"): it needs a positive word with it.
 1085          if times.contains(where: { t.contains($0) }) { return positive.contains(where: { t.contains(" \($0)") }) }
 1086          return kind == .yes && afterTimeOffer
 1087      }
 1088  }
 1089  
 1090  
 1091  /// The screen controller's two decisions, shared by the app and the replay tests (H7), so the tests
 1092  /// prove the code the app actually runs.
 1093  public enum CoachController {
 1094      public enum Offer: Equatable, Sendable { case show, queue, drop(String) }
 1095      public enum Promote: Equatable, Sendable { case wait, show, drop(String) }
 1096  
 1097      /// A queued line waits while the prospect is talking, so the rep's eyes stay on them.
 1098      /// It shows when they stop. (A line arriving right as they finish, like the ready "yes" line, still shows.) Exceptions live elsewhere and are untouched: openers, voicemail,
 1099      /// screeners, opt-out (the goodbye line), and a line the rep asked for with Space.
 1100      public static func waitForProspect(_ s: CoachSignals) -> Bool {
 1101          s.hasLine && s.prospectSpeaking && !s.doNotCall
 1102      }
 1103  
 1104      /// A finished line arrives. Openers, voicemails and the first line show at once; anything else
 1105      /// only if the line on screen can be replaced now, else it waits in the queue.
 1106      /// `staleReason`: why the rep has moved past this line since it was asked for (checked before showing too).
 1107      public static func offer(isOpenerOrVoicemail: Bool, firstLine: Bool, holdLine: Bool, signals: CoachSignals,
 1108                               staleReason: String? = nil) -> Offer {
 1109          if isOpenerOrVoicemail || firstLine { return .show }
 1110          if let why = staleReason { return .drop(why) }
 1111          return !holdLine && CoachMachine.canReplace(signals) ? .show : .queue
 1112      }
 1113  
 1114      /// A queued line, checked on each tick or when the rep's speech ends: wait, show, or drop as stale.
 1115      public static func promote(holdLine: Bool, signals: CoachSignals, ageSeconds: Double, repWordsSinceQueued: Int,
 1116                                 repAskedSinceQueued: Bool, repTextSinceQueued: String) -> Promote {
 1117          guard !holdLine, !waitForProspect(signals), CoachMachine.canReplace(signals) else { return .wait }
 1118          if let why = QueuedLine.staleReason(ageSeconds: ageSeconds, repWordsSinceQueued: repWordsSinceQueued,
 1119                                              repAskedSinceQueued: repAskedSinceQueued, repTextSinceQueued: repTextSinceQueued) {
 1120              return .drop(why)
 1121          }
 1122          return .show
 1123      }
 1124  }
 1125  
 1126  
 1127  /// A possible opt-out ("Don't call me back") waiting to see if a later time follows (Fix 1).
 1128  /// It is never dropped: it resolves as an opt-out unless a later time actually follows.
 1129  public enum PendingOptOut {
 1130      public enum Outcome: Equatable, Sendable { case optOut, callback, wait }
 1131      /// Long enough for "Don't call me back... until Tuesday" with a real pause. Restarts on any new prospect words.
 1132      public static let timeout = 2.5
 1133  
 1134      /// - later: what the prospect said after the phrase (may be empty).
 1135      /// - utteranceEnded / callEnded / secondsWaited: what has happened since. Any of them decides it.
 1136      public static func resolve(pending: String, later: String, utteranceEnded: Bool, callEnded: Bool, secondsWaited: Double) -> Outcome {
 1137          // A pause alone (utterance end with nothing after) doesn't decide it: only their next words, the call ending,
 1138          // or the full timeout. Deepgram's 1.0 s pause call came before the timer and cut the window short.
 1139          let decided = !later.isEmpty || callEnded || secondsWaited >= timeout
 1140          _ = utteranceEnded
 1141          guard decided else { return .wait }
 1142          let whole = (pending + " " + later).trimmingCharacters(in: .whitespaces)
 1143          return OptOut.matches(whole, isFinal: true) ? .optOut : .callback
 1144      }
 1145  }
 1146  
 1147  /// A pending goal counts down once per full prospect turn, not per transcript chunk (Fix 5).
 1148  public enum GoalPendingRule {
 1149      public static func turnsLeft(after turnsLeft: Int, confirmed: Bool) -> Int { confirmed ? 0 : max(0, turnsLeft - 1) }
 1150  }
 1151  
 1152  extension CoachController {
 1153      /// May an interrupting line (screener, nudge) show right now? Not over the rep's speech or reading (Fix 6).
 1154      public static func canInterrupt(signals: CoachSignals) -> Bool {
 1155          var s = signals
 1156          s.queuedIsForNewTopic = true
 1157          return !s.repSpeaking && CoachMachine.canReplace(s)
 1158      }
 1159  }
 1160  
 1161  
 1162  /// "Two no's and a go": one no gets one respectful question; two no's (or a no plus a sign-off) ends it (call 6).
 1163  public enum Rejection {
 1164      // Only clear no's. Reflex brush-offs ("we're good", "I'm good") don't count: they often open up right after.
 1165      static let nos = ["not interested", "not relevant", "no thanks", "no thank you", "not a fit",
 1166                        "not for us", "not really interested", "doesn't apply", "not something we need",
 1167                        "not the right fit", "not a good fit", "right fit for this"]
 1168      static let signOffs = ["yep thanks", "yep, thanks", "bye", "take care", "have a good one", "have a good day", "have a great day",
 1169                             "gotta go", "got to go", "thanks anyway", "thank you anyway"]
 1170  
 1171      public static func isNo(_ text: String) -> Bool {
 1172          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
 1173          // "...though our CRM data is a mess": a no that opens a door isn't a no.
 1174          if [" but ", " though", " however", " although"].contains(where: { t.contains($0) }) { return false }
 1175          if nos.contains(where: { t.contains($0) }) { return true }
 1176          // "I don't think this is really relevant", "this isn't relevant to us"
 1177          // "I don't know that I'm interested", "I don't know that I'm the right fit" (Nov 20): soft no's.
 1178          let negated = ["don't think", "don't know that", "don't know if", "not", "isn't", "doesn't"].contains { t.contains($0) }
 1179          return negated && (t.contains("relevant") || t.contains("interested") || t.contains("a fit") || t.contains("right fit"))
 1180      }
 1181  
 1182      public static func isSignOff(_ text: String) -> Bool {
 1183          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: ".", with: "")
 1184          return signOffs.contains { t.contains($0) }
 1185      }
 1186  
 1187      /// Done: two no's, or a no that comes with a sign-off.
 1188      public static func callOver(nosSoFar: Int, latest: String) -> Bool {
 1189          nosSoFar >= 2 || (nosSoFar >= 1 && isSignOff(latest))
 1190      }
 1191  }
 1192  
 1193  /// When to write a line from the rep's own talk (call 6: 12 wasted calls on a monologue).
 1194  public enum FollowRepLimit {
 1195      public static let minWords = 15
 1196      /// At most one per stretch of rep talk (until the prospect speaks again), and only after 15+ of their words.
 1197      public static func allowed(repWordsSinceLastAsk: Int, followsThisStretch: Int) -> Bool {
 1198          followsThisStretch == 0 && repWordsSinceLastAsk >= minWords
 1199      }
 1200  }
 1201  
 1202  
 1203  /// A line with a slot still unfilled ("[Name]", "[Day]") never shows (script rule: token fill).
 1204  public enum TokenFill {
 1205      public static func hasOpenSlot(_ line: String) -> Bool {
 1206          line.range(of: #"\[[^\]]{1,30}\]"#, options: .regularExpression) != nil
 1207      }
 1208  }
 1209  
 1210  
 1211  /// Haiku vs Sonnet scoreboard math: is a difference real or luck?
 1212  public enum ModelTest {
 1213      /// Two-proportion z score. |z| >= 1.96 is about 95% sure the difference is real.
 1214      public static func z(_ a: Int, of n1: Int, vs b: Int, of n2: Int) -> Double {
 1215          guard n1 > 0, n2 > 0 else { return 0 }
 1216          let p1 = Double(a) / Double(n1), p2 = Double(b) / Double(n2)
 1217          let p = Double(a + b) / Double(n1 + n2)
 1218          let se = (p * (1 - p) * (1 / Double(n1) + 1 / Double(n2))).squareRoot()
 1219          return se == 0 ? 0 : (p1 - p2) / se
 1220      }
 1221  
 1222      /// "Haiku wins", "Sonnet wins" or "too close to call yet".
 1223      public static func verdict(_ a: Int, of n1: Int, vs b: Int, of n2: Int, names: (String, String)) -> String {
 1224          let score = z(a, of: n1, vs: b, of: n2)
 1225          if n1 < 20 || n2 < 20 { return "not enough calls yet (need 20+ each)" }
 1226          if score >= 1.96 { return "\(names.0) wins (95% sure)" }
 1227          if score <= -1.96 { return "\(names.1) wins (95% sure)" }
 1228          return "too close to call yet"
 1229      }
 1230  }
 1231  
 1232  
 1233  /// What the prospect's turn is doing, decided in code before any line is picked. Higher-priority
 1234  /// situations (opt-out, ending, a direct question, a no) outrank the script's stage.
 1235  public enum ConversationIntent: String, Sendable {
 1236      /// rejection = a clear refusal ("not interested", "no thanks", "not a fit"): no more sales questions.
 1237      /// objection = a concern or reflex brush-off ("we use Gong", "no time", "send me info", "we're good"):
 1238      /// one relevant follow-up is fine.
 1239      case optOut, ending, question, rejection, objection, other
 1240  
 1241      static let questionStarts: Set<String> = ["what", "who", "why", "how", "where", "when", "which", "is", "are", "do",
 1242                                               "does", "can", "could", "would", "will", "did"]
 1243      static let greetings: Set<String> = ["hello", "hi", "hey", "yes", "yeah", "speaking", "this", "is", "it"]
 1244  
 1245      public static func classify(_ said: String) -> ConversationIntent {
 1246          let t = said.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
 1247          let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
 1248          if OptOut.matches(said) { return .optOut }
 1249          if ObjectionTracker.detect(said) == "ending the call" || Rejection.isSignOff(said) { return .ending }
 1250          if Rejection.isNo(said) { return .rejection }
 1251          // "Hello?" is a greeting, not a question.
 1252          if words.count <= 3, words.allSatisfy(greetings.contains) { return .other }
 1253          if t.contains("?") || AnswerEvidence.kind(said) == .deflection { return .question }
 1254          if let first = words.first, questionStarts.contains(first), words.count >= 3 { return .question }
 1255          if ObjectionTracker.detect(said) != nil { return .objection }
 1256          return .other
 1257      }
 1258  }
 1259  
 1260  /// The rep is the caller. A line must never have the rep claim the prospect's role (Nov 20:
 1261  /// "Yes, I'm the one who decides on those tools.").
 1262  public enum RoleCheck {
 1263      static let claims = ["i'm the one who decides", "i am the one who decides", "i'm the one that decides",
 1264                           "i'm the decision maker", "i am the decision maker", "i'm the decision-maker",
 1265                           "i make the decisions", "i make those decisions", "i decide on", "i'm the one who handles",
 1266                           "i'm in charge of", "i am in charge of", "i'm the right person", "i am the right person",
 1267                           "i'm the one in charge", "i own that", "i handle those", "i handle that"]
 1268  
 1269      public static func speaksAsProspect(_ line: String) -> Bool {
 1270          let t = line.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
 1271          return claims.contains { t.contains($0) }
 1272      }
 1273  }
 1274  
 1275  
 1276  /// Is a new question the same as one already asked and answered? Compares meaning words (stemmed),
 1277  /// not wording: "What happens with notes after a call?" and "Where do your call notes end up?" overlap.
 1278  public enum Repeats {
 1279      static let questionWords: Set<String> = ["what", "who", "why", "how", "when", "where", "which", "does", "did", "are", "can",
 1280                                              "could", "would", "will", "should", "tell", "some", "about", "much", "many"]
 1281  
 1282      /// Words that don't carry the point of a question (they pad paraphrases or are in every question).
 1283      static let filler: Set<String> = ["too", "also", "really", "just", "ups", "roughly", "today", "those", "these", "there",
 1284                                        "into", "out", "team", "people", "rep", "folk", "anyone", "everyone", "kind", "sort"]
 1285      /// A few same-meaning words seen in real paraphrases (THINK/SAY matrix). Small on purpose.
 1286      static let same: [String: String] = [
 1287          "crm": "salesforce", "using": "use", "used": "use", "usage": "use", "adoption": "use", "adopt": "use",
 1288          "stopp": "block", "stop": "block", "blocking": "block", "stall": "block", "stuck": "block", "way": "block",
 1289          "hour": "time", "made": "cause", "got": "cause", "get": "cause", "led": "cause", "rollout": "roll",
 1290          "care": "handle", "manage": "handle",
 1291      ]
 1292  
 1293      static func meaning(_ text: String) -> Set<String> {
 1294          Set(Delivery.words(text).map { same[$0] ?? $0 }.filter { !questionWords.contains($0) && !filler.contains($0) })
 1295      }
 1296  
 1297      /// At least 60% of the smaller question's meaning words are in the other one (and at least two words).
 1298      public static func same(_ a: String, _ b: String) -> Bool {
 1299          let x = meaning(a), y = meaning(b)
 1300          guard x.count >= 2, y.count >= 2 else { return false }
 1301          let shared = x.intersection(y).count
 1302          return Double(shared) / Double(min(x.count, y.count)) >= 0.6
 1303      }
 1304  }
 1305  
```


## `mac/Sources/CoachCore/Think.swift`

```swift
    1  import Foundation
    2  
    3  /// THINK mode (on by default): the card shows one short thought the rep can say
    4  /// as-is or in their own words. The full SAY line stays one shortcut away. Script rows always show in full.
    5  public enum Think {
    6      public static let defaultsKey = "thinkCoach"
    7      /// On unless turned off in Settings.
    8      public static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    9  
   10      /// The prompt line asking for the thought. Empty when THINK mode is off, so the live prompt is unchanged.
   11      public static func promptLine(enabled: Bool) -> String {
   12          guard enabled else { return "" }
   13          return """
   14          THINK: <one quick coaching nudge for the rep, usually 5 to 12 simple words>
   15            THINK rules (a skilled coach whispering the next move, not a script):
   16            - Pick the MOVE first, then write THINK for that move. THINK and SAY must be the same move and the same question.
   17            - Before you write it, decide the ONE most valuable thing still unknown: a concrete example of something
   18              broad, the cause of a problem they confirmed, how they do it today, what it costs them, who decides, or
   19              (when interest and fit are real) a meeting. Not a fixed order. Pick what this conversation needs.
   20            - Ask about their actual tools, process and words. Never assume a problem because it is common in their industry.
   21            - Usually ONE short question the rep can say aloud. Example ladder, they said "our team won't use Salesforce":
   22              weak "What's your biggest challenge?" / better "What's stopping your team from using Salesforce?" /
   23              best when you need the root cause "What happens when your team tries to use it?" (it asks for a real example).
   24            - When a question is the wrong move, a short instruction instead: they asked what the call is about
   25              -> "Explain the free AI health check." They said no again -> "Thank them and end the call." They are
   26              ending the call -> "Thank them. Don't push." Never both a question and an instruction in one THINK.
   27            - Answer their direct question first. An objection ("we use Gong", "no time") can get one relevant question.
   28              A clear no ("not interested", "not a fit") gets no sales question: acknowledge, at most offer an easy exit.
   29            - Never repeat a question they already answered, declined or deflected. Skip what the call already established.
   30            - Never vague coaching words: no "explore", "probe", "find the gap", "handle the objection", "qualify".
   31            - Everyday words: "your team", "call notes", "follow-ups". Never "your reps".
   32            - Good: "Does Gong handle your follow-ups too?"  Bad: "Who's the right person? Ask for a name."
   33            - Good: "Who handles sales tools there?"  Bad: "Explore whether Gong handles CRM updates."
   34  
   35          """
   36      }
   37  
   38      /// Coaching jargon that needs translating mid-call: falls back to SAY.
   39      static let jargon = ["explore", "probe", "dig ", "drive ", "uncover", "leverage", "qualify", "find the gap",
   40                           "handle the objection", "handle objection", "identify friction", "friction"]
   41  
   42      /// Words a THINK that states (not asks) a pain would be assuming, unless the prospect said them.
   43      static let assumedPain = ["wasting", "struggling", "losing hours", "drowning", "frustrated", "painful", "a mess"]
   44  
   45      /// A usable thought on its own, or nil (then the card falls back to SAY).
   46      public static func valid(_ think: String) -> String? {
   47          let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
   48          let words = t.split(whereSeparator: { $0 == " " }).count
   49          guard words >= 2, words <= 16, !t.hasPrefix("<"), !t.uppercased().hasPrefix("SAY") else { return nil }
   50          let low = t.lowercased()
   51          if jargon.contains(where: { low.contains($0) }) { return nil }
   52          // A question to say plus an instruction to the rep ("Who's the right person? Ask for a name.").
   53          if let q = t.firstIndex(of: "?"), t[t.index(after: q)...].contains(where: { $0.isLetter }) { return nil }
   54          if RoleCheck.speaksAsProspect(t) { return nil }
   55          return t
   56      }
   57  
   58      /// Why this THINK should not reach the screen in this conversation (empty = fine). Rules only, no model call.
   59      /// `sayLine` is the SAY that came with it. Each problem string is also what a retry is told to fix.
   60      public static func problems(think: String, say: String, move: String, intent: ConversationIntent, objectionKind: String?,
   61                                  latestProspect: String, recentText: String, scriptText: String, answeredQuestions: [String]) -> [String] {
   62          let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
   63          guard !t.isEmpty else { return ["THINK is missing: write one short coaching nudge"] }
   64          guard valid(t) != nil else { return ["THINK isn't usable: one clear move, 2 to 16 simple words, no jargon, no question plus instruction"] }
   65          var out: [String] = []
   66          let isQuestion = t.hasSuffix("?")
   67          // They're done: no question to ask.
   68          if isQuestion, [.ending, .optOut].contains(intent) {
   69              out.append("THINK asks a question but they're ending the call: thank them, don't push")
   70          }
   71          // A clear no: no sales question. The only question allowed is the exit itself (move close: "Can I send one email?").
   72          if isQuestion, intent == .rejection, move != "close" {
   73              out.append("THINK asks a question after a clear no: acknowledge it, at most offer an easy exit")
   74          }
   75          if intent == .rejection, ["discover", "clarify", "objection"].contains(move) {
   76              out.append("MOVE \(move) after a clear no: acknowledge or close instead")
   77          }
   78          // A direct question from them comes first: THINK must answer it, not discover.
   79          if intent == .question, move == "discover" {
   80              out.append("they asked a direct question: THINK must answer it first (MOVE answer), not start discovery")
   81          }
   82          // Poor moves for the objection they raised (a line can pass every other check and still be bad coaching).
   83          if objectionKind == "happy as is", move == "close" {
   84              out.append("MOVE close on a brush-off (\"we're all set\"): acknowledge, then one light question; offer a meeting only if they open up")
   85          }
   86          if ["no time", "call later"].contains(objectionKind ?? ""), ["discover", "clarify"].contains(move) {
   87              out.append("MOVE \(move) when they have no time: ask for a better time, don't start discovery")
   88          }
   89          // Discovery needs a question; a pure statement or instruction for MOVE discover is the wrong coaching.
   90          if move == "discover", !isQuestion {
   91              out.append("MOVE is discover but THINK isn't a question: write the one question to ask")
   92          }
   93          if isQuestion {
   94              // Already answered: same meaning as a question the rep asked and got an answer to.
   95              if let again = answeredQuestions.first(where: { Repeats.same($0, t) }) {
   96                  out.append("THINK repeats a question already answered: \"\(again)\"")
   97              }
   98              // Unrelated topic: a discovery question with nothing from this conversation or the script. Next steps
   99              // (a time, who joins, a referral, sending what they asked for) are new topics by nature, so they're fine.
  100              let mine = Repeats.meaning(t)
  101              if !mine.isEmpty, ["discover", "clarify"].contains(move) {
  102                  let known = Repeats.meaning(recentText).union(Repeats.meaning(scriptText))
  103                  if mine.intersection(known).isEmpty { out.append("THINK is about something that hasn't come up: ground it in what they said") }
  104              }
  105          } else {
  106              // States a pain as theirs when they never said it.
  107              let low = t.lowercased(), said = latestProspect.lowercased() + " " + recentText.lowercased()
  108              if let w = assumedPain.first(where: { low.contains($0) && !said.contains($0) }) {
  109                  out.append("THINK assumes a problem they haven't named (\"\(w)\"): ask, don't state it")
  110              }
  111          }
  112          if !agrees(think: t, say: say, move: move) {
  113              out.append("THINK and SAY aren't the same move: SAY should say what THINK asks or explains")
  114          }
  115          return out
  116      }
  117  
  118      /// The kind of question: "qty" (how many / much / long / often), "who", "when", "where", "which",
  119      /// "open" (what / why / how), or "yn". "What's blocking it?" and "Why aren't they using it?" are both open.
  120      static func group(_ word: String) -> String? {
  121          switch word {
  122          case "what", "why", "how": return "open"
  123          case "who", "when", "where", "which": return word
  124          default: return nil
  125          }
  126      }
  127  
  128      static func questionClass(_ q: String) -> String {
  129          let low = q.lowercased()
  130          if ["how many", "how much", "how long", "how often"].contains(where: { low.contains($0) }) { return "qty" }
  131          let first = low.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
  132          return group(first) ?? "yn"
  133      }
  134  
  135      /// Every kind a question could be read as ("If this went well, what would that look like?" is open too).
  136      static func questionClasses(_ q: String) -> Set<String> {
  137          let low = q.lowercased()
  138          var out: Set<String> = [questionClass(q)]
  139          if out.contains("qty") { return out }
  140          for w in low.split(whereSeparator: { !$0.isLetter }).map(String.init) { if let g = group(w) { out.insert(g) } }
  141          return out
  142      }
  143  
  144      /// THINK and SAY must be the same move. Not "share any word": the same kind of question, and most of
  145      /// THINK's meaning inside SAY's question; or, for an instruction, at least one shared meaning word.
  146      public static func agrees(think: String, say: String, move: String = "") -> Bool {
  147          let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
  148          if t.hasSuffix("?") {
  149              // SAY's questions: the one that best matches THINK.
  150              let sayQuestions = QuestionTracker.questions(in: say)
  151              guard !sayQuestions.isEmpty else { return false }
  152              let mine = Repeats.meaning(t)
  153              return sayQuestions.contains { q in
  154                  guard questionClasses(q).contains(questionClass(t)) else { return false }
  155                  let theirs = Repeats.meaning(q)
  156                  guard !mine.isEmpty else { return true }
  157                  return Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.5
  158              }
  159          }
  160          // An instruction describes the move; SAY carries it out. Discovery needs a question, so no.
  161          if move == "discover" { return false }
  162          // Stop-type instructions ("Thank them and end the call", "Don't push"): SAY must not go on asking.
  163          let low = t.lowercased()
  164          let stop = ["thank them", "end the call", "don't push", "do not push", "acknowledge", "let them go", "wrap up"]
  165          if move == "acknowledge" || (move == "close" && stop.contains(where: { low.contains($0) })) { return !say.contains("?") }
  166          // Answer or explain: SAY must be about the same thing.
  167          let mine = Repeats.meaning(t)
  168          return mine.isEmpty || !mine.intersection(Repeats.meaning(say)).isEmpty
  169      }
  170  
  171      /// What the big line shows. Script rows (exact) and missing or bad thoughts show SAY; the rep can ask for SAY anytime.
  172      public static func primary(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool, move: String = "") -> String {
  173          guard enabled, !exact, !showFull, let t = valid(think), agrees(think: t, say: say, move: move) else { return say }
  174          return t
  175      }
  176  }
  177  
```


## `mac/Sources/CoachCore/LineLook.swift`

```swift
    1  import Foundation
    2  
    3  /// How a line looks on the card: a one-glance move label, and which part to make stand out.
    4  /// Display only. It never changes the words, the model, or when a line shows.
    5  public enum LineLook {
    6      /// The label above the line, from the move the model already picks. Empty move = "SAY THIS" (no guessing).
    7      public static func label(move: String, exact: Bool) -> String {
    8          let base: String
    9          switch move.lowercased().trimmingCharacters(in: .whitespaces) {
   10          case "discover": base = "ASK"
   11          case "clarify": base = "CHECK WHAT THEY MEANT"
   12          case "answer": base = "ANSWER THEM"
   13          case "acknowledge": base = "ACKNOWLEDGE"
   14          case "objection": base = "HANDLE THE PUSHBACK"
   15          case "close": base = "CLOSE"
   16          default: base = "SAY THIS"
   17          }
   18          return exact ? base + " · EXACT" : base
   19      }
   20  
   21      /// The line split so its one question stands out: (before, question, after).
   22      /// Only when the line has exactly one sentence ending in "?" and some other text too.
   23      /// Anything else returns nil and the whole line shows plain. No guessing.
   24      public static func emphasis(_ say: String) -> (before: String, key: String, after: String)? {
   25          let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
   26          guard text.filter({ $0 == "?" }).count == 1, let q = text.firstIndex(of: "?") else { return nil }
   27          // Start of the question's sentence: just after the last ". ", "! " before the "?".
   28          var start = text.startIndex
   29          var i = text.startIndex
   30          while i < q {
   31              let next = text.index(after: i)
   32              if ".!".contains(text[i]), next < q, text[next] == " " { start = text.index(after: next) }
   33              i = next
   34          }
   35          let end = text.index(after: q)
   36          let before = String(text[..<start]), key = String(text[start..<end]), after = String(text[end...])
   37          guard !before.trimmingCharacters(in: .whitespaces).isEmpty || !after.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
   38          return (before, key, after)
   39      }
   40  }
   41  
```


## `mac/Sources/CoachCore/CallAttempt.swift`

```swift
    1  import Foundation
    2  
    3  /// What a dial turned out to be. Decided once, by fixed rules, when the call ends.
    4  /// The coaching model never decides it, so Haiku vs Sonnet can't change the numbers.
    5  public enum CallOutcome: String, Codable, Sendable, CaseIterable {
    6      case humanProspect, humanGatekeeper, voicemail, phoneTree, screenerOnly, noAnswer, invalidNumber, failedConnection, unknown
    7  
    8      /// A real person answered (the prospect or a gatekeeper).
    9      public var humanAnswered: Bool { self == .humanProspect || self == .humanGatekeeper }
   10      /// The prospect themself was reached. Gatekeepers don't count.
   11      public var prospectReached: Bool { self == .humanProspect }
   12  }
   13  
   14  /// One call attempt, from dial to hang-up. The single record the Pickup numbers, the call plan
   15  /// (DialHistory) and the Salesforce checkbox all read from.
   16  public struct CallAttempt: Codable, Sendable, Equatable {
   17      /// One prospect-side utterance, tagged by rules at the moment it was heard.
   18      public struct Heard: Codable, Sendable, Equatable {
   19          public enum Tag: String, Codable, Sendable { case speech, menu, screener }
   20          public var text: String
   21          public var at: Date
   22          public var tag: Tag
   23          public init(text: String, at: Date, tag: Tag = .speech) { self.text = text; self.at = at; self.tag = tag }
   24      }
   25  
   26      public let attemptID: String
   27      public let leadID: String?
   28      public let campaign: String?
   29      public let startedAt: Date
   30      /// The phone confirmed the call was placed (Aircall showed it, or any call audio or words came through).
   31      public var placedAt: Date?
   32      /// First words from a real person (not a menu, screener, recording or echo).
   33      public var callConnectedAt: Date?
   34      public var callEndedAt: Date?
   35      public var outcome: CallOutcome?
   36      /// Which rule decided the outcome, for the trace.
   37      public var classificationSource = ""
   38      /// A real conversation with the prospect: 3+ of their turns, or 45+ s from their first words to hang-up.
   39      public var conversation = false
   40      /// The live model this call used (logged only; never used to classify).
   41      public var liveModel: String?
   42  
   43      // Facts, filled in as the call happens.
   44      public var heard: [Heard] = []
   45      public var repSaid: [Heard] = []
   46      public var voicemailByRule = false
   47      public var badNumber = false
   48      public var phoneTree = false
   49      public var screenerSeen = false
   50      public var screenerOpen = false
   51      /// What the model labelled the call (Voicemail, Gatekeeper...). A hint for the trace only.
   52      public var modelStages: [String] = []
   53  
   54      public init(attemptID: String = UUID().uuidString, leadID: String?, campaign: String?, startedAt: Date = Date(), liveModel: String? = nil) {
   55          self.attemptID = attemptID; self.leadID = leadID; self.campaign = campaign; self.startedAt = startedAt; self.liveModel = liveModel
   56      }
   57  
   58      public var finalized: Bool { outcome != nil }
   59  
   60      // MARK: Lifecycle events
   61  
   62      public mutating func placed(at: Date = Date()) { if placedAt == nil { placedAt = at } }
   63      public mutating func prospect(_ text: String, at: Date = Date(), tag: Heard.Tag = .speech) {
   64          guard !finalized, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
   65          placed(at: at)
   66          heard.append(Heard(text: text, at: at, tag: screenerOpen && tag == .speech ? .screener : tag))
   67      }
   68      public mutating func rep(_ text: String, at: Date = Date()) {
   69          guard !finalized, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
   70          placed(at: at)
   71          repSaid.append(Heard(text: text, at: at))
   72      }
   73      public mutating func voicemailDetected() { if !finalized { voicemailByRule = true } }
   74      /// A phone menu answered. Menus answer first, so words heard before this were the menu; a
   75      /// voicemail guess made on the menu's words is cancelled.
   76      public mutating func phoneTreeDetected() {
   77          guard !finalized else { return }
   78          phoneTree = true
   79          voicemailByRule = false
   80          for i in heard.indices where heard[i].tag == .speech { heard[i].tag = .menu }
   81      }
   82      /// A number that doesn't work (its recording can sound like a voicemail, so that guess is cancelled).
   83      public mutating func badNumberDetected() { if !finalized { badNumber = true; voicemailByRule = false } }
   84      /// A call screener answered. Screeners answer first, so earlier words were the screener.
   85      public mutating func screenerStarted() {
   86          guard !finalized else { return }
   87          screenerSeen = true
   88          screenerOpen = true
   89          for i in heard.indices where heard[i].tag == .speech { heard[i].tag = .screener }
   90      }
   91      /// A person came on after the screener. `personSaid`: their words, already heard while the screener
   92      /// was still open, are moved back to a person.
   93      public mutating func screenerEnded(personSaid: String = "") {
   94          screenerOpen = false
   95          let said = Self.norm(personSaid).joined(separator: " ")
   96          guard !said.isEmpty else { return }
   97          var i = heard.count - 1
   98          while i >= 0, heard[i].tag == .screener, said.contains(Self.norm(heard[i].text).joined(separator: " ")) {
   99              heard[i].tag = .speech
  100              i -= 1
  101          }
  102      }
  103      public mutating func modelStage(_ stage: String) { if !finalized, !stage.isEmpty { modelStages.append(stage) } }
  104  
  105      /// Decides the outcome once. Returns false if it was already decided (so nothing is counted twice).
  106      @discardableResult
  107      public mutating func finalize(endedAt: Date = Date(), source: String? = nil) -> Bool {
  108          guard !finalized else { return false }
  109          callEndedAt = endedAt
  110          let (o, why, human) = Self.classify(self)
  111          outcome = o
  112          classificationSource = source.map { "\($0): \(why)" } ?? why
  113          callConnectedAt = human.first?.at
  114          if o.prospectReached, let first = human.first?.at {
  115              conversation = human.count >= 3 || endedAt.timeIntervalSince(first) >= 45
  116          }
  117          return true
  118      }
  119  
  120      // MARK: Rules
  121  
  122      /// Words only a phone menu says (checked on what's heard once a menu was detected).
  123      static let menuWords = ["press", "dial", "option", "options", "extension", "menu", "directory", "pound",
  124                              "para", "español", "to reach", "please listen", "your party", "hold for the next"]
  125  
  126      static let gatekeeperPhrases = [
  127          "who's calling", "who is calling", "may i ask who", "can i ask who", "what is this regarding", "what's this regarding",
  128          "what is this about", "what's this about", "not available", "isn't available", "not in the office", "isn't in",
  129          "is not in", "he's out", "she's out", "they're out", "take a message", "front desk", "reception",
  130          "thank you for calling", "thanks for calling", "how may i direct", "how can i direct", "can i tell him", "can i tell her",
  131      ]
  132      static let transferPhrases = [
  133          "transfer you", "put you through", "connect you", "one moment", "hold please", "please hold",
  134          "let me get", "let me grab", "let me see if",
  135      ]
  136      static let wrongNumberPhrases = [
  137          "wrong number", "no one here by that name", "nobody here by that name", "doesn't work here",
  138          "does not work here", "no longer works here", "not this number",
  139      ]
  140  
  141      /// True when the prospect-side words are really the rep's own voice coming back (echo).
  142      static func isEcho(_ h: Heard, rep: [Heard]) -> Bool {
  143          let words = Set(norm(h.text))
  144          guard words.count >= 2 else { return false }
  145          return rep.contains { r in
  146              abs(r.at.timeIntervalSince(h.at)) <= 2.5 && Double(words.intersection(Set(norm(r.text))).count) / Double(words.count) >= 0.7
  147          }
  148      }
  149  
  150      static func norm(_ s: String) -> [String] {
  151          s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
  152      }
  153  
  154      static func has(_ text: String, _ phrases: [String]) -> Bool {
  155          let t = " " + norm(text).joined(separator: " ") + " "
  156          return phrases.contains { t.contains(" " + $0 + " ") }
  157      }
  158  
  159      /// (outcome, the rule that decided it, the real-person utterances).
  160      public static func classify(_ a: CallAttempt) -> (CallOutcome, String, [Heard]) {
  161          guard a.placedAt != nil else { return (.failedConnection, "never placed", []) }
  162          // The voicemail rules only fire on words a machine says ("leave a message after the tone"),
  163          // so a voicemail rule wins: the greeting's own words are not a person.
  164          if a.voicemailByRule { return (.voicemail, "voicemail rule", []) }
  165          let human = a.heard.filter {
  166              $0.tag == .speech && !isEcho($0, rep: a.repSaid) && !(a.phoneTree && has($0.text, menuWords))
  167          }
  168          if human.isEmpty {
  169              if a.voicemailByRule { return (.voicemail, "voicemail rule", []) }
  170              if a.phoneTree { return (.phoneTree, "phone menu, no person after it", []) }
  171              if a.screenerSeen { return (.screenerOnly, "screener only, no person after it", []) }
  172              if a.badNumber { return (.invalidNumber, "bad number rule", []) }
  173              let echoOnly = a.heard.contains { $0.tag == .speech }
  174              return (.noAnswer, echoOnly ? "only the rep's own voice came back" : "no one spoke", [])
  175          }
  176          if human.contains(where: { has($0.text, wrongNumberPhrases) }) { return (.humanGatekeeper, "wrong number", human) }
  177          let lastTransfer = human.lastIndex { has($0.text, transferPhrases) }
  178          let sawGatekeeper = human.contains { has($0.text, gatekeeperPhrases) } || lastTransfer != nil
  179          if !sawGatekeeper { return (.humanProspect, a.phoneTree ? "person after the phone menu" : a.screenerSeen ? "person after the screener" : "person spoke", human) }
  180          if let i = lastTransfer, i < human.count - 1 { return (.humanProspect, "gatekeeper put them through", human) }
  181          if lastTransfer == nil, let firstGK = human.firstIndex(where: { has($0.text, gatekeeperPhrases) }), firstGK > 0,
  182             !has(human[0].text, gatekeeperPhrases) {
  183              // The prospect spoke first, then asked who's calling: still the prospect.
  184              return (.humanProspect, "prospect asked who's calling", human)
  185          }
  186          return (.humanGatekeeper, "gatekeeper only", human)
  187      }
  188  }
  189  
  190  /// The three call numbers, per dial. Built from finished attempts only.
  191  public struct PickupStats: Equatable, Sendable {
  192      public var placedDials = 0
  193      public var humanAnswered = 0
  194      public var conversations = 0
  195      public var leadsAttempted = 0
  196      public var leadsReached = 0
  197  
  198      public init(_ attempts: [CallAttempt]) {
  199          let done = attempts.filter { $0.finalized && $0.placedAt != nil }
  200          placedDials = done.count
  201          humanAnswered = done.filter { $0.outcome?.humanAnswered == true }.count
  202          conversations = done.filter(\.conversation).count
  203          let leads = Set(done.compactMap(\.leadID))
  204          leadsAttempted = leads.count
  205          leadsReached = Set(done.filter { $0.outcome?.prospectReached == true }.compactMap(\.leadID)).count
  206      }
  207  
  208      public var humanAnswerRate: Double? { placedDials == 0 ? nil : Double(humanAnswered) / Double(placedDials) }
  209      public var prospectReachRate: Double? { leadsAttempted == 0 ? nil : Double(leadsReached) / Double(leadsAttempted) }
  210      public var conversationRate: Double? { placedDials == 0 ? nil : Double(conversations) / Double(placedDials) }
  211  }
  212  
```


## `mac/Sources/ClarityLiveCoach/CoachPrompt.swift`

```swift
    1  import CoachCore
    2  import Foundation
    3  
    4  // MARK: - Prompt
    5  
    6  enum CoachPrompt {
    7      static let stages = ["Opener", "Screener", "Gatekeeper", "Voicemail", "Discovery", "Value", "Objection", "Closing", "Goal reached", "Exit"]
    8  
    9      /// Stays byte-for-byte the same for a campaign, so Claude can cache it.
   10      static func system(for campaign: Campaign) -> String {
   11          """
   12          You are a world-class cold calling coach sitting next to a sales rep during a live phone call.
   13          Only the rep sees what you write; you never speak to the prospect. The rep makes about 100 dials a day
   14          and can get overwhelmed. Make the next sentence obvious so they can stay calm and present.
   15  
   16          The transcript is labeled Rep and Prospect. It is live speech-to-text, so expect small errors
   17          ("Claude" is often heard as "cloud" or "clod"). Read words in context.
   18  
   19          How to coach:
   20          1. One line, \(LineBudget.promptMax) words at most, easy to say out loud on the first read. A question is the
   21             right ending when you're learning about them (discover, clarify, objection). When you're answering,
   22             acknowledging or closing, a plain statement is fine; never add a question just to have one.
   23          2. Sound like a confident, friendly human. Plain words, contractions, no jargon, no hype. A short question beats a pitch.
   24          3. Answer what the prospect just said. Never contradict a need they stated or ask what they already answered.
   25             A direct question gets a plain answer first. Add a question only if it follows naturally from that answer,
   26             never one that changes the subject.
   27          4. Objections: acknowledge in a few words, then ask a curious question. Never argue.
   28          5. Never invent a fact, number, client name, price, offer, feature or result. Use only what the campaign gives.
   29          6. Move toward the campaign objective. Once reached, help the rep confirm details and wrap up. Stop selling.
   30          7. Two clear no's, a request not to be called, or no fit: help the rep exit politely.
   31          8. An automated call screener ("say your name and why you're calling"): the rep says only
   32             "This is [rep's first name] calling for [prospect's first name]." Then waits. Stage: Screener.
   33          9. If talk is flowing well or the rep is mid-thought, the move is silent.
   34  
   35          What decides the next move, in this order (the first one that applies wins):
   36          1. An opt-out or a request not to be called: end it, no more questions.
   37          2. They're ending the call, or a clear refusal ("not interested", "no thanks", "not a fit"): acknowledge it,
   38             no sales question. At most offer an easy exit ("Can I send one short email and leave it there?").
   39             A second no ends the call.
   40          3. A direct question from them: answer it plainly.
   41          4. What's already established: never ask again what they answered, declined or deflected; build on what they confirmed.
   42          5. The best next move for this conversation (answer, clarify, discover, acknowledge, objection, close).
   43          6. The stage's goal: it guides the move, it never overrides what they just said.
   44          7. The script: it supplies the strategy, facts and approved wording. Use its lines in its words when a
   45             row truly fits what they meant, not just a few shared words. A script question that doesn't fit the
   46             moment is skipped, not forced. Its banned words, facts and compliance limits always hold.
   47  
   48          Scripts built as a backbone (output rules, banned words, facts, state, a pick order, and tables of
   49          ID or Condition / Sounds like / Say / Then) are the source of approved rows and facts:
   50          - The script's banned words, facts and compliance limits beat the style rules below.
   51          - Track the script's state from the call so far: line type, stage, whether a problem was named, how many no's.
   52          - Each turn, check the pick order, but a row only matches when its "Sounds like" fits what they MEANT
   53            (a meaning match, not shared words), and nothing above in the decision order applies first.
   54            Treat the script's transcript noise list as the same word.
   55          - SAY is that row's Say line word for word, with only the [slots] filled in ([Name], [Firm] or [Company],
   56            [SDR] = the rep's first name, [Day] [Time] or [SlotA] [SlotB] = the open meeting times below).
   57            If a slot is unknown, drop it naturally. Never show a bracket.
   58          - A row whose Say is "Show nothing" or EMPTY, a rule that says to return an empty string, or a
   59            call-screen/talk-over rule that says show nothing: the move is silent.
   60          - A row that says "Show <text>" in capitals (like USE NAME DIRECTORY): put that text in SAY.
   61          - Nothing matches: use the fallback row for the current stage.
   62          - CUE starts with the row's ID (or its stage, like S3) in brackets, then the row's Then
   63            (e.g. "[S5 manual 2] then ask how long").
   64          - STAGE maps the script's stages to the app's: GATE or gatekeeper = Gatekeeper, OPEN or opener = Opener,
   65            REASON, PROBLEM or the question = Value, PAIN or discovery = Discovery, PLAYBACK and BRIDGE = Discovery,
   66            any objection row = Objection, ASK = Closing, JOIN and LOCK = Goal reached once a time is picked,
   67            HANDOFF, exit without a meeting or end = Exit, voicemail = Voicemail, call screen = Screener.
   68          - Times: only the open meeting times below as [Slot A] [Slot B] [Slot C] [Slot D] (or [Day] [Time]). Never make one up.
   69          - "Send me info" is not a meeting yes: use the info row, then ask once for a time.
   70  
   71          Getting past a gatekeeper (receptionist, assistant, operator, "who's calling?"), when the script has no
   72          gatekeeper lines. Adapt the campaign's opener; the goal is to be put through, not to pitch:
   73          - Sound expected and brief. First name for the prospect, first name for the rep: "Hi, it's Mason for AJ.
   74            Is AJ around?" Calm, warm, a little informal, like a peer calling a peer.
   75          - Ask for help, don't sell. Never pitch the gatekeeper. One short, true reason only if asked, tied to the
   76            prospect's world in the script's words ("It's about how AJ's team handles ops admin. Easy to explain
   77            once we connect.").
   78          - "What's this regarding?": the one-line reason, then straight back to the ask: "Could you put me through?"
   79          - "Are they expecting your call?": honest: "Not yet. Worth a minute of AJ's time, though. Is AJ in?"
   80          - "They're busy / in a meeting": get the next best thing: their direct line or extension, the best time
   81            to call, or their email. Use the gatekeeper's name if they gave it.
   82          - "Send an email": "Happy to. What's the best address for AJ?" then ask when AJ is usually free.
   83          - Never lie, never claim a relationship or a prior conversation that didn't happen.
   84          - Use the prospect's name, not "he" or "she", unless the gatekeeper used one first.
   85          - Once the prospect is on the line: back to the script's opener.
   86  
   87          Cold call method (adapt it to the campaign):
   88          - Opener: honest that it's a cold call, ask for a few seconds. Calm and slow beats slick.
   89          - Reason for the call: lead with a problem their peers have, not the product. Then ask if it's true for them.
   90          - Value (STAGE: Value): one sentence tying the problem they named to what the campaign offers, then a question.
   91          - Discovery: one question at a time. Follow up on their answer before moving on. Get the cost of the problem in their words: time, money, risk.
   92          - Keep them talking: repeat their last few words as a question, or name what they seem to feel ("Sounds like that rollout was frustrating").
   93          - An objection or a reflex brush-off ("we use another tool", "no time", "send me info", "we're all set") is not a
   94            refusal: acknowledge it in a few words, then one relevant question. If they push back again, respect it.
   95            A clear refusal ("not interested", "no thanks", "not a fit") is different: no sales question (see the order above).
   96          - Ask for the objective as soon as there is real interest. Don't over-discover. Make it easy: specific, short, low commitment.
   97          - Use their first name at most once or twice. Silence is fine; don't fill it.
   98          - Never suggest "Did I catch you at a bad time?" It tests as the worst opener.
   99          - Never pitch features on a cold call. Earn the next step.
  100          - "We're all good", "all taken care of", "we're set", "we already have someone" (a brush-off, not a refusal): don't accept it and don't exit.
  101            Acknowledge it warmly, then one light question about their setup ("Fair. What's still a hassle, even
  102            with that in place?"). Offer the free health check (a second set of eyes, no cost) only if they show an
  103            opening. Don't push a meeting on the first brush-off.
  104          - "No time right now" or "call me later": ask for a better time to call. Don't pitch, don't start discovery.
  105  
  106          Selling AI and automation (when the campaign is about AI):
  107          Buyers are skeptical and busy. Talk about outcomes in their words, like hours back, cleaner data and more selling time, not about AI itself.
  108          - "We already use ChatGPT or Copilot": good start. Ask how much of the team uses it daily, and if it's connected to their real systems.
  109          - "Security, legal or IT won't allow it": very fair. Ask what they'd need to see to be comfortable.
  110          - "We tried AI and it didn't stick": common. Ask what got in the way. Adoption usually fails on process and habits, not tech.
  111          - "AI is hype": agree there's a lot of noise. Ask about one boring manual task they'd love to be gone.
  112          - "We're building it in-house": ask if they're building tools or driving adoption, and what's slower than hoped.
  113          - "Not a priority": ask what is a priority this quarter. Connect only if there's a real link.
  114          - "Will it replace my people?": no. It gives them time back for the work they were hired to do.
  115  
  116          Before writing, decide what the talk needs next: what the prospect wants or is worried about, what
  117          the rep already said in their own words, and the current goal. Then pick ONE move:
  118          answer (they asked something), clarify (they're confused), discover (learn their situation),
  119          acknowledge (they shared something; reflect it briefly), objection (handle their concern),
  120          close (ask for the meeting, or end politely), silent (the rep doesn't need a new line now:
  121          they're mid-thought, or the line on screen still fits).
  122  
  123          Answer in exactly this format and nothing else:
  124          MOVE: <answer, clarify, discover, acknowledge, objection, close or silent>
  125          STAGE: <one of: \(stages.joined(separator: ", "))>
  126          \(Think.promptLine(enabled: Think.enabled))SAY: <the line the rep should say next>
  127          CUE: <why, or how to say it, under 10 words>
  128  
  129          For silent, write only:
  130          MOVE: silent
  131  
  132          \(campaign.promptText)
  133          """
  134      }
  135  
  136      static func opener(calling: String?, details: String?, style: Opener?, scriptOpener: String? = nil) -> String {
  137          guard let style else {
  138              let given = scriptOpener.map { "The script's opener, exactly as written: \"\($0)\"\n" } ?? ""
  139              return """
  140              \(about(calling, details))\(given)The call has not connected yet. Give the opener the rep should say when they pick up.
  141              Use the script's own opener (above, or the campaign's Opening section, or the first line of the original
  142              script). Say it the way the script says it: same words, same order, same tone, and nothing in front of it
  143              (if the script starts "Is this ___?", the line starts "Is this", not "Hi ___, this is ___").
  144              Fill in the blanks (___, [Name], {first name}) with their first name, the rep's name or the company.
  145              Then check it against what you know about this person. If a part of the script doesn't fit them, change
  146              only that part, as little as possible, in the script's voice. For example: the script says "a fellow
  147              Portland entrepreneur" but they're not in Portland or don't run a business; the script names an industry,
  148              role or tool that isn't theirs; the script assumes something their Salesforce page contradicts. Never
  149              invent facts about them. If nothing needs changing, use the script as is. Don't add a pitch or a greeting
  150              the script doesn't have. Only write a different opener if you're highly confident it serves the script's
  151              goal better for this person, and keep it as short as the script's.
  152              CUE: one short delivery tip from the script's tone, plus "(adjusted: <what changed>)" if you changed anything.
  153              """
  154          }
  155          return """
  156          \(about(calling, details))The call has not connected yet. Write the opener using this proven structure. \
  157          Keep its wording and shape; only fill in the brackets. [company] is the rep's company from the campaign. \
  158          [industry] is their industry from the Salesforce facts (like "accounting" or "insurance"); if unknown, drop it ("a few teams"). If the first name is unknown, leave it out naturally. If the rep's name is unknown, write [your name].
  159          Opener: \(style.template)
  160          Put the opener's name in the CUE: "\(style.name) opener".
  161          """
  162      }
  163  
  164      /// A phone menu is playing. Plan the best route to the owner.
  165      static func phoneTree(menu: String, calling: String?, details: String?, repSaid: String) -> String {
  166          """
  167          \(about(calling, details))The call reached an automated phone menu (phone tree). Everything it has said so far
  168          (speech-to-text, so expect small errors):
  169          "\(menu)"
  170          \(repSaid.isEmpty ? "" : "Keys or words the rep has already used: \(repSaid)\n")
  171          Goal: reach the person above, or if they're the owner or a decision maker, the fastest route to a live
  172          person who can put the rep through to them. Pick the highest-leverage option from what the menu actually
  173          offers. Usually best first: dial by name or the company directory (spell their last name on the keypad:
  174          2=ABC 3=DEF 4=GHI 5=JKL 6=MNO 7=PQRS 8=TUV 9=WXYZ), their extension if known, an option for the owner,
  175          management or executive office, then sales (sales lines answer fast and can transfer), then the operator
  176          (0). Avoid support queues, billing, hours, locations and anything that ends in a voicemail box.
  177          If the menu hasn't listed its options yet, say to wait for them, and what to listen for.
  178          If the latest words are clearly a live person, not a recording, start your answer with the line HUMAN,
  179          then give what the rep should say to them. A receptionist or assistant: the campaign's opener adapted for
  180          getting through to the person (see "Getting past a gatekeeper"), in the script's voice. The person
  181          themselves: the script's opener.
  182          Answer in this format:
  183          SAY: <the exact keys to press now, or what to say, and why in a few words>
  184          KEYS: <only the digits to press now, like 3 or 7467 (0-9, * and #); leave empty if the rep should wait or talk>
  185          CUE: <the backup plan if that doesn't work>
  186          """
  187      }
  188  
  189      /// A running summary of the call so far (written in the background every few turns).
  190      static var liveSummary = ""
  191      /// How many turns the summary covers; later turns always go word for word.
  192      static var summaryCoversTurns = 0
  193      /// What has worked on this call list's common blockers (set at call start).
  194      static var blockerHints = ""
  195      /// Open and answered questions, tracked in code (set before each request).
  196      static var questionFacts = ""
  197      /// Objections raised, answered, and what the prospect said after (tracked in code).
  198      static var objectionFacts = ""
  199      /// How many times the prospect has said no this call (two no's and a go).
  200      static var prospectNos = 0
  201      /// The prospect's words the latest reply was written for (the line check reads it).
  202      static var latestProspect = ""
  203      /// The last turns word for word and the campaign script, for the "is this THINK about this call" check.
  204      static var recentText = ""
  205      static var scriptText = ""
  206      /// Questions the rep asked that were answered (the line check refuses to repeat them).
  207      static var answeredQuestions: [String] = []
  208      /// Lines already shown to the rep this call, and which of them the rep actually said.
  209      static var shownLines: [String] = []
  210      static var saidLines: [String] = []
  211      /// Shown lines the rep partly said in their own words (a paraphrase): neither confirmed nor "never said".
  212      static var likelyCoveredLines: [String] = []
  213      /// The step of the last line the rep actually said (Opener, Discovery, Value...).
  214      static var lastSaidStage = ""
  215      /// What the last reply prompt included, for the call trace.
  216      static var lastContext: [String: Any] = [:]
  217  
  218      /// `turns` are finalized transcript only. `speculative`: `latest` is still-changing partial words
  219      /// (an early draft), so it's labeled as not final and never written into the call as fact.
  220      static func reply(turns: [Turn], latest: String, calling: String?, details: String?, style: Opener?, openTimes: String?,
  221                        speculative: Bool = false, repLed: Bool = false, assumeYes: Bool = false, fullContext: Bool = false) -> String {
  222          // Short call (12 turns or fewer, or no summary yet): every finalized turn, word for word.
  223          // Longer: the summary of everything before, plus the last 10 turns word for word.
  224          let start = fullContext ? 0 : CallMemoryRules.verbatimStart(totalTurns: turns.count, summaryCovers: summaryCoversTurns, hasSummary: !liveSummary.isEmpty)
  225          let recent = Array(turns[start...].suffix(300))
  226          var history = recent.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
  227          if recent.count < turns.count { history = "Earlier in the call (summary):\n\(liveSummary)\n\nThe last minute, word for word:\n" + history }
  228          let repLast = turns.last { $0.speaker == .rep }?.text ?? ""
  229          latestProspect = (repLed || assumeYes) ? "" : latest
  230          recentText = recent.suffix(6).map(\.text).joined(separator: " ")
  231          let intent = (repLed || assumeYes) ? ConversationIntent.other : ConversationIntent.classify(latest)
  232          let priority: String = {
  233              switch intent {
  234              case .question: return "PRIORITY NOW: they asked a direct question. MOVE answer: answer it plainly in the first sentence. No discovery question in this line.\n"
  235              case .rejection: return "PRIORITY NOW: they clearly said no. MOVE acknowledge or close. No sales question; at most offer an easy exit. After a second no, thank them and end.\n"
  236              case .objection: return "PRIORITY NOW: they raised an objection, not a refusal. MOVE objection: acknowledge it in a few words, then one relevant question.\n"
  237              case .ending, .optOut: return "PRIORITY NOW: they're ending the call. MOVE close: thank them briefly. No more questions.\n"
  238              case .other: return ""
  239              }
  240          }()
  241          lastContext = ["mode": recent.count < turns.count ? "summary + last 10 turns" : "full transcript",
  242                         "turns_total": turns.count, "turns_verbatim_from": turns.count - recent.count + 1, "turns_verbatim_to": turns.count,
  243                         "speculative_latest": speculative, "rep_led": repLed, "shown_lines_included": min(shownLines.count, 5)]
  244          let now = assumeYes
  245              ? "The rep just asked: \"\(latest)\"\nThe prospect hasn't answered. Write the line for if they say yes. If the rep asked permission to explain, this is the script's next approved pitch, said simply. If it was a discovery question, this is the follow-up to a yes."
  246              : repLed
  247              ? "The rep went off script and just said, in their own words: \"\(latest)\"\nThe prospect hasn't answered yet. Give the rep the next line that builds on what they just said."
  248              : speculative
  249              ? "The prospect is still talking. Heard so far (partial, may change, not confirmed): \"\(latest)\""
  250              : "The prospect just said: \"\(latest)\""
  251          // Facts only: what the rep said is done; a line shown but not said never reached the prospect.
  252          let said = saidLines.suffix(5).map { "- \($0)" }.joined(separator: "\n")
  253          let notSaid = shownLines.filter { !saidLines.contains($0) && !likelyCoveredLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
  254          let partly = likelyCoveredLines.filter { !saidLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
  255          let shown = (said.isEmpty ? "" : "Coach lines the rep actually said (done, don't repeat):\n" + said + "\n")
  256              + (partly.isEmpty ? "" : "Coach lines the rep partly covered in their own words (likely done; don't repeat as is):\n" + partly + "\n")
  257              + (notSaid.isEmpty ? "" : "Coach lines shown but NOT said (the prospect never heard them; the rep chose their own words):\n" + notSaid + "\n")
  258              + (lastSaidStage.isEmpty ? "" : "The last step the rep actually covered: \(lastSaidStage)\n")
  259          let opened = style.map { "The rep opened with the \"\($0.name)\" opener: \($0.template)\nGood follow-up for it: \($0.followUp)\n\n" } ?? ""
  260          let booking = openTimes.map { "\($0)\n\n" } ?? ""
  261          return """
  262          \(about(calling, details))\(opened)\(booking)Call so far, oldest first:
  263          \(history)
  264  
  265          \(repLast.isEmpty ? "" : "The rep's last words: \"\(repLast)\"\n")\(now)
  266          \(blockerHints.isEmpty ? "" : "\n" + blockerHints + "\n")\(questionFacts.isEmpty ? "" : "\nQuestions on this call (tracked by simple rules from the transcript):\n" + questionFacts + "\n")\(objectionFacts.isEmpty ? "" : "\nObjections on this call (tracked by simple rules from their words; answered is not the same as resolved):\n" + objectionFacts + "\n")
  267          \(priority)\(shown)\(prospectNos == 1 ? "They have clearly said no once. No more sales questions: acknowledge it, at most offer an easy exit.\n" : "")
  268          The tracked questions and objections above come from simple rules on the transcript. If the transcript
  269          shows something different, the transcript is the truth.
  270          The rep's actual words are the truth; the script is the guide. If the rep already covered something in
  271          their own words (the reason for the call, the pitch, a question), it's done: never repeat it. Coach from
  272          where the rep really is toward the next goal of the script.
  273          If the prospect asked a question, the first sentence answers it plainly and directly.
  274          Roles: the rep is the caller from Clarity. The prospect is the person being called. Never have the rep
  275          claim the prospect's role, title or decisions ("I'm the one who decides"). If unsure who decides, ask.
  276          A pain is theirs only if they said it. Never state a problem as theirs or as what "usually" bothers teams when
  277          they haven't said it. You may offer one as a question ("Some teams say call notes never get typed in. True for you?").
  278          A clear no: acknowledge it, no sales question, at most offer an easy exit. A second no: thank them and end.
  279          An objection is not a no: acknowledge it, then one relevant question.
  280          What should the rep say next? SAY is 1 to 2 short sentences, \(LineBudget.promptMax) words at most. End with one
  281          question when the move is to learn something (discover, clarify, objection); an answer, acknowledgment or
  282          close can end plainly. Use the script's wording when a row truly fits; otherwise write what this
  283          conversation needs.
  284          """
  285      }
  286  
  287      /// Written before the call, so it's ready the instant a voicemail greeting starts.
  288      static func voicemail(calling: String?, details: String?, earlierTexts: [String] = [], earlierMessages: [String] = [],
  289                            history: String = "", localLunch: Bool = false) -> String {
  290          let local = localLunch ? LocalLunch.promptNote : ""
  291          let past = history.isEmpty ? "" : """
  292          What the rep has already done with this person:
  293          \(history)
  294  
  295          """
  296          let earlierLinkedIn = earlierMessages.isEmpty ? "" : """
  297          This will be LinkedIn message number \(earlierMessages.count + 1). LinkedIn messages already sent (oldest first):
  298          \(earlierMessages.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
  299          The new LINKEDIN MESSAGE must be clearly different from every one of these: a new angle or question and new wording.
  300  
  301          """
  302          let earlier = earlierTexts.isEmpty ? "" : """
  303          This will be text number \(earlierTexts.count + 1) to this person. Texts already sent (oldest first):
  304          \(earlierTexts.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
  305          The new TEXT must be clearly different from every one of these: a new angle or question and new wording.
  306          Don't reuse their opening words. Keep it short and friendly; later texts can be lighter (for example,
  307          a quick "should I stop reaching out?" by the 4th or 5th text).
  308  
  309          """
  310          return """
  311          \(about(calling, details))\(past)\(earlier)\(earlierLinkedIn)\(local)If this call goes to voicemail, what should the rep say after the beep?
  312          One voice for everything you write here. The voicemail, TEXT, LINKEDIN and LINKEDIN MESSAGE all come from
  313          the campaign above: its opening, its angle, its offer, its tone, and any voicemail, text or LinkedIn wording
  314          it gives. Follow the campaign over the defaults below whenever they differ.
  315          Templates come first: if the campaign or its script has a voicemail script, the voicemail is that script
  316          word for word, with only the blanks and placeholders filled in. If the campaign or its script has a text message template (a missed call text, a text
  317          after a voicemail, or any text the rep sends), the TEXT line must be that template word for word, with only
  318          the name, rep and company placeholders filled in (for a later text, use the script's matching follow-up
  319          template if it has one). Same for LinkedIn: a connection note or request template goes in LINKEDIN word for
  320          word, a LinkedIn message template goes in LINKEDIN MESSAGE, and with no LinkedIn template, use the text
  321          template there too. Only write your own when the campaign has no template. Write the voicemail first, then
  322          make every TEXT and LinkedIn line sound like the same person who just left that voicemail: the same way the
  323          rep introduces themselves (if the voicemail says something like "a fellow Portland entrepreneur", so do the
  324          text and LinkedIn note), the same reason for reaching out, the same warmth and plainness. Never switch to
  325          a different pitch or a more formal, salesy tone in the written follow-ups.
  326          Voicemail: under 20 seconds, about 40 words. In this order: their first name; the rep's name and how the
  327          campaign introduces them; one reason tied to the campaign's angle and to something specific about them,
  328          their role or their company (from the Salesforce facts, or a common pain for their title if there are none);
  329          then one closing line that fits the history above:
  330          - No text sent yet: "I'll send you a quick text so you have my number."
  331          - A text was already sent: don't promise a first text again. Mention it instead, for example
  332            "I sent you a text the other day, so you have my number" (use the real timing: today, yesterday, a few days ago).
  333          - A LinkedIn connection request or message was already sent: you can mention it, for example
  334            "I also sent you a connection request on LinkedIn" (pick the one or two most recent touches, not a list).
  335          - Voicemails were already left: don't repeat them. New angle and new wording, and it can be shorter and lighter.
  336          The TEXT, LINKEDIN and LINKEDIN MESSAGE lines below follow the same history: e.g. the text can say
  337          "left you a voicemail" or "sent you a note on LinkedIn" when that's true.
  338          No pitch, no hype, no email.
  339          CUE: one short delivery tip. STAGE: Voicemail.
  340          Then add three more lines:
  341          TEXT: <the text message to send right after. Under 40 words. Sounds like a real person texting, not marketing,
  342          and like the voicemail above. The rep introduces themselves the same way as in the voicemail, then the same
  343          reason for reaching out (the campaign's angle, tied to their role or company),
  344          then one easy yes/no question about THEIR situation (e.g. "Is that still a headache for your team?"),
  345          then one short line saying what happens next, so they know they'll hear from the rep again. Make it true to
  346          the history: calls left = "I'll try you again tomorrow if I don't hear back." or "I'll send you a note on
  347          LinkedIn too."; last call = "I won't keep calling. Reach out anytime." Vary the wording each time.>
  348          LINKEDIN: <a LinkedIn connection request note. Under 200 characters. Same voice and intro as the voicemail.
  349          Says the rep just tried calling, gives the same reason, no pitch, no links, no emojis.>
  350          LINKEDIN MESSAGE: <a LinkedIn direct message, for when they're already connected. Under 400 characters.
  351          Same voice and intro as the voicemail. Says the rep just tried calling, gives the same reason, one easy
  352          question. No links, no emojis.>
  353          Rules for the voicemail, TEXT and both LinkedIn lines:
  354          - Never name anyone they haven't met (no "Oliver", no "my partner", no "our team lead"). They only know the rep.
  355          - Don't ask for a meeting, a call length or a day in a first touch. Ask about their situation instead.
  356            Only after earlier texts or voicemails (see the history) can a later one offer a short call, and then as
  357            a simple question ("Worth a quick chat?"), still without naming anyone else.
  358          - One idea per message. No jargon, no "quick look at yours", no hype.
  359          Never copy wording from these instructions; the words come from the campaign.
  360          """
  361      }
  362  
  363      /// The Salesforce record the rep had open: the tab title and, if allowed, the page's text.
  364      private static func about(_ calling: String?, _ details: String? = nil) -> String {
  365          var lines: [String] = []
  366          let rep = Prefs.repName
  367          if !rep.isEmpty {
  368              lines.append("The rep's first name is \(rep).")
  369          }
  370          if let calling {
  371              lines.append("Salesforce record open in the rep's browser: \(calling). Use the first name if it's a person.")
  372          }
  373          if let details {
  374              lines.append("Text from their Salesforce page. It includes menus and clutter; use only facts about this person and their company, and never guess:\n\(details)")
  375          } else if calling != nil {
  376              lines.append("Assume nothing else about them.")
  377          }
  378          return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
  379      }
  380  }
  381  
```


## `mac/Sources/ClarityLiveCoach/CoachModel+Lines.swift`

```swift
    1  import AppKit
    2  import CoachCore
    3  import AVFoundation
    4  import Combine
    5  import CoreAudio
    6  import Foundation
    7  
    8  /// The coaching line on screen: asking Claude, holding a line until the rep has read it, history and journey.
    9  extension CoachModel {
   10      func trackJourney(_ stage: String) {
   11          let step: Int?
   12          switch stage {
   13          case "Opener", "Screener", "Gatekeeper", "Voicemail": step = 0
   14          case "Discovery": step = 1
   15          case "Value": step = 2
   16          case "Closing", "Goal reached": step = 3
   17          default: step = nil // Objection, Exit: stay where we are
   18          }
   19          if let step { journeyStep = step } // follows the call both ways (calls aren't linear)
   20      }
   21  
   22      /// Shows the line before the one on screen.
   23      func back() {
   24          guard !doNotCall else { return } // the goodbye line stays (Fix 2)
   25          let current = historyIndex ?? history.count - 1
   26          guard current > 0 else { return }
   27          historyIndex = current - 1
   28          suggestion = history[current - 1].s
   29          kind = history[current - 1].kind
   30      }
   31  
   32      /// Back to the newest line after looking back.
   33      func showLatest() {
   34          guard !doNotCall else { return } // Fix 2
   35          guard let latest = history.last else { return }
   36          historyIndex = nil
   37          suggestion = latest.s
   38          kind = latest.kind
   39      }
   40  
   41      /// Asks for the line that moves the call to the next step.
   42      func advanceStep() {
   43          guard let next = nextStepName else { newLine(); return }
   44          newLine(extra: "Move the call forward to the next step: \(next). Write the line that starts it now.")
   45      }
   46  
   47      /// The meeting times Claude may offer, with stable codes for this call, and which two to offer next.
   48      func bookingText() -> String? {
   49          let slots = availability.offerSlots()
   50          guard !slots.isEmpty else { return nil }
   51          for slot in slots where codeByDate[slot] == nil {
   52              codeByDate[slot] = "T\(codeByDate.count + 1)"
   53          }
   54          let next = pickNextPair(from: slots)
   55          nextOffer = next
   56          let list = slots.map { slot in
   57              "\(codeByDate[slot]!): \(availability.label(slot))" + (offeredTimes.contains(slot) ? " (already offered)" : "")
   58          }.joined(separator: "\n")
   59          let nextCodes = next.compactMap { codeByDate[$0] }.joined(separator: " or ")
   60          return """
   61          Meeting times open on the host's calendar (exact start times, \(availability.zoneName) time). Offer only these:
   62          \(list)
   63          When asking for the meeting, offer exactly these two next: \(nextCodes). Say them naturally, like "Tuesday at 10 or Wednesday at 2:30".
   64          If they turn times down, the next message gives you new ones; never re-offer a time marked already offered.
   65          If the prospect names a time, check the list. If it's there, confirm it. If not, offer the closest listed time.
   66          Whenever your SAY offers or confirms specific times, add a last line: OFFERED: <their codes, comma separated>.
   67          """
   68      }
   69  
   70      /// Two not-yet-offered times: the soonest, plus one on another day (or at least 3 hours apart).
   71      func pickNextPair(from slots: [Date]) -> [Date] {
   72          let fresh = slots.filter { !offeredTimes.contains($0) }
   73          guard let first = fresh.first else { return [] }
   74          let cal = Calendar.current
   75          let second = fresh.dropFirst().first { !cal.isDate($0, inSameDayAs: first) }
   76              ?? fresh.dropFirst().first { $0.timeIntervalSince(first) >= 3 * 3600 }
   77              ?? fresh.dropFirst().first
   78          return [first] + (second.map { [$0] } ?? [])
   79      }
   80  
   81      /// Space bar during a live call: a fresh line from the whole call, word for word, on Sonnet, shown at once.
   82      func freshLine() {
   83          guard status == .live, !doNotCall, !voicemailActive, !callClosed else { return }
   84          let latest = uncoached.trimmed.isEmpty ? (turns.last?.text ?? "") : uncoached.trimmed
   85          CallTrace.event("manual", ["action": "space: fresh line", "was": suggestion.say])
   86          ActivityLog.add("Space: fresh line from the whole call (Sonnet)")
   87          holdLine = false
   88          nextAskModel = "claude-sonnet-5-5"
   89          freshLineIDs.insert(seq + 1) // the id ask() is about to use
   90          ask(.reply, user: CoachPrompt.reply(turns: turns, latest: latest, calling: calling, details: recordDetails, style: callOpener,
   91                                              openTimes: bookingText(), fullContext: true)
   92              + "\nThe rep pressed for a fresh line. Read the whole call and give the best next line for this exact moment.")
   93      }
   94  
   95      /// Space bar while this app is in front and a call is live (not while typing in a text box).
   96      func installSpaceKey() {
   97          guard spaceMonitor == nil else { return }
   98          spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
   99              guard let self, event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
  100                    self.status == .live, !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
  101              self.freshLine()
  102              return nil // used: don't also type a space
  103          }
  104      }
  105  
  106      /// The rep asked for a different line right now. Skips the wait and the hold.
  107      func newLine(extra: String = "The rep asked for a different line than the last one.") {
  108          // ⌘J and the space bar are one feature: the fresh line from the whole call.
  109          if status == .live, !voicemailActive { freshLine(); return }
  110          CallTrace.event("manual", ["action": "Different line", "was": suggestion.say])
  111          guard status == .live, !voicemailActive else { return }
  112          let latest = uncoached.trimmed.isEmpty ? (turns.last { $0.speaker == .prospect }?.text ?? "") : uncoached.trimmed
  113          uncoached = ""
  114          shownAt = .distantPast // no hold for a line the rep asked for
  115          repWordsSinceShown = 99
  116          ask(.reply, user: CoachPrompt.reply(
  117              turns: turns, latest: latest, calling: calling, details: recordDetails, style: callOpener,
  118              openTimes: bookingText()
  119          ) + "\n" + extra)
  120      }
  121  
  122      /// The rep clicked "Other times": count the current pair as turned down.
  123      func skipOfferedTimes() {
  124          offeredTimes.formUnion(nextOffer)
  125          nextOffer = pickNextPair(from: availability.offerSlots())
  126      }
  127  
  128      /// Instant line for a call screener. No Claude call, no waiting.
  129      func showScreenerLine() {
  130          screenerRetries = 0 // each screener gets its own retries
  131          screenerCallID = CallTrace.callID
  132          // Never over the rep mid-sentence (C6): wait up to 3 s for them to stop.
  133          if signals().repSpeaking || !(interim[.rep] ?? "").isEmpty {
  134              screenerWait?.cancel()
  135              screenerWait = Task { [weak self] in
  136                  for _ in 0..<33 { // up to about 10 s
  137                      try? await Task.sleep(for: .milliseconds(300))
  138                      guard let self, !Task.isCancelled else { return }
  139                      var sig = self.signals(); sig.queuedIsForNewTopic = true
  140                      if !sig.repSpeaking && (self.interim[.rep] ?? "").isEmpty && CoachMachine.canReplace(sig) { self.showScreenerLineNow(); return }
  141                  }
  142                  // Still talking after 10 s: they're handling the screener themselves. Don't interrupt.
  143                  CallTrace.event("suggestion.dropped", ["line": "screener", "why": "the rep kept talking"])
  144              }
  145              return
  146          }
  147          showScreenerLineNow()
  148      }
  149  
  150      private func showScreenerLineNow() {
  151          yesShowTask?.cancel()
  152          guard status == .live, !doNotCall, screenerCallID == CallTrace.callID else { return }
  153          // Every caller is covered: never over the rep's speech or reading; wait again instead (Fix 6).
  154          guard CoachController.canInterrupt(signals: signals()), (interim[.rep] ?? "").isEmpty else {
  155              CallTrace.event("screener.waiting", ["why": "the rep is talking or reading"])
  156              screenerRetries += 1
  157              if screenerRetries <= 30 {
  158                  screenerWait?.cancel()
  159                  screenerWait = Task { [weak self] in
  160                      try? await Task.sleep(for: .milliseconds(300))
  161                      guard let self, !Task.isCancelled else { return }
  162                      self.showScreenerLineNow()
  163                  }
  164              }
  165              return
  166          }
  167          screenerRetries = 0
  168          screenerActive = true
  169          attempt?.screenerStarted()
  170          coachTask?.cancel()
  171          thinking = false
  172          holdTask?.cancel()
  173          pending = nil
  174          if kind == .opener { openerBeforeScreener = suggestion }
  175          seq += 1
  176          show(Suggestion(say: Screener.line(calling: calling),
  177                          cue: "Call screener. Say it slowly and clearly, then wait.",
  178                          stage: "Screener"),
  179               id: seq, kind: .screener)
  180      }
  181  
  182      /// If the prospect's words end like a finished sentence and hold still for a moment,
  183      /// start Claude now instead of waiting for the end-of-speech signal.
  184      func scheduleEarlyStart() {
  185          specTimer?.cancel()
  186          guard status == .live, !screenerActive, !voicemailActive, !doNotCall else { return } // prepare even while a line is up
  187          let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
  188          if pendingAmbiguousOptOut != nil, !(interim[.prospect] ?? "").isEmpty { armPendingOptOutTimer() } // still talking: wait more
  189          if pendingAmbiguousOptOut != nil || OptOut.hasAmbiguous(text) { return } // never draft on a possible opt-out (Fix 3)
  190          // "Don't call me back" mid-sentence: stop selling now, don't wait for them to finish.
  191          if LiveCoach.isOptOut(text, isFinal: false) { handleOptOut(text); return }
  192          guard isMeaningful(text) else { return }
  193          // A script answer waits for their full sentence ("I don't know..." can end "...that I'm the right fit"):
  194          // the final words go through the same priority checks.
  195          if scriptAnswers.matchInContext(text, answeredQuestions: CoachPrompt.answeredQuestions).entry != nil { return }
  196          // Draft early once their meaning is clear: a finished sentence (200 ms), or 6+ words that
  197          // stopped changing (450 ms). Each new word cancels the wait, so there's no flood of requests.
  198          // A yes to the rep's question, with the yes line already written: no draft needed.
  199          if yesBranch != nil, ProspectReply.kind(text) == .yes { return } // ready or still being written
  200          // One or two word fragments ("No.") almost always grow: drafting on them wastes a request.
  201          guard let wait = EarlyStart.delayMS(for: text),
  202                EarlyStart.shouldRedraft(previous: lastEarlyBasis, text: text, draftsThisTurn: earlyDraftsThisTurn) else { return }
  203          specTimer = Task { [weak self] in
  204              try? await Task.sleep(for: .milliseconds(wait))
  205              guard let self, !Task.isCancelled, !self.doNotCall,
  206                    EarlyStart.shouldRedraft(previous: self.lastEarlyBasis, text: text, draftsThisTurn: self.earlyDraftsThisTurn),
  207                    (self.uncoached + " " + (self.interim[.prospect] ?? "")).trimmed == text,
  208                    normalized(text) != self.specBasis else { return }
  209              self.ask(.reply, user: CoachPrompt.reply(
  210                  turns: self.turns, latest: text, calling: self.calling, details: self.recordDetails, style: self.callOpener,
  211                  openTimes: self.bookingText(), speculative: true
  212              ), early: text)
  213              self.lastEarlyBasis = text
  214              self.earlyDraftsThisTurn += 1
  215          }
  216      }
  217  
  218      /// The prospect stopped talking. Decide if the rep needs a new line.
  219      func prospectFinished() {
  220          specTimer?.cancel()
  221          lastEarlyBasis = nil
  222          earlyDraftsThisTurn = 0
  223          if goalPending, !goalHit { // once per full turn, not per chunk (Fix 5)
  224              goalPendingTurns = GoalPendingRule.turnsLeft(after: goalPendingTurns, confirmed: false)
  225              if goalPendingTurns <= 0 { goalPending = false }
  226          }
  227          var said = uncoached.trimmingCharacters(in: .whitespaces)
  228          // A possible opt-out is waiting: decide it first, with whatever they said after it (Fix 1c).
  229          if let pendingSaid = pendingAmbiguousOptOut {
  230              let outcome = PendingOptOut.resolve(pending: pendingSaid, later: said, utteranceEnded: false, callEnded: false,
  231                                                  secondsWaited: Date().timeIntervalSince(pendingAmbiguousAt))
  232              if outcome != .wait {
  233                  pendingAmbiguousOptOut = nil
  234                  pendingOptOutTask?.cancel()
  235                  if outcome == .optOut { handleOptOut((pendingSaid + " " + said).trimmingCharacters(in: .whitespaces)); return }
  236                  said = (pendingSaid + " " + said).trimmingCharacters(in: .whitespaces) // a callback request: answer it as one
  237                  CallTrace.event("optout.not", ["said": said, "why": "a later time followed: a callback request"])
  238              }
  239          }
  240          guard !said.isEmpty else { return }
  241          if doNotCall {
  242              uncoached = ""
  243              CallTrace.event("coach.suppressed", ["said": said, "why": "do not call: no more sales lines this call"])
  244              return
  245          }
  246          if status == .live, LiveCoach.isOptOut(said, isFinal: false) { handleOptOut(said); return } // clear phrases
  247          // Hold only if no later time already follows; "...until Tuesday" is a callback and gets a normal answer.
  248          if status == .live, OptOut.hasAmbiguous(said), OptOut.matches(said, isFinal: true) {
  249              // "Don't call me back..." might go on ("...until Tuesday"). No sales line; decide at the full pause.
  250              pendingAmbiguousOptOut = said
  251              pendingAmbiguousAt = Date()
  252              CallTrace.event("optout.waiting", ["said": said, "why": "might be a callback request; waiting for the full pause"])
  253              uncoached = ""
  254              armPendingOptOutTimer()
  255              return
  256          }
  257          if phoneTreeActive { uncoached = ""; askPhoneTree(); return } // the menu goes on: re-plan the route
  258          // Two no's and a go: count their no's; two (or a no plus "yep, thanks") ends it politely, no AI.
  259          if status == .live, prospectNos > 0 { prospectTurnsAfterFirstNo += 1 }
  260          if status == .live, !voicemailActive, Rejection.isNo(said) { prospectNos += 1 }
  261          if status == .live, !voicemailActive, Rejection.callOver(nosSoFar: prospectNos, latest: said), !callClosed {
  262              callClosed = true
  263              closedOnSecondNo = prospectNos >= 2
  264              uncoached = ""
  265              coachTask?.cancel(); specTimer?.cancel(); pending = nil; yesBranch = nil; yesBranchTask?.cancel()
  266              let first = Screener.firstName(calling) ?? ""
  267              seq += 1
  268              CallTrace.event("call.closing", ["said": said, "nos": prospectNos, "why": "two no's, or a no and a sign-off"])
  269              show(Suggestion(say: "Totally understand\(first.isEmpty ? "" : ", \(first)"). Thanks for your time. Have a good one.",
  270                              cue: "Two no's: end it kindly.", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
  271              return
  272          }
  273          if callClosed { uncoached = ""; return } // nothing more to sell on this call
  274          if voicemailActive { uncoached = ""; return } // no coaching while a greeting plays
  275          // The rep asked a yes/no question and the line for "yes" is ready: a clear yes shows it now,
  276          // with no wait. No, unsure, or anything else gets a fresh answer from their real words.
  277          // Too old: the talk moved on since the question. Drop it and answer fresh.
  278          if yesBranch != nil, !YesBranchRule.usable(ageSinceQuestion: Date().timeIntervalSince(yesBranchAskedAt)) {
  279              CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "expired"])
  280              yesBranch = nil; yesBranchTask?.cancel()
  281          }
  282          if let yb = yesBranch, !yb.ready, ProspectReply.kind(said) == .yes {
  283              yesBranchWanted = said // nearly done: use it when it lands instead of starting over (H3)
  284              // ...but never dead air: after 1.2 s, give up on it and answer from their words.
  285              let waitFor = yb.question
  286              Task { [weak self] in
  287                  try? await Task.sleep(for: .seconds(YesBranchRule.maxWait))
  288                  guard let self, self.yesBranchWanted == said, self.yesBranch?.question == waitFor else { return }
  289                  self.yesBranchWanted = nil
  290                  self.yesBranch = nil
  291                  self.yesBranchTask?.cancel()
  292                  CallTrace.event("yes_branch.discarded", ["question": waitFor, "why": "not ready within \(YesBranchRule.maxWait) s"])
  293                  self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
  294                                                           details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
  295              }
  296              specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
  297              uncoached = ""
  298              latestProspect = said
  299              CallTrace.event("yes_branch.waiting", ["question": yb.question, "answer": said])
  300              return
  301          }
  302          if let yb = yesBranch {
  303              yesBranch = nil
  304              yesBranchTask?.cancel()
  305              let kind = ProspectReply.kind(said)
  306              if kind == .yes, yb.ready {
  307                  // A short wait so "Yeah. ...No, I'm not interested." can cancel it (call 6).
  308                  specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
  309                  uncoached = ""
  310                  latestProspect = said
  311                  let line = yb.s
  312                  yesShowTask?.cancel()
  313                  yesShowTask = Task { [weak self] in
  314                      try? await Task.sleep(for: .milliseconds(600))
  315                      guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall, !self.callClosed,
  316                            !self.voicemailActive, !self.screenerActive,
  317                            self.uncoached.trimmingCharacters(in: .whitespaces).isEmpty,
  318                            (self.interim[.prospect] ?? "").isEmpty else {
  319                          CallTrace.event("yes_branch.discarded", ["question": yb.question, "why": "they kept talking after the yes"])
  320                          return
  321                      }
  322                      CallTrace.event("yes_branch.used", ["question": yb.question, "answer": said, "line": line.say])
  323                      ActivityLog.add("Coach: they said yes, ready line shown")
  324                      self.markRequestStart()
  325                      self.seq += 1
  326                      self.offer(line, id: self.seq, kind: .reply, askedAt: Date())
  327                  }
  328                  return
  329              }
  330              CallTrace.event("yes_branch.discarded", ["question": yb.question, "answer": said, "answer_kind": kind.rawValue,
  331                                                       "ready": yb.ready, "why": kind == .yes ? "not ready yet" : "their answer wasn't a clear yes"])
  332          }
  333  
  334          // Started early on exactly these words? Then the answer is already on its way.
  335          if let basis = specBasis {
  336              specBasis = nil
  337              if basis != normalized(said) {
  338                  // Thrown out: stop it now, so it can't show later on any early return below (C5).
  339                  coachTask?.cancel(); specHeld = nil; thinking = false
  340                  CallTrace.event("early.wasted", ["basis": basis, "said": said, "why": "they kept talking after the early draft started"])
  341              }
  342              if basis == normalized(said) {
  343                  CallTrace.event("early.used", ["basis": basis, "said": said, "why": "their final words matched the early draft"])
  344                  uncoached = ""
  345                  latestProspect = said
  346                  confirmedAt = Date()
  347                  if let held = specHeld {
  348                      specHeld = nil
  349                      offer(held.s, id: held.id, kind: .reply, askedAt: confirmedAt!)
  350                  }
  351                  return
  352              }
  353          }
  354          if screenerActive {
  355              uncoached = ""
  356              if Screener.detects(said) { return } // still the screener talking
  357              // A real person picked up after the screener: back to the opener.
  358              screenerActive = false
  359              attempt?.screenerEnded(personSaid: said)
  360              latestProspect = said
  361              if let opener = openerBeforeScreener {
  362                  // Not on the mutual "Hello?": wait for 0.8 s of quiet, so the rep isn't reading over the greeting.
  363                  openerWaitTask?.cancel()
  364                  openerWaitTask = Task { [weak self] in
  365                      try? await Task.sleep(for: .milliseconds(800))
  366                      guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall,
  367                            (self.interim[.prospect] ?? "").isEmpty, self.uncoached.isEmpty else { return }
  368                      self.seq += 1
  369                      self.show(opener, id: self.seq, kind: .opener)
  370                  }
  371                  return
  372              }
  373          }
  374          // Always prepare an answer. Whether it shows now or waits is the display controller's call
  375          // (CoachMachine.canReplace): the line being read is never swapped out from under the rep.
  376          uncoached = ""
  377          latestProspect = said
  378          // A plain "Hello?" is already answered by the opener on screen.
  379          let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
  380          // "Sure" or "Yes" is filler while the rep talks, but a real answer to the rep's question.
  381          let repAsked = turns.last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
  382          guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else {
  383              CallTrace.event("coach.skipped", ["said": said, "why": onlyGreeting ? "a plain greeting; the opener already answers it" : "not meaningful (filler)"])
  384              return
  385          }
  386          if instantAnswer(said) { return }
  387          ask(.reply, user: CoachPrompt.reply(
  388              turns: turns, latest: said, calling: calling, details: recordDetails, style: callOpener,
  389              openTimes: bookingText()
  390          ))
  391          updateSummaryIfDue()
  392      }
  393  
  394      /// Every 4 prospect turns, Haiku writes a short summary of the call in the background, so each live
  395      /// line only needs the last minute word for word.
  396      func updateSummaryIfDue() {
  397          let total = turns.count
  398          guard CallMemoryRules.summaryDue(totalTurns: total, summaryCovers: CoachPrompt.summaryCoversTurns, inFlight: summaryInFlight),
  399                let key = Keychain.read(.anthropic) else { return }
  400          let theirs = turns.filter { $0.speaker == .prospect }.count
  401          let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
  402          let callID = CallTrace.callID // the summary belongs to this call only
  403          summaryInFlight = true
  404          Task {
  405              defer { if CallTrace.callID == callID { self.summaryInFlight = false } }
  406              var c = LiveCoach.client(key)
  407              c.maxTokens = 250
  408              var text = ""
  409              try? await c.stream(system: "Summarize a live sales call for a coach in 3 to 6 short bullets: who they are, their situation, any numbers, pains, objections raised, what was agreed. Only what was said. No preamble.",
  410                                  user: transcript) { text = $0 }
  411              guard CallMemoryRules.acceptSummary(currentCallID: CallTrace.callID, summaryCallID: callID,
  412                                                  summaryCovers: total, storedCovers: CoachPrompt.summaryCoversTurns) else {
  413                  CallTrace.event("memory.rejected", ["why": "older than the stored summary, or from another call", "covers_turns": total])
  414                  return
  415              }
  416              if !text.isEmpty {
  417                  CoachPrompt.liveSummary = text
  418                  CoachPrompt.summaryCoversTurns = total
  419                  CallTrace.memVersion += 1
  420                  CallTrace.event("memory.update", ["summary": text, "covers_turns": total, "prospect_turns": theirs, "evidence_chars": transcript.count])
  421              }
  422          }
  423      }
  424  
  425      /// "Take me off your list": the goodbye line, DoNotCall written in Salesforce, off every list, hang up. No AI.
  426      func handleOptOut(_ said: String) {
  427          guard !doNotCall else { return }
  428          yesShowTask?.cancel()
  429          let optOutCallID = CallTrace.callID
  430          doNotCall = true // terminal: every later draft, early start and queued line is blocked
  431          specTimer?.cancel()
  432          coachTask?.cancel()
  433          yesBranchTask?.cancel(); yesBranch = nil
  434          stillWithMeTask?.cancel()
  435          phoneTreeTask?.cancel()
  436          openerTask?.cancel()
  437          if let p = pending {
  438              CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "do not call"], sug: p.id)
  439          }
  440          pending = nil
  441          specHeld = nil
  442          specBasis = nil
  443          uncoached = ""
  444          thinking = false
  445          CallTrace.event("state", ["from": coachState.rawValue, "to": CoachState.doNotCall.rawValue,
  446                                    "why": "opt-out phrase", "said": said, "cancelled_request": seq])
  447          coachState = .doNotCall
  448          seq += 1
  449          show(Suggestion(say: LiveCoach.optOutLine, cue: "Opt out. Say goodbye, then hang up. Saving Do Not Call in Salesforce...", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
  450          guard let key = currentAttemptKey else { return }
  451          RemovedList.add(key)
  452          followUp = nil // no text, no LinkedIn
  453          CallTrace.event("crm.suppress", ["record": key, "actions": ["DoNotCall", "status", "off every list", "no text"]])
  454          outcomeSaved.insert(String(key.prefix(15))) // nothing more to log
  455          ActivityLog.add("Opt out from \(calling ?? key): \"\(said)\". Off every list, no text, writing DoNotCall and status")
  456          CallTrace.event("intent", ["intent": "opt_out", "said": said, "why": "opt-out phrase in their words", "action": "goodbye line and DoNotCall; the rep hangs up"])
  457          Task { [weak self] in
  458              do {
  459                  try await Salesforce.setDoNotCall(key)
  460                  ActivityLog.add("Opt out: DoNotCall saved in Salesforce for \(self?.calling ?? key)")
  461                  CallTrace.event("crm.saved", ["record": key, "field": "DoNotCall"])
  462                  // Only now say it's saved in Salesforce (the line itself stays as is).
  463                  if let self, self.suggestion.say == LiveCoach.optOutLine { self.suggestion.cue = "Opt out. Do Not Call saved in Salesforce. Hang up when you're done." }
  464              } catch {
  465                  ActivityLog.problem("Opt out: couldn't save DoNotCall in Salesforce: \(error.localizedDescription)")
  466                  CallTrace.event("crm.failed", ["record": key, "field": "DoNotCall", "error": error.localizedDescription])
  467                  if let self, CallTrace.callID == optOutCallID { // never on the next call's screen
  468                      if self.suggestion.say == LiveCoach.optOutLine {
  469                          self.suggestion.cue = "Off your list here, but Salesforce didn't save Do Not Call. Mark it by hand."
  470                      }
  471                      self.problem = "Do Not Call didn't save in Salesforce for \(self.calling ?? key). Mark it by hand."
  472                  }
  473              }
  474              // Status too: Leads go Unqualified, Contacts go Negative. Both keep them off every list.
  475              let status = key.hasPrefix("00Q") ? "Unqualified" : "Negative"
  476              do {
  477                  try await Salesforce.setStatus(of: key, to: status, note: "Asked not to be called again: \"\(said.prefix(200))\"")
  478                  ActivityLog.add("Opt out: status set to \(status)")
  479              } catch {
  480                  ActivityLog.problem("Opt out: couldn't set status to \(status): \(error.localizedDescription)")
  481              }
  482              // No automatic hang-up: the rep says goodbye and hangs up themselves.
  483          }
  484      }
  485  
  486      func prepareOpener() {
  487          // A ready-to-read line right away (from the opener template), so there's always a script
  488          // on screen before the phone rings. Claude's personal version replaces it when it's ready.
  489          seq += 1
  490          instantOpenerID = seq
  491          show(instantOpener(for: calling), id: seq, kind: .opener)
  492          // Claude's personal opener costs tokens: only for someone we'll really call, once they've been
  493          // on screen 1.5 s (a skipped person is gone by then), and one request even when several things
  494          // (page open, details loaded) ask for it at once.
  495          openerTask?.cancel()
  496          let key = recordKey()
  497          if let key, MobileOnly.excluded(key) || RemovedList.contains(key) { return }
  498          openerTask = Task { [weak self] in
  499              try? await Task.sleep(for: .milliseconds(1500))
  500              guard let self, !Task.isCancelled, self.recordKey() == key,
  501                    self.status == .ready || (self.status == .live && self.turns.isEmpty) else { return }
  502              if let key, MobileOnly.excluded(key) || RemovedList.contains(key) { return }
  503              self.ask(.opener, user: CoachPrompt.opener(calling: self.calling, details: self.recordDetails, style: self.openerStyle,
  504                                                         scriptOpener: self.openerStyle == nil ? self.scriptOpenerLine() : nil))
  505          }
  506      }
  507  
  508      func ask(_ kind: Kind, user: String, early: String? = nil) {
  509          guard let key = Keychain.read(.anthropic) else {
  510              problem = "Add your Anthropic key: gear > Setup > AI keys."
  511              return
  512          }
  513          if doNotCall, kind == .reply {
  514              CallTrace.event("claude.blocked", ["why": "do not call", "early": early != nil])
  515              return
  516          }
  517          coachTask?.cancel() // a newer statement makes the old answer stale
  518          if kind == .reply { repWordsAtLastAsk = repWordsInCall; repTextSinceAsk = "" }
  519          let repLed = nextIsRepLed
  520          nextIsRepLed = false
  521          seq += 1
  522          let id = seq
  523          if repLed { repLedIDs.insert(id) }
  524          let askedAt = Date()
  525          logSystemIfChanged()
  526          CallTrace.event("memory.snapshot", ["summary": CoachPrompt.liveSummary, "summary_version": CallTrace.memVersion,
  527                                              "question_facts": CoachPrompt.questionFacts, "objection_facts": CoachPrompt.objectionFacts, "blocker_hints": CoachPrompt.blockerHints,
  528                                              "turns": turns.count], req: id)
  529          let override = kind == .reply ? nextAskModel : nil // a space-bar fresh line uses Sonnet
  530          nextAskModel = nil
  531          let requested = (kind == .reply ? LiveCoach.client(key, model: override) : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)).model
  532          if kind == .reply { ActivityLog.add("Coach #\(id): asking \(ClaudeClient.displayName(requested))\(early == nil ? "" : " early, from their words so far")") }
  533          else { ActivityLog.add("Coach #\(id): \(kind) from \(ClaudeClient.displayName(requested))") }
  534          CallTrace.event("claude.request", [
  535              "kind": "\(kind)", "early": early != nil, "early_basis": early ?? "",
  536              "system_chars": self.system.count, "system_hash": Self.stableHash(self.system),
  537              "user_message": user, "summary_version": CallTrace.memVersion,
  538              "context": kind == .reply ? CoachPrompt.lastContext : [:], "user_chars": user.count,
  539          ], req: id)
  540          specBasis = early.map(normalized)
  541          specHeld = nil
  542          confirmedAt = nil
  543          // Live lines: Haiku, short and fast. Voicemails also Haiku, so the message is ready before the beep.
  544          let client = kind == .reply ? LiveCoach.client(key, model: override)
  545              : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)
  546          let system = self.system
  547          thinking = true
  548          CallTrace.event("claude.settings", ["model": client.model, "max_tokens": client.maxTokens, "effort": client.effort,
  549                                              "thinking": client.thinking?["type"] ?? "default", "stream": true,
  550                                              "idle_timeout_s": client.idleTimeout, "total_timeout_s": client.totalTimeout], req: id)
  551  
  552          coachTask = Task { [weak self] in
  553              do {
  554                  var finalText = ""
  555                  let gate = LineGate()
  556                  let started = Date()
  557                  var firstToken = false
  558                  try await client.stream(system: system, user: user, onText: { text in
  559                      if !firstToken, kind == .reply {
  560                          firstToken = true
  561                          ActivityLog.add("Coach #\(id): first words from Claude after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
  562                          let ms = Int(Date().timeIntervalSince(started) * 1000)
  563                          Task { @MainActor in CallTrace.event("claude.first_token", ["ms": ms], req: id) }
  564                      }
  565                      finalText = text
  566                      let s = Suggestion.parse(text)
  567                      Task { @MainActor in
  568                          guard kind == .reply else { self?.offer(s, id: id, kind: kind, askedAt: askedAt); return }
  569                          // A live line shows only once it's whole and passes the house rules.
  570                          guard (s.sayComplete && !s.stage.isEmpty) || s.skip, !gate.checked else { if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }; return }
  571                          gate.checked = true
  572                          let problems = s.skip ? [] : Self.lineProblems(s)
  573                          gate.passed = problems.isEmpty
  574                          CallTrace.event("check.result", ["stage": "stream", "line": s.say, "skip": s.skip,
  575                                                           "passed": gate.passed, "problems": problems], req: id)
  576                          if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
  577                      }
  578                  }, onUsage: { u in
  579                      // Token counts and cache use: cache_read > 0 means the system prompt came from cache.
  580                      Task { @MainActor in CallTrace.event("claude.usage", u.merging(["ms": Int(Date().timeIntervalSince(started) * 1000)]) { a, _ in a }, req: id) }
  581                  }, onModel: { served in
  582                      guard served != requested, !served.hasPrefix(requested) else { return }
  583                      Task { @MainActor in
  584                          ActivityLog.add("Coach #\(id): model switched: asked \(ClaudeClient.displayName(requested)), answered by \(ClaudeClient.displayName(served)) (fallback)")
  585                          CallTrace.event("claude.model_switch", ["requested": requested, "served": served], req: id)
  586                      }
  587                  })
  588                  if kind == .reply { ActivityLog.add("Coach #\(id): Claude done after \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
  589                  CallTrace.event("claude.done", ["ms": Int(Date().timeIntervalSince(started) * 1000), "output": finalText,
  590                                                  "fresh": self?.seq == id], req: id)
  591                  var last = Suggestion.parse(finalText)
  592                  last.sayComplete = true
  593                  if kind == .reply, !last.skip, !last.say.isEmpty {
  594                      let problems = Self.lineProblems(last)
  595                      CallTrace.event("check.result", ["stage": "final", "line": last.say, "passed": problems.isEmpty,
  596                                                       "problems": problems], req: id)
  597                      if !problems.isEmpty { last = await self?.fixLine(last, system: system, user: user, key: key, id: id) ?? last }
  598                  }
  599                  self?.offer(last, id: id, kind: kind, askedAt: askedAt)
  600              } catch is CancellationError {
  601                  CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
  602              } catch let error as URLError where error.code == .cancelled {
  603                  CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
  604              } catch {
  605                  CallTrace.event("claude.error", ["error": error.localizedDescription], req: id)
  606                  // Keep the last good line on screen; just flag it.
  607                  self?.problem = "Coach hiccup: \(error.localizedDescription)"
  608                  ActivityLog.problem("Claude error: \(error.localizedDescription)")
  609              }
  610              if self?.seq == id { self?.thinking = false }
  611          }
  612      }
  613  
  614      /// The house rules for a live line (offered meeting times are allowed).
  615      static func lineProblems(_ s: Suggestion) -> [String] {
  616          // A question is required only when the move is to learn something: answer, acknowledge and close may end plainly.
  617          let plainEnding = ["answer", "acknowledge", "close"].contains(s.move)
  618          var p = Guardrail.problems(s.say, endsCall: ["Exit", "Goal reached", "Voicemail"].contains(s.stage) || s.rowTag != nil || plainEnding, allowTimes: true)
  619          // The conversation outranks the stage (Nov 20).
  620          if RoleCheck.speaksAsProspect(s.say) {
  621              p.append("the rep claims the prospect's role: the rep is the caller, never the one who decides there")
  622          }
  623          let intent = ConversationIntent.classify(CoachPrompt.latestProspect)
  624          if s.move == "discover", intent == .question {
  625              p.append("they asked a direct question: answer it plainly first (MOVE answer), no discovery question")
  626          }
  627          if ["discover", "clarify", "objection"].contains(s.move), intent == .rejection {
  628              p.append("they declined: a clear no gets no sales question (MOVE acknowledge or close)")
  629          }
  630          // THINK is the coaching: a normal live line needs a useful one, checked against this conversation.
  631          if Think.enabled, s.rowTag == nil, !s.nudge, !s.skip {
  632              p.append(contentsOf: Think.problems(think: s.think, say: s.say, move: s.move, intent: intent,
  633                                                  objectionKind: ObjectionTracker.detect(CoachPrompt.latestProspect),
  634                                                  latestProspect: CoachPrompt.latestProspect, recentText: CoachPrompt.recentText,
  635                                                  scriptText: CoachPrompt.scriptText, answeredQuestions: CoachPrompt.answeredQuestions))
  636          }
  637          // A script row copied word for word ("S2 open" is 26 words) isn't sent back for being long.
  638          return s.rowTag == nil ? p : p.filter { !$0.contains("words (max") }
  639      }
  640  
  641      /// A problem that trimming can't fix: the move or the coaching is wrong for this moment.
  642      /// A missing or badly formatted THINK is not serious on its own (the card shows SAY, labeled).
  643      static func isSerious(_ problem: String) -> Bool {
  644          if problem.hasPrefix("THINK is missing") || problem.hasPrefix("THINK isn't usable") 
  645              // Measured: these two checks wrongly reject good pairs (10 of 40 in the THINK/SAY matrix), so they
  646              // fall back to SAY instead of hiding the line.
  647              || problem.hasPrefix("THINK and SAY aren't the same move") || problem.hasPrefix("THINK is about something that hasn't come up") { return false }
  648          return ["the rep claims", "they asked a direct", "they declined", "THINK ", "MOVE "].contains { problem.hasPrefix($0) }
  649      }
  650  
  651      /// A line broke the rules: Haiku tries again with the reasons, then Sonnet, then the smallest safe fix.
  652      func fixLine(_ bad: Suggestion, system: String, user: String, key: String, id: Int = 0) async -> Suggestion {
  653          var problems = Self.lineProblems(bad)
  654          ActivityLog.add("Line check: failed (\(problems.joined(separator: "; "))): \(bad.say)")
  655          CallTrace.event("check.fail", ["line": bad.say, "problems": problems], req: id)
  656          // Formatting only (an abbreviation like CRM, an em dash): fix it in code, no second request.
  657          if problems.allSatisfy({ $0.hasPrefix("abbreviation") || $0 == "em dash" || $0 == "more than one question" }),
  658             let fixed = LineRepair.fix(bad.say) {
  659              var s = bad
  660              s.say = fixed
  661              // Spelled-out words add syllables: allow half a grade of slack on a repaired line (M6).
  662              let left = Self.lineProblems(s).filter { !($0.hasPrefix("reading level") && ReadingLevel.grade(fixed) <= ReadingLevel.checkMax + 0.5) }
  663              if left.isEmpty {
  664                  ActivityLog.add("Line check: fixed in code (no extra request)")
  665                  CallTrace.event("check.fixed_locally", ["from": bad.say, "line": fixed], req: id)
  666                  return s
  667              }
  668          }
  669          for model in [LiveCoach.callModel] { // one retry at most, on this call's model (H4)
  670              var text = ""
  671              let retry = user + "\n\nYour last answer broke these rules: \(problems.joined(separator: "; ")). THINK was: \"\(bad.think)\". SAY was: \"\(bad.say)\". Write MOVE, STAGE, THINK, SAY and CUE again."
  672              CallTrace.event("claude.retry.request", ["model": model, "user_message": retry], req: id)
  673              let t0 = Date()
  674              ActivityLog.add("Line check: asking \(ClaudeClient.displayName(model)) to fix it")
  675              try? await LiveCoach.client(key, model: model).stream(system: system, user: retry) { text = $0 }
  676              var s = Suggestion.parse(text)
  677              s.sayComplete = true
  678              let left = s.skip ? [] : Self.lineProblems(s)
  679              CallTrace.event("claude.retry.done", ["model": model, "ms": Int(Date().timeIntervalSince(t0) * 1000), "output": text,
  680                                                    "passed": !s.say.isEmpty && left.isEmpty, "problems": left], req: id)
  681              if s.skip || (!s.say.isEmpty && Self.lineProblems(s).isEmpty) {
  682                  ActivityLog.add("Line check: fixed by \(model.contains("haiku") ? "Haiku" : "Sonnet")")
  683                  CallTrace.event("check.fixed", ["model": model, "line": s.say], req: id)
  684                  return s
  685              }
  686              if !s.say.isEmpty { problems = Self.lineProblems(s) }
  687          }
  688          // Final check. Formatting (length, an abbreviation, the question mark) can be trimmed safely. A wrong move,
  689          // a role mix-up, or a THINK that doesn't fit the conversation can't: show nothing new instead.
  690          if Self.lineProblems(bad).contains(where: Self.isSerious) {
  691              var quiet = bad
  692              quiet.skip = true
  693              quiet.move = "silent"
  694              ActivityLog.add("Line check: dropped (wrong move for the conversation): \(bad.say)")
  695              CallTrace.event("check.dropped", ["line": bad.say, "problems": Self.lineProblems(bad)], req: id)
  696              return quiet
  697          }
  698          var s = bad
  699          s.say = LiveCoach.sanitize(bad.say)
  700          ActivityLog.add("Line check: trimmed to fit: \(s.say)")
  701          CallTrace.event("check.trimmed", ["line": s.say, "from": bad.say], req: id)
  702          return s
  703      }
  704  
  705      /// Shows a suggestion, but never swaps a fresh line out from under the rep.
  706      func offer(_ s: Suggestion, id: Int, kind: Kind, askedAt: Date) {
  707          guard id == seq, !s.skip, !s.say.isEmpty, !doNotCall else { // do not call: nothing replaces the goodbye
  708              // MOVE: silent: keep the line if it still fits; clear it if the talk moved past it.
  709              let movedOn: Bool = {
  710                  guard let last = turns.last, last.speaker == .prospect else { return lineSuperseded }
  711                  let repAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
  712                  return lineSuperseded || repAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?")
  713              }()
  714              if s.move == "silent", id == seq, !doNotCall, status == .live, !suggestion.say.isEmpty,
  715                 SilentRule.clearNow(superseded: movedOn, delivered: lineDelivered, answered: answeredAfterDelivery, signals: signals()) {
  716                  CallTrace.event("suggestion.cleared", ["line": suggestion.say, "why": "Claude chose silent and the line was outdated"], sug: shownID)
  717                  suggestion = Suggestion()
  718                  lineSuperseded = false
  719              }
  720              if s.sayComplete || s.skip {
  721                  let why = doNotCall ? "do not call" : id != seq ? "stale: request #\(seq) is newer" : s.move == "silent" ? "Claude chose silent: no new line needed" : s.skip ? "Claude said skip" : "empty"
  722                  CallTrace.event("suggestion.dropped", ["line": s.say, "why": why], sug: id)
  723              }
  724              return
  725          }
  726          // Easier to read live: show the line once it's whole, not word by word (setting).
  727          let wholeLine = Prefs.wholeLine
  728          if wholeLine && !s.sayComplete { return }
  729          if specBasis != nil {
  730              if s.sayComplete, specHeld?.id != id {
  731                  CallTrace.event("suggestion.held_early", ["line": s.say, "basis": specBasis ?? "", "why": "drafted early: waits for them to stop"], sug: id)
  732              }
  733              specHeld = (s, id) // started early: wait until they really stop talking
  734              return
  735          }
  736          if kind == .reply, timedID != id {
  737              timedID = id // time from "they stopped talking" to the first words of the answer
  738              latency = max(0, Date().timeIntervalSince(confirmedAt ?? askedAt))
  739          }
  740          if id == shownID {
  741              // Once a line is whole on screen, its words are frozen: a late chunk never changes it (N2).
  742              if suggestion.sayComplete { return }
  743              if frozenShownID == id { return }
  744              if status == .live, signals().repSpeaking || !(interim[.rep] ?? "").isEmpty { frozenShownID = id; return } // reading it: freeze for good
  745              if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
  746              var s = s
  747              s.say = fillTags(s.say, for: calling) // never show a bare [Name] or [SDR]
  748              suggestion = s // same answer, still streaming in
  749              note(s)
  750              return
  751          }
  752          // The call is live and someone already talked: keep the opener the rep is reading.
  753          if kind == .opener, status == .live, repWordsInCall > 0 || turns.contains(where: { $0.speaker == .prospect })
  754              || signals().repSpeaking || !(interim[.rep] ?? "").isEmpty {
  755              if s.sayComplete { CallTrace.event("suggestion.dropped", ["line": s.say, "why": "opener arrived after the talk started"], sug: id) }
  756              return
  757          }
  758          // The AI thinks ahead, the screen follows the conversation: never swap the line while the rep is
  759          // speaking. Queue it, flag the old one as outdated, and show it the moment they stop.
  760          // A new prospect turn since the line appeared = the conversation moved on.
  761          // Only a real reply moves the conversation on (3+ words or a question), not "uh-huh" or "yeah".
  762          // Any answer to a question you asked counts too, even "yes" or "nope", so you never have to press Next.
  763          let youAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
  764          if kind == .reply, repLedIDs.contains(id), !lineSuperseded || supersededLogged != shownID {
  765              supersededLogged = shownID
  766              CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id,
  767                                                        "why": "the rep moved on in their own words", "delivered": lineDelivered], sug: shownID)
  768              lineSuperseded = true
  769          }
  770          if kind == .reply, let last = turns.last, last.speaker == .prospect,
  771             youAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?") {
  772              if !lineSuperseded || supersededLogged != shownID {
  773                  supersededLogged = shownID
  774                  let why = youAsked ? "they answered your question" : last.text.contains("?") ? "they asked a question" : "they said something new (3+ words)"
  775                  CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id, "prospect_said": last.text,
  776                                                            "why": why, "delivered": lineDelivered], sug: shownID)
  777                  ActivityLog.add("Coach #\(shownID): line outdated (\(why))")
  778              }
  779              lineSuperseded = true
  780          }
  781          // The rep moved past it while it was being written (asked, pivoted, or kept talking): drop it (round 2 #1).
  782          let readingOnScript = !lineDelivered && Delivery.onLine(line: suggestion.say, spoken: recentRepChunks.joined(separator: " "))
  783          let staleWhy = kind == .reply && id != shownID
  784              ? QueuedLine.staleReason(ageSeconds: 0, repWordsSinceQueued: readingOnScript ? 0 : repWordsInCall - repWordsAtLastAsk,
  785                                       repAskedSinceQueued: QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
  786                                                                                            lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate),
  787                                       repTextSinceQueued: repTextSinceAsk)
  788              : nil
  789          if freshLineIDs.contains(id) { // the rep pressed space: show it now, whatever is on screen
  790              defer { freshLineIDs.remove(id) } // still marked while show() counts it
  791              CallTrace.event("suggestion.fresh", ["line": s.say, "why": "the rep asked for a fresh line"], sug: id)
  792              show(s, id: id, kind: kind)
  793              return
  794          }
  795          let decision = CoachController.offer(isOpenerOrVoicemail: kind == .opener || kind == .voicemail, firstLine: shownID == 0,
  796                                               holdLine: holdLine, signals: signals(), staleReason: staleWhy)
  797          if case .drop(let why) = decision {
  798              CallTrace.event("suggestion.discarded", ["line": s.say, "why": "stale on arrival: \(why)", "rule": QueuedLine.ruleKind(why)], sug: id)
  799              // Only when they talked on in their own words: after a question or a pivot, the prospect's answer comes next.
  800              if why.hasPrefix("the rep said") { followRep(why: "the line arrived after the rep moved on") }
  801              return
  802          }
  803          if decision == .show {
  804              show(s, id: id, kind: kind)
  805          } else {
  806              if pending?.id != id {
  807                  let why = holdLine ? "held by you" : repSpeaking ? "you're speaking" : "you may be reading"
  808                  ActivityLog.add("Coach #\(id): line queued (\(why))")
  809                  CallTrace.event("suggestion.queued", ["line": s.say, "why": why, "signals": signals().trace], sug: id)
  810              }
  811              if let old = pending, old.id != id {
  812                  CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer queued line replaced it"], sug: old.id)
  813              }
  814              if pending?.id != id {
  815                  pendingQueuedAt = Date()
  816                  repWordsAtQueue = repWordsAtLastAsk // what the rep had said when this line was asked for
  817                  // C4: a question the rep asked while this line was still being written counts too.
  818                  repAskedSinceQueue = QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
  819                                                                       lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate)
  820              }
  821              pending = (id, s)
  822          }
  823      }
  824  
  825      /// Same text, same hash, on every run (Swift's hashValue changes each launch).
  826      static func stableHash(_ s: String) -> String {
  827          var h: UInt64 = 0xcbf29ce484222325
  828          for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
  829          return String(h, radix: 16)
  830      }
  831  
  832      /// The full system prompt goes in the trace at call start and again whenever it changes.
  833      func logSystemIfChanged() {
  834          let h = Self.stableHash(system)
  835          guard h != loggedSystemHash else { return }
  836          loggedSystemHash = h
  837          CallTrace.event("context.system", ["text": system, "hash": h])
  838      }
  839  
  840      /// The approved script answer for what they said, shown with no AI wait. True if one matched.
  841      func instantAnswer(_ said: String) -> Bool {
  842          guard status == .live, !doNotCall else { return false }
  843          let answers = scriptAnswers
  844          // Only when they're answering the rep's question: otherwise a phrase match is out of context.
  845          let repJustAsked = turns.dropLast().last { $0.speaker == .rep }?.text.contains("?") ?? false
  846          // Never ahead of higher-priority rules: a direct question, a no or a sign-off goes to the full coach.
  847          let (hit, why) = answers.matchInContext(said, answeredQuestions: CoachPrompt.answeredQuestions)
  848          guard repJustAsked, let e = hit else {
  849              CallTrace.event("script.match", ["searched": answers.entries.count, "matched": false, "said": said,
  850                                               "intent": ConversationIntent.classify(said).rawValue,
  851                                               "why": repJustAsked ? why : "the rep hadn't just asked a question"])
  852              return false
  853          }
  854          CallTrace.event("script.match", ["searched": answers.entries.count, "matched": true, "row": e.id,
  855                                           "phrases": e.phrases, "said": said, "answer": e.say, "why": why])
  856          if suggestion.say == e.say || pending?.suggestion.say == e.say { return true } // already up
  857          coachTask?.cancel() // any slower AI draft for this is stale now
  858          thinking = false
  859          specBasis = nil
  860          specHeld = nil
  861          markRequestStart()
  862          seq += 1
  863          ActivityLog.add("Coach #\(seq): instant answer from your script (\(e.id)), no AI")
  864          offer(Suggestion(say: e.say, cue: "From your script: \(e.id)", stage: "Objection", sayComplete: true),
  865                id: seq, kind: .reply, askedAt: Date())
  866          return true
  867      }
  868  
  869      /// Called twice a second: a queued line shows once the rep stops speaking.
  870      func promotePendingIfReady() {
  871          guard status == .live, let p = pending, CoachMachine.isFresh(requestID: p.id, latestID: seq) else { return }
  872          let decision = CoachController.promote(holdLine: holdLine, signals: signals(),
  873                                                 ageSeconds: Date().timeIntervalSince(pendingQueuedAt),
  874                                                 repWordsSinceQueued: repWordsInCall - repWordsAtQueue,
  875                                                 repAskedSinceQueued: repAskedSinceQueue, repTextSinceQueued: repTextSinceAsk)
  876          guard decision != .wait else {
  877              if blockedLoggedID != p.id { // once per queued line, not every tick
  878                  blockedLoggedID = p.id
  879                  CallTrace.event("promotion.blocked", ["why": holdLine ? "held by the rep" : "not safe to replace yet",
  880                                                        "signals": signals().trace], sug: p.id)
  881              }
  882              return
  883          }
  884          // The rep's words are the source of truth: if they moved on while this waited, it's stale.
  885          if case .drop(let why) = decision {
  886              pending = nil
  887              ActivityLog.add("Coach #\(p.id): queued line dropped (\(why); \(QueuedLine.ruleKind(why)) rule)")
  888              CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)",
  889                                                       "rule": QueuedLine.ruleKind(why)], sug: p.id)
  890              // They asked their own question: the next move is the prospect's answer. Otherwise write the
  891              // next line from where the rep actually is.
  892              if !repAskedSinceQueue { followRep() }
  893              return
  894          }
  895          ActivityLog.add("Coach #\(p.id): queued line shown")
  896          CallTrace.event("suggestion.promoted", ["why": "safe to replace now (rep stopped, line read or delivered)"], sug: p.id)
  897          show(p.suggestion, id: p.id, kind: .reply)
  898      }
  899  
  900      /// The rep went off script and paused without asking anything: the next line builds on what they
  901      /// actually said, not on what the script expected.
  902      func followRep(why: String = "the rep moved on from the queued line") {
  903          guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
  904                let rep = turns.last, rep.speaker == .rep else { return }
  905          CallTrace.event("follow_rep", ["rep_said": rep.text, "why": why])
  906          followsThisStretch += 1
  907          nextIsRepLed = true
  908          ask(.reply, user: CoachPrompt.reply(turns: turns, latest: rep.text, calling: calling, details: recordDetails,
  909                                              style: callOpener, openTimes: bookingText(), repLed: true))
  910      }
  911  
  912      /// After each thing the rep says: if they're off script, get the next line ready now, while they
  913      /// talk, so it's waiting when they pause. A queued line they've moved past is dropped first.
  914      func prepareWhileRepTalks(_ text: String) {
  915          guard status == .live, !doNotCall, !voicemailActive, !screenerActive, !suggestion.say.isEmpty else { return }
  916          let since = repWordsInCall - repWordsAtLastAsk
  917          guard !followPausedUntilQuiet,
  918                FollowRepLimit.allowed(repWordsSinceLastAsk: since, followsThisStretch: followsThisStretch) else { return }
  919          guard FollowRep.shouldPrepare(repJustSaid: text, recentRepSpeech: recentRepChunks.joined(separator: " "),
  920                                        shownLine: suggestion.say, shownLineDelivered: lineDelivered,
  921                                        repWordsSinceLastAsk: since) else { return }
  922          if let p = pending {
  923              pending = nil
  924              let why = "the rep said \(since) words of their own since"
  925              ActivityLog.add("Coach #\(p.id): queued line dropped while you talk (\(why); heuristic rule)")
  926              followPausedUntilQuiet = true // they're on their own roll: no more drafts until they pause
  927              CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)", "rule": "heuristic"], sug: p.id)
  928          }
  929          followRep(why: "preparing ahead: the rep is off script (\(since) words since the last request)")
  930      }
  931  
  932      /// The rep just asked a yes/no question: write the line for "yes" now, while they wait for the
  933      /// answer. It's held, never shown, until the prospect actually says yes. Open questions ("What do
  934      /// you use?") get nothing ahead: the answer comes from their real words.
  935      func prepareYesBranch(_ text: String) {
  936          // Keep the ready line through small talk; drop it for a new question or once the talk moved on (H3).
  937          if yesBranch != nil {
  938              yesBranchRepWords += text.split(separator: " ").count
  939              if YesBranchRule.keep(afterRepSaid: text, wordsSinceQuestion: yesBranchRepWords) { return }
  940              CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "the rep moved on or asked a new question"])
  941          }
  942          yesBranchTask?.cancel()
  943          yesBranch = nil
  944          yesBranchWanted = nil
  945          guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
  946                let q = RepQuestion.closedQuestion(in: text), let key = Keychain.read(.anthropic) else { return }
  947          yesBranchRepWords = 0
  948          yesBranchAskedAt = Date()
  949          let user = CoachPrompt.reply(turns: turns, latest: q, calling: calling, details: recordDetails, style: callOpener,
  950                                       openTimes: bookingText(), assumeYes: true)
  951          let system = self.system
  952          yesBranch = (q, Suggestion(say: "", cue: "", stage: ""), false)
  953          CallTrace.event("yes_branch.request", ["question": q, "user_message": user])
  954          let started = Date()
  955          yesBranchTask = Task { [weak self] in
  956              var text = ""
  957              try? await LiveCoach.client(key).stream(system: system, user: user, onText: { text = $0 }, onUsage: { u in
  958                  Task { @MainActor in CallTrace.event("claude.usage", u.merging(["yes_branch": 1]) { a, _ in a }) }
  959              })
  960              guard let self, !Task.isCancelled, self.yesBranch?.question == q else { return }
  961              CallTrace.event("claude.done", ["yes_branch": true, "ms": Int(Date().timeIntervalSince(started) * 1000), "output": text])
  962              var s = Suggestion.parse(text)
  963              s.sayComplete = true
  964              let problems = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
  965              if !problems.isEmpty, let fixed = LineRepair.fix(s.say) { s.say = fixed }
  966              let left = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
  967              CallTrace.event("yes_branch.ready", ["question": q, "line": s.say, "ms": Int(Date().timeIntervalSince(started) * 1000),
  968                                                   "passed": left.isEmpty, "problems": left])
  969              if left.isEmpty { self.yesBranch = (q, s, true) } else { self.yesBranch = nil }
  970              // They already said yes while this was being written: show it now, or fall back to a normal answer.
  971              if let said = self.yesBranchWanted {
  972                  self.yesBranchWanted = nil
  973                  self.yesBranch = nil
  974                  if left.isEmpty, self.status == .live, !self.doNotCall {
  975                      CallTrace.event("yes_branch.used", ["question": q, "answer": said, "line": s.say, "late": true])
  976                      self.markRequestStart()
  977                      self.seq += 1
  978                      self.offer(s, id: self.seq, kind: .reply, askedAt: Date())
  979                  } else {
  980                      self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
  981                                                               details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
  982                  }
  983              }
  984          }
  985      }
  986  
  987      /// The possible opt-out's timer: (re)started on the phrase and on any new prospect words. When it runs out with
  988      /// no later time said, it's an opt-out.
  989      func armPendingOptOutTimer() {
  990          pendingOptOutTask?.cancel()
  991          pendingAmbiguousAt = Date()
  992          pendingOptOutTask = Task { [weak self] in
  993              try? await Task.sleep(for: .seconds(PendingOptOut.timeout))
  994              guard let self, !Task.isCancelled, let p = self.pendingAmbiguousOptOut else { return }
  995              let later = self.uncoached.trimmingCharacters(in: .whitespaces)
  996              switch PendingOptOut.resolve(pending: p, later: later, utteranceEnded: false, callEnded: false,
  997                                           secondsWaited: PendingOptOut.timeout) {
  998              case .optOut:
  999                  self.pendingAmbiguousOptOut = nil
 1000                  CallTrace.event("optout.timeout", ["said": p, "why": "no later time within \(PendingOptOut.timeout) s"])
 1001                  self.handleOptOut((p + " " + later).trimmingCharacters(in: .whitespaces))
 1002              case .callback:
 1003                  self.pendingAmbiguousOptOut = nil
 1004                  CallTrace.event("optout.not", ["said": p + " " + later, "why": "a later time followed: a callback request"])
 1005              case .wait: break
 1006              }
 1007          }
 1008      }
 1009  
 1010      /// A yes line or script answer is a new request too: what the rep said before it doesn't make it stale.
 1011      func markRequestStart() {
 1012          repWordsAtLastAsk = repWordsInCall
 1013          repTextSinceAsk = ""
 1014      }
 1015  
 1016      /// The Next button: show the queued line now.
 1017      func promoteNow() {
 1018          guard !doNotCall, let p = pending else { return } // Fix 2
 1019          ActivityLog.add("Coach: Next clicked, queued line shown")
 1020          CallTrace.event("manual", ["action": "Next"], sug: p.id)
 1021          show(p.suggestion, id: p.id, kind: .reply)
 1022      }
 1023  
 1024      func show(_ s: Suggestion, id: Int, kind: Kind) {
 1025          // After an opt-out, only the goodbye line may ever show (round 2 #3).
 1026          if doNotCall, s.say != LiveCoach.optOutLine {
 1027              CallTrace.event("suggestion.dropped", ["line": s.say, "why": "do not call", "kind": "\(kind)"], sug: id)
 1028              return
 1029          }
 1030          if status == .live, !s.say.isEmpty {
 1031              let ms = lastHeardThemAt.map { Int(Date().timeIntervalSince($0) * 1000) }
 1032              ActivityLog.add("Coach line shown (\(kind)\(ms.map { ", \($0) ms after their last words" } ?? "")): \(s.say)")
 1033          }
 1034          var s = s
 1035          // THINK that doesn't hold up against this conversation never reaches the card: SAY shows instead, on purpose
 1036          // (the card says "SAY THIS"), and the reason is in the trace.
 1037          if status == .live, kind == .reply, Think.enabled, s.rowTag == nil, !s.nudge, !s.think.isEmpty {
 1038              let why = Think.problems(think: s.think, say: s.say, move: s.move, intent: ConversationIntent.classify(CoachPrompt.latestProspect),
 1039                                       objectionKind: ObjectionTracker.detect(CoachPrompt.latestProspect),
 1040                                       latestProspect: CoachPrompt.latestProspect, recentText: CoachPrompt.recentText,
 1041                                       scriptText: CoachPrompt.scriptText, answeredQuestions: CoachPrompt.answeredQuestions)
 1042              if !why.isEmpty {
 1043                  CallTrace.event("think.fallback", ["think": s.think, "say": s.say, "problems": why], sug: id)
 1044                  s.think = ""
 1045              }
 1046          } else if status == .live, kind == .reply, Think.enabled, s.rowTag == nil, !s.nudge, s.think.isEmpty {
 1047              CallTrace.event("think.fallback", ["think": "", "say": s.say, "problems": ["THINK was missing"]], sug: id)
 1048          }
 1049          s.say = fillTags(s.say, for: calling) // [SDR], {first name} and other slots Claude copied from the script
 1050          // Still an unfilled slot ([Day], [Firm] we don't know): never show it. Keep the current line (script rule).
 1051          if status == .live, kind == .reply, TokenFill.hasOpenSlot(s.say) {
 1052              CallTrace.event("suggestion.dropped", ["line": s.say, "why": "a [slot] couldn't be filled"], sug: id)
 1053              ActivityLog.add("Coach: a line had a blank to fill (\(s.say)); kept the current line")
 1054              showToast("No line with a blank in it. Say it your way, or press space for a fresh one.")
 1055              return
 1056          }
 1057          if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
 1058          if let old = pending, old.id != id {
 1059              ActivityLog.add("Coach #\(old.id): queued line discarded (newer one shown)")
 1060              CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer line was shown"], sug: old.id)
 1061          }
 1062          if status == .live, kind == .reply || kind == .opener, !s.say.isEmpty {
 1063              CoachPrompt.shownLines.append(s.say)
 1064              // Model test: only lines the call's model wrote (not the instant opener, script answers or a space-bar
 1065              // Sonnet line), and a line replaced before it could be read doesn't count as ignored.
 1066              if testLineCounted, !lineDelivered, Date().timeIntervalSince(shownAt) < 2 { callLinesShown -= 1 }
 1067              testLineCounted = kind == .reply && !s.nudge && s.say != LiveCoach.optOutLine && !freshLineIDs.contains(id)
 1068                  && !s.cue.hasPrefix("From your script") && !s.cue.hasPrefix("Two no")
 1069              if testLineCounted { callLinesShown += 1 }
 1070          }
 1071          if status == .live {
 1072              CallTrace.event("suggestion.shown", ["line": s.say, "think": s.think, "think_mode": Think.enabled, "cue": s.cue, "stage": s.stage, "move": s.move, "label": LineLook.label(move: s.move, exact: s.rowTag != nil), "key_part": LineLook.emphasis(s.say)?.key ?? "", "kind": "\(kind)",
 1073                                                   "replaced": suggestion.say, "replaced_delivered": lineDelivered], sug: id)
 1074          }
 1075          pending = nil
 1076          lineSuperseded = false
 1077          if kind == .reply { repTextSinceAsk = ""; repWordsAtLastAsk = repWordsInCall } // round 2 #9
 1078          priorLineOfferedTime = !suggestion.offered.isEmpty || GoalEvidence.mentionsTime(suggestion.say)
 1079          // The old line: partly said in the rep's own words? Then it isn't "never said" (H1).
 1080          if status == .live, !suggestion.say.isEmpty, !lineDelivered,
 1081             Delivery.likelyCovered(line: suggestion.say, spoken: repSaidSinceShown),
 1082             !CoachPrompt.likelyCoveredLines.contains(suggestion.say) {
 1083              CoachPrompt.likelyCoveredLines.append(suggestion.say)
 1084              CallTrace.event("delivery.likely", ["line": suggestion.say, "said": repSaidSinceShown,
 1085                                                  "confidence": Delivery.confidence(line: suggestion.say, spoken: repSaidSinceShown)], sug: shownID)
 1086          }
 1087          repSaidSinceShown = ""
 1088          lineDelivered = false
 1089          answeredAfterDelivery = false
 1090          shownID = id
 1091          shownAt = Date()
 1092          repWordsSinceShown = 0
 1093          suggestion = s
 1094          historyIndex = nil
 1095          if !s.say.isEmpty, s.sayComplete || kind != .reply { history.append((s: s, kind: kind)) }
 1096          self.kind = kind
 1097          problem = nil
 1098          note(s)
 1099      }
 1100  
 1101      /// Bookkeeping for what a line tells us: stage reached, times offered, goal, voicemail.
 1102      func note(_ s: Suggestion) {
 1103          if status != .ready, !s.stage.isEmpty {
 1104              stagesSeen.insert(s.stage)
 1105              trackJourney(s.stage)
 1106          }
 1107          if voicemailActive, !s.textMessage.isEmpty || !s.linkedin.isEmpty || !s.linkedinMessage.isEmpty { fillFollowUp(from: s) }
 1108          // Remember which meeting times this line offered, so the next ones are different.
 1109          if !s.offered.isEmpty {
 1110              let dates = s.offered.compactMap { code in codeByDate.first { $0.value == code }?.key }
 1111              offeredTimes.formUnion(dates)
 1112              nextOffer = pickNextPair(from: availability.offerSlots())
 1113          }
 1114          if s.stage == "Closing" { availability.refreshIfOlder() } // fresh times while booking
 1115          // A closing line on screen is only a pending goal; the prospect's words confirm it (N4).
 1116          if s.stage == "Goal reached", !goalHit {
 1117              goalPending = true
 1118              goalPendingTurns = 2
 1119              // They often agree first ("Tuesday works") and the closing line follows: check their last words too.
 1120              if let last = turns.last(where: { $0.speaker == .prospect }) { confirmGoalIfAgreed(last.text, checkingEarlierTurn: true) }
 1121          }
 1122          // The model's stage is a hint only: it never decides voicemail or pickups (rules do),
 1123          // so swapping Haiku and Sonnet can't change the numbers.
 1124          if !s.stage.isEmpty { attempt?.modelStage(s.stage) }
 1125          if s.stage == "Voicemail", !sawVoicemail { CallTrace.event("voicemail.model_hint", ["why": "the model said Voicemail; rules decide"]) }
 1126      }
 1127  
 1128      func scheduleStillWithMe() {
 1129          stillWithMeTask?.cancel()
 1130          guard let last = turns.last, last.speaker == .rep,
 1131                RepQuestion.asQuestion(last.text).hasSuffix("?") || !QuestionTracker.questions(in: last.text).isEmpty,
 1132                turns.contains(where: { $0.speaker == .prospect }),
 1133                !voicemailActive, !screenerActive, !phoneTreeActive, !badNumberThisCall else { return }
 1134          let askedAt = lastWordsAt
 1135          stillWithMeTask = Task { [weak self] in
 1136              try? await Task.sleep(for: .seconds(6))
 1137              guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall, !self.thinking, self.pending == nil,
 1138                    self.lineDelivered, // only after a line was said, then real silence (never over the rep's own thought)
 1139                    self.lastWordsAt == askedAt,
 1140                    self.turns.last?.speaker == .rep, !self.voicemailActive,
 1141                    (self.interim[.prospect] ?? "").isEmpty, // they're mid-answer
 1142                    !self.signals().repSpeaking, (self.interim[.rep] ?? "").isEmpty,
 1143                    CoachMachine.canReplace({ var x = self.signals(); x.queuedIsForNewTopic = true; return x }()) else { return } // never over the rep (C6)
 1144              self.coachTask?.cancel()
 1145              self.thinking = false
 1146              self.seq += 1
 1147              var nudge = Suggestion(say: "Still with me?", cue: "6 seconds of silence after your question.",
 1148                                     stage: "", sayComplete: true)
 1149              nudge.nudge = true
 1150              self.show(nudge, id: self.seq, kind: .reply)
 1151              self.repWordsSinceShown = 99 // a nudge, not a script line: never hold the prospect's answer for it
 1152          }
 1153      }
 1154  
 1155      /// Switches (or refreshes) the campaign. Takes effect right away between calls.
 1156      /// Refreshes the opener after a setting changes (rotation, your name).
 1157      func refreshOpener() {
 1158          if status == .ready { prepareOpener() }
 1159      }
 1160  }
 1161  
```


## `mac/Sources/ClarityLiveCoach/CoachModel+Audio.swift`

```swift
    1  import AppKit
    2  import CoachCore
    3  import AVFoundation
    4  import Combine
    5  import CoreAudio
    6  import Foundation
    7  
    8  /// Listening: audio capture, the two transcription streams, and what each word means.
    9  extension CoachModel {
   10      func startAudio() -> Bool {
   11          pendingStop?.cancel() // a new call: keep the old tap from being removed later
   12          pendingStop = nil
   13          guard let deepgramKey = Keychain.read(.deepgram) else {
   14              problem = "Add your Deepgram key: gear > Setup > AI keys."
   15              return false
   16          }
   17          streams.set(rep: openStream(.rep, key: deepgramKey), prospect: openStream(.prospect, key: deepgramKey))
   18  
   19          // The Aircall phone inside the coach hands over the call audio itself: no Core Audio tap,
   20          // so nothing glitches (like the hang-up tone). If it doesn't within 4 s, use the tap.
   21          if AircallPhone.isOn {
   22              let streams = self.streams
   23              let phone = AircallPhone.shared
   24              phone.onAudio = { isRep, pcm in streams.send(pcm, isRep: isRep) }
   25              directAudio = true
   26              ActivityLog.add("Listening straight from the Aircall phone")
   27              let startedAt = Date()
   28              directCheck?.cancel()
   29              directCheck = Task { [weak self] in
   30                  // Check at 4 s and again at 8 s: the other side must have real sound by then
   31                  // (ringback or a voicemail greeting), or the phone isn't sharing the call: use the tap.
   32                  for checkAt in [4.0, 8.0] {
   33                      try? await Task.sleep(for: .seconds(4))
   34                      guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
   35                      if phone.lastRemoteAudio > startedAt { break }
   36                      if checkAt < 8 { continue }
   37                      phone.onAudio = nil
   38                      self.directAudio = false
   39                      ActivityLog.problem("No sound from the Aircall phone after 8 s; using the audio tap")
   40                      if !self.startTap() { self.stopAudio() }
   41                      return
   42                  }
   43                  guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
   44                  if phone.lastLocalAudio < startedAt {
   45                      // The other side comes through, the rep's mic doesn't: add the Mac's mic.
   46                      phone.onAudio = { isRep, pcm in if !isRep { streams.send(pcm, isRep: false) } }
   47                      do {
   48                          try self.capture.startMicOnly { isRep, speech in
   49                              guard let samples = speech.int16ChannelData?[0] else { return }
   50                              streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: true)
   51                          }
   52                          ActivityLog.add("Rep's side: Mac mic (the phone didn't share it)")
   53                      } catch {
   54                          ActivityLog.problem("Mic failed: \(error.localizedDescription)")
   55                      }
   56                  } else {
   57                      ActivityLog.add("Hearing both sides straight from the Aircall phone")
   58                  }
   59              }
   60              return true
   61          }
   62          return startTap()
   63      }
   64  
   65      /// The old way: a Core Audio tap on the call app's sound, plus the mic.
   66      func startTap() -> Bool {
   67          let chrome = AudioProcess.callAudioTargets(in: AudioProcess.others())
   68          guard !chrome.isEmpty else {
   69              callMessage = "Can't hear the call yet. Open the Aircall app (or Aircall in Chrome) and start the call."
   70              ActivityLog.problem("Listening failed: no Aircall or Chrome audio found")
   71              return false
   72          }
   73          do {
   74              let streams = self.streams
   75              try capture.start(processes: chrome) { isRep, speech in
   76                  guard let samples = speech.int16ChannelData?[0] else { return }
   77                  streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: isRep)
   78              }
   79              ActivityLog.add("Listening to: \(Self.names(of: chrome))")
   80              return true
   81          } catch {
   82              streams.closeAll()
   83              callMessage = "The coach couldn't start listening: \(error.localizedDescription). The call still works; coaching is off for it."
   84              ActivityLog.problem("Listening failed: \(error.localizedDescription)")
   85              return false
   86          }
   87      }
   88  
   89      /// Process names for the log.
   90      static func names(of ids: [AudioObjectID]) -> String {
   91          let all = AudioProcess.others()
   92          let names = ids.compactMap { id in all.first { $0.id == id }?.name }
   93          return names.isEmpty ? "\(ids.count) process(es)" : Set(names).sorted().joined(separator: ", ")
   94      }
   95  
   96      /// Listening starts a second after dialing, sometimes before Aircall's call audio exists.
   97      /// Once Aircall is clearly on the call, make sure that's what the app listens to.
   98      func followCallAudio() {
   99          guard !directAudio else { return } // the phone hands over its audio itself
  100          let processes = AudioProcess.others()
  101          guard AudioProcess.aircallAppOnCall(in: processes) || AudioProcess.chromeOnCall(in: processes) else { return }
  102          let targets = AudioProcess.callAudioTargets(in: processes)
  103          // Only add missing call audio (never drop what's working), and at most twice a call.
  104          guard retargets < 2, !targets.isEmpty, !Set(targets).isSubset(of: Set(capture.tapTargets)) else { return }
  105          retargets += 1
  106          do {
  107              try capture.retargetTap(processes: targets)
  108              ActivityLog.add("Switched listening to: \(Self.names(of: targets))")
  109          } catch {
  110              ActivityLog.add("Couldn't switch listening: \(error.localizedDescription)")
  111          }
  112      }
  113  
  114      /// Stops listening. Transcription stops right away, but the audio tap is removed a few
  115      /// seconds later: tearing it down while Aircall plays the hang-up tone makes that tone
  116      /// stutter and repeat.
  117      func stopAudio() {
  118          AircallPhone.shared.onAudio = nil
  119          directCheck?.cancel()
  120          directAudio = false
  121          streams.closeAll()
  122          pendingStop?.cancel()
  123          pendingStop = Task { [weak self] in
  124              try? await Task.sleep(for: .seconds(3))
  125              guard let self, !Task.isCancelled else { return }
  126              self.pendingStop = nil
  127              self.capture.stop()
  128          }
  129      }
  130  
  131      /// One line about what the app is doing, for bug reports.
  132      func debugSummary() -> String {
  133          "status=\(status) person=\(calling ?? "none") page=\(SalesforceTab.currentRecord() ?? "none") " +
  134          "waitingFor=\(gettingReady == nil ? "-" : waitingFor()) voicemailFor=\(voicemailFor ?? "none") " +
  135          "followUp=\(followUp?.prospect ?? "none") autoDial=\(autoDial) attempts=\(currentAttempts) " +
  136          "salesforce=\(Salesforce.isConnected) aircall=\(Aircall.canPlaceCalls)"
  137      }
  138  
  139      func openStream(_ speaker: Speaker, key: String) -> DeepgramStream {
  140          final class Ref: @unchecked Sendable { weak var stream: DeepgramStream? }
  141          let ref = Ref()
  142          let stream = DeepgramStream(apiKey: key, keyterms: useKeyterms ? DeepgramStream.defaultKeyterms : []) { [weak self] event in
  143              // When the words were spoken, on the wall clock both sides share (not when the text arrived).
  144              var spoken: (start: Date, end: Date)?
  145              if case .transcript(_, _, _, let start, let duration, _) = event, start > 0 || duration > 0,
  146                 let s = ref.stream?.wallTime(audioSeconds: start) {
  147                  spoken = (s, s.addingTimeInterval(duration))
  148              }
  149              Task { @MainActor in self?.handle(event, from: speaker, spoken: spoken) }
  150          }
  151          ref.stream = stream
  152          return stream
  153      }
  154  
  155      func handle(_ event: DeepgramStream.Event, from speaker: Speaker, spoken: (start: Date, end: Date)? = nil) {
  156          guard status == .live else { return }
  157          switch event {
  158          case .transcript(let text, let isFinal, let speechFinal, let audioStart, let audioDuration, let confidence):
  159              if !text.isEmpty {
  160                  CallTrace.event(isFinal ? "transcript.final" : "transcript.partial", [
  161                      "speaker": speaker == .rep ? "rep" : "prospect", "text": text, "speech_final": speechFinal,
  162                      "audio_start": audioStart, "audio_end": audioStart + audioDuration, "confidence": confidence])
  163              }
  164              if speechFinal { CallTrace.event("turn.end", ["speaker": speaker == .rep ? "rep" : "prospect", "by": "speech_final"]) }
  165              if speaker == .prospect {
  166                  // Check the recent words together, so a phrase split across chunks still matches.
  167                  let recent = String(((turns.last { $0.speaker == .prospect }?.text ?? "") + " " + text).suffix(400))
  168                  let early = repWordsInCall < 3 && Date().timeIntervalSince(firstProspectAt ?? Date()) < 15
  169                  let firstWords = turns.contains { $0.speaker == .rep } ? "" : (prospectSoFar + " " + text)
  170                  if BadNumber.detects(recent) {
  171                      if !badNumberThisCall { markBadNumber() }
  172                  } else if phoneTreeActive {
  173                      // In a phone menu: no voicemail card, no auto hang-up. Only a real mailbox ends it.
  174                      if Voicemail.recordingPrompt(recent) {
  175                          phoneTreeActive = false
  176                          phoneTreeTask?.cancel()
  177                          showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
  178                      }
  179                  } else if !badNumberThisCall, !phoneTreeThisCall, repWordsInCall < 5,
  180                            !Voicemail.recordingPrompt(recent), PhoneTree.detects(prospectSoFar + " " + text) {
  181                      // Work through it by default. Old behavior (disqualify + hang up) behind a setting.
  182                      if Prefs.hangUpPhoneTrees { markPhoneTree() } else { enterPhoneTree() }
  183                  } else if !voicemailActive, screenerActive || stagesSeen.contains("Screener") || Screener.detects(prospectSoFar),
  184                            Voicemail.unavailableAfterScreen(recent) || Voicemail.numberCantTakeCall(recent) {
  185                      // The call screener says they won't take it: same as no answer. Hang up (redial on the
  186                      // 1st try, next person on a no-voicemail day). A voicemail day's last try waits for the beep.
  187                      ActivityLog.add("Screener said not available for \(calling ?? "?")")
  188                      showVoicemail(mailboxFull: false)
  189                      autoHangUpForRedial(why: "screener said not available")
  190                  } else if Voicemail.detects(recent, earlyInCall: early)
  191                      || (!screenerActive && !Screener.detects(firstWords) && Voicemail.longGreeting(firstWords, earlyInCall: early)) {
  192                      if !voicemailActive || (Voicemail.mailboxFull(recent) && !mailboxFullShown) {
  193                          showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
  194                      }
  195                      // Surely a recording, and the rep hasn't started talking: hang up now, before the beep
  196                      // (redial on the 1st try; on to the next person on a no-voicemail day's last try).
  197                      if repWordsInCall < 3, !screenerActive, !autoHungUpThisCall,
  198                         let why = Voicemail.hangUpReason(recent, firstWords: firstWords, earlyInCall: early) {
  199                          autoHangUpForRedial(why: why)
  200                      }
  201                  } else if !voicemailActive, !screenerActive, !stagesSeen.contains("Screener"), Screener.detects(recent) {
  202                      showScreenerLine()
  203                  }
  204              }
  205              if !text.isEmpty {
  206                  let wasSpeaking = speaker == .rep ? repSpeaking : prospectSpeaking
  207                  if !wasSpeaking {
  208                      ActivityLog.add("Speech start (\(speaker == .rep ? "Rep" : "Them"), transcript arrival)")
  209                      CallTrace.event("speech.start", ["speaker": speaker == .rep ? "rep" : "prospect",
  210                                                       "overlap": speaker == .rep ? prospectSpeaking : repSpeaking])
  211                  }
  212                  if speaker == .rep { lastRepSpeechAt = Date(); repEndpointed = false } else { lastProspectSpeechAt = Date() }
  213                  // Audio timeline: classify the turn from when words were spoken. No timestamps (rare):
  214                  // fall back to arrival time, a short range ending now.
  215                  let side: SpeechTimeline.Side = speaker == .rep ? .rep : .prospect
  216                  let end = spoken?.end ?? Date()
  217                  let start = spoken?.start ?? end.addingTimeInterval(-0.3)
  218                  if let kind = timeline.update(side, start: start.timeIntervalSinceReferenceDate, end: end.timeIntervalSinceReferenceDate,
  219                                                text: text, isFinal: isFinal) {
  220                      CallTrace.event("turn.classified", ["speaker": side.rawValue, "kind": kind.rawValue, "text": text,
  221                                                          "spoken_start_ms": Int(start.timeIntervalSince1970 * 1000),
  222                                                          "spoken_end_ms": Int(end.timeIntervalSince1970 * 1000),
  223                                                          "lag_ms": Int(Date().timeIntervalSince(end) * 1000),
  224                                                          "timestamps": spoken == nil ? "arrival (fallback)" : "audio",
  225                                                          "final": isFinal])
  226                  }
  227              }
  228              if isFinal {
  229                  reconnects = 0
  230                  interim[speaker] = nil
  231                  if !text.isEmpty { addFinal(text, from: speaker) }
  232                  // Opt-out on any prospect final, even one that doesn't end their turn (C7).
  233                  // Clear opt-out phrases on any final, checked on the whole turn so far, not one chunk (round 3).
  234                  // addFinal already added this chunk to uncoached: check it as is (Fix 4).
  235                  if speaker == .prospect, !doNotCall, LiveCoach.isOptOut(uncoached, isFinal: false) { handleOptOut(uncoached) }
  236                  if speaker == .prospect { followsThisStretch = 0; yesShowTask?.cancel() } // new prospect words: the waiting yes line is stale
  237                  // A possible opt-out in a mid-turn final: hold it now, so a hang-up before the turn ends can't lose it.
  238                  if speaker == .prospect, !speechFinal, !doNotCall, pendingAmbiguousOptOut == nil,
  239                     OptOut.hasAmbiguous(uncoached), OptOut.matches(uncoached, isFinal: true) {
  240                      pendingAmbiguousOptOut = uncoached.trimmingCharacters(in: .whitespaces)
  241                      uncoached = ""
  242                      CallTrace.event("optout.waiting", ["said": pendingAmbiguousOptOut ?? "", "why": "possible opt-out in a mid-turn final"])
  243                      armPendingOptOutTimer()
  244                  }
  245                  if speechFinal && speaker == .prospect { prospectFinished() }
  246                  if !speechFinal && speaker == .prospect { scheduleEarlyStart() } // a final mid-turn is a head start too (M2)
  247                  if speechFinal && speaker == .rep { repEndpointed = true; followPausedUntilQuiet = false; promotePendingIfReady() } // the transcriber heard them stop (M1)
  248              } else {
  249                  interim[speaker] = text
  250                  if speaker == .prospect, !text.isEmpty { yesShowTask?.cancel(); openerWaitTask?.cancel() } // they kept talking
  251                  if speaker == .prospect { scheduleEarlyStart() }
  252              }
  253          case .utteranceEnd:
  254              CallTrace.event("turn.end", ["speaker": speaker == .rep ? "rep" : "prospect", "by": "utterance_end"])
  255              if speaker == .prospect {
  256                  // The full pause after "don't call me back": now decide if it was an opt-out or a callback request.
  257                  if let said = pendingAmbiguousOptOut, !uncoached.trimmingCharacters(in: .whitespaces).isEmpty {
  258                      // Only once they've said more: a bare pause is left to the timer (it may still be "...until Tuesday").
  259                      pendingAmbiguousOptOut = nil
  260                      pendingOptOutTask?.cancel()
  261                      let later = uncoached.trimmingCharacters(in: .whitespaces)
  262                      let whole = (said + " " + later).trimmingCharacters(in: .whitespaces)
  263                      if PendingOptOut.resolve(pending: said, later: later, utteranceEnded: true, callEnded: false, secondsWaited: 0) == .optOut {
  264                          if !doNotCall { handleOptOut(whole) }
  265                      } else { uncoached = whole; CallTrace.event("optout.not", ["said": whole, "why": "a later time followed: a callback request"]) }
  266                  }
  267                  if !doNotCall { prospectFinished() }
  268              }
  269              if speaker == .rep { repEndpointed = true; promotePendingIfReady() } // M1: no wait for the next tick
  270          case .failed(let message):
  271              // Keep the call and the last tip; just reconnect this side.
  272              guard reconnects < 3, let key = Keychain.read(.deepgram) else {
  273                  problem = "Transcription stopped: \(message)"
  274                  return
  275              }
  276              reconnects += 1
  277              useKeyterms = false // reconnect with the plainest settings
  278              streams.replace(speaker, with: openStream(speaker, key: key))
  279          }
  280      }
  281  
  282      /// The rep clicked "Voicemail": the app missed it, so show the message now.
  283      func markVoicemail() {
  284          guard status == .live, !voicemailActive else { return }
  285          showVoicemail(mailboxFull: false)
  286      }
  287  
  288      func addFinal(_ text: String, from speaker: Speaker) {
  289          lastWordsAt = Date()
  290          defer { scheduleStillWithMe() }
  291          defer { if speaker == .rep { prepareWhileRepTalks(text); prepareYesBranch(text) } } // runs after the turn is recorded
  292          if speaker == .rep {
  293              let count = text.split(separator: " ").count
  294              repWordsSinceShown += count
  295              repWordsInCall += count
  296              lastRepFinal = text
  297              lastRepFinalAt = Date()
  298              recentRepChunks = Array((recentRepChunks + [text]).suffix(2))
  299          }
  300          if speaker == .prospect, firstProspectAt == nil { firstProspectAt = Date() }
  301          ActivityLog.add("Heard \(speaker == .rep ? "Rep" : "Them") (final): \(text)")
  302          if speaker == .rep, pending != nil, text.contains("?") { repAskedSinceQueue = true }
  303          if speaker == .rep, text.contains("?") || QueuedLine.repPivoted(text) { lastRepQuestionAt = Date() }
  304          if speaker == .rep { repTextSinceAsk += " " + text }
  305          if speaker == .rep, status == .live, !suggestion.say.isEmpty {
  306              repSaidSinceShown += " " + text
  307              if !lineDelivered, Delivery.delivered(line: suggestion.say, spoken: repSaidSinceShown) {
  308                  lineDelivered = true
  309                  if testLineCounted { callLinesUsed += 1 }
  310                  let conf = Delivery.confidence(line: suggestion.say, spoken: repSaidSinceShown)
  311                  ActivityLog.add(String(format: "Coach: line delivered (meaning %.0f%% said)", conf * 100))
  312                  let ev = Delivery.evidence(line: suggestion.say, spoken: repSaidSinceShown)
  313                  CoachPrompt.saidLines.append(suggestion.say)
  314                  if !suggestion.stage.isEmpty { CoachPrompt.lastSaidStage = suggestion.stage }
  315                  CallTrace.event("delivery", ["line": suggestion.say, "said": repSaidSinceShown, "confidence": conf,
  316                                               "rule": Delivery.rule(line: suggestion.say, spoken: repSaidSinceShown) ?? "none",
  317                                               "matched_words": ev.matched, "missing_words": ev.missing,
  318                                               "how": "overall: half the line's key words said; question: 60% of its question's key words"], sug: shownID)
  319              }
  320          }
  321          // Resolved only by a real answer: "Why?" or "What do you mean?" after the line isn't one (N1).
  322          if speaker == .prospect, lineDelivered, !answeredAfterDelivery, AnswerEvidence.isAnswer(text) {
  323              answeredAfterDelivery = true
  324              ActivityLog.add("Coach: they answered the delivered line (resolved)")
  325              CallTrace.event("resolution", ["answer": text, "how": "prospect spoke after the line was delivered"], sug: shownID)
  326          }
  327          if speaker == .prospect { lastHeardThemAt = Date(); confirmGoalIfAgreed(text) }
  328          if turns.last?.speaker != speaker { CallTrace.turn += 1 }
  329          // Cut off = this side really came in over the other in audio time (not just answered quickly).
  330          let kindNow = timeline.segments[speaker == .rep ? .rep : .prospect]?.last?.kind
  331          let overlapped = kindNow == .interruption || kindNow == .overlap
  332          for change in questionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, overlapped: overlapped) {
  333              switch change {
  334              case .asked(let q): CallTrace.event("question.asked", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
  335              case .answered(let q): CallTrace.event("question.answered", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "answer": q.answer])
  336              case .interrupted(let q): CallTrace.event("question.interrupted", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "cut_off_by": text])
  337              case .abandoned(let q): CallTrace.event("question.abandoned", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
  338              case .uncertain(let q): CallTrace.event("question.uncertain", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "reply": q.answer,
  339                                                                             "reply_kind": AnswerEvidence.kind(q.answer).rawValue])
  340              }
  341          }
  342          CoachPrompt.questionFacts = questionTracker.promptText // current before the next prompt is built
  343          CoachPrompt.answeredQuestions = questionTracker.doNotRepeat // answered, or deflected and declined
  344          for c in objectionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, turn: CallTrace.turn) {
  345              let o = c.objection
  346              CallTrace.event("objection.\(o.status.rawValue)", [
  347                  "id": o.id, "kind": o.kind, "from": c.from?.rawValue ?? "none", "to": o.status.rawValue, "why": c.why,
  348                  "raised": ["turn": o.raisedTurn, "text": o.raisedText],
  349                  "addressed": ["turn": o.addressedTurn, "text": o.addressedText],
  350                  "evidence": ["turn": o.evidenceTurn, "text": o.evidenceText]])
  351              ActivityLog.add("Objection \(o.kind): \(c.from?.rawValue ?? "new") -> \(o.status.rawValue)")
  352          }
  353          CoachPrompt.objectionFacts = objectionTracker.promptText
  354          // The call record hears it too (tagged by rules: a phone menu is not a person).
  355          if var a = attempt {
  356              if speaker == .prospect {
  357                  a.prospect(text, tag: PhoneTree.detects(text) ? .menu : .speech) // rules only (the model's HUMAN guess isn't used)
  358              } else {
  359                  a.rep(text)
  360              }
  361              attempt = a
  362              if a.heard.count + a.repSaid.count <= 3 || speaker == .prospect { CallAttemptStore.shared.upsert(a) } // saved, in case the app quits
  363          }
  364          if let last = turns.last, last.speaker == speaker {
  365              turns[turns.count - 1].text += " " + text
  366          } else {
  367              turns.append(Turn(speaker: speaker, text: text))
  368          }
  369          if speaker == .prospect {
  370              uncoached += (uncoached.isEmpty ? "" : " ") + text
  371          }
  372      }
  373  }
  374  
```


## `mac/Sources/ClarityLiveCoach/CoachModel+Call.swift`

```swift
    1  import AppKit
    2  import CoachCore
    3  import AVFoundation
    4  import Combine
    5  import CoreAudio
    6  import Foundation
    7  
    8  /// A call from start to end: the tick, starting and ending calls, auto redial and auto next.
    9  extension CoachModel {
   10      /// Whoever is up has a phone number outside the US and Canada: skip them, whatever loaded them.
   11      /// Checked every half second, so no path (first lead, Back, reload, auto next) can miss it.
   12      private func skipForeignLead() {
   13          MobileOnly.campaignID = campaign.id
   14          callList.pin(object: campaign.listObject, view: campaign.listViewID) // only the menu's list
   15          if leads.isActive, let d = leads.details { MobileOnly.record(d.id, mobile: d.mobile) }
   16          // Mobile numbers only: no Mobile on file, skip them for this call list.
   17          if MobileOnly.on, status == .ready, !dialing, let key = recordKey(), MobileOnly.excluded(key), mobileSkippedID != key {
   18              mobileSkippedID = key
   19              ActivityLog.add("\(calling ?? key) has no Mobile (Mobile numbers only is on): skipping")
   20              problem = "No Mobile number. Skipped (Mobile numbers only)."
   21              skipNext(why: "no Mobile number (Mobile numbers only is on)")
   22              return
   23          }
   24          // The Chrome list: someone off the list (non-US number, removed) is on screen: move on.
   25          if !leads.isActive, status == .ready, !dialing, let key = recordKey(), RemovedList.contains(key),
   26             foreignSkippedID != key {
   27              foreignSkippedID = key
   28              ActivityLog.add("\(calling ?? key) is off the list (non-US number or removed): skipping")
   29              problem = "Off your list. Skipped, on to the next person."
   30              skipNext(why: "off the list")
   31              return
   32          }
   33          guard status == .ready, !dialing, leads.isActive, let d = leads.details, !d.doNotCall,
   34                let n = d.foreignNumber, foreignSkippedID != d.id else { return }
   35          foreignSkippedID = d.id // once per person, so Back can still show them
   36          ActivityLog.add("\(d.name) isn't a US or Canada number (\(n)): skipping and removing from the list")
   37          RemovedList.add(d.id)
   38          problem = "Not a US or Canada number. Skipped, on to the next person."
   39          skipNext(why: "not a US or Canada number")
   40      }
   41  
   42      func tick() {
   43          guard active else { return }
   44          if !attemptsReconciled {
   45              attemptsReconciled = true
   46              for a in CallAttemptStore.shared.orphans() {
   47                  ActivityLog.add("Call record recovered after the app quit: \(a.outcome?.rawValue ?? "?") (\(a.classificationSource))")
   48                  applyOutcome(a, live: false)
   49              }
   50          }
   51          checkBlock()
   52          // Midnight: yesterday's "called today" clears, so people due today come back on the list.
   53          let day = Calendar.current.component(.day, from: Date())
   54          if day != lastTickDay {
   55              if lastTickDay != 0 {
   56                  callList.resetCalledIfNewDay()
   57                  callList.refreshUpNext()
   58                  leads.resetIfNewDay()
   59                  ActivityLog.add("New day: called-today list cleared")
   60              }
   61              lastTickDay = day
   62          }
   63          skipForeignLead()
   64          promotePendingIfReady()
   65          if status == .live {
   66              let next = CoachMachine.state(signals())
   67              if next != coachState {
   68                  ActivityLog.add("Coach state: \(coachState.rawValue) -> \(next.rawValue)")
   69                  CallTrace.event("state", ["from": coachState.rawValue, "to": next.rawValue, "signals": signals().trace])
   70                  coachState = next
   71              }
   72          } else if coachState != .idle { coachState = .idle }
   73          if phase != loggedPhase {
   74              ActivityLog.add("Phase: \(loggedPhase.rawValue) -> \(phase.rawValue)")
   75              loggedPhase = phase
   76          }
   77          let onCall = AudioProcess.anyCallApp(in: AudioProcess.others())
   78          // Between calls, notice which record is open so the opener uses their name.
   79          // Dialed from the app: start listening once the Aircall app picks up the call (or after 8 s).
   80          if let since = pendingDialSince, status == .ready {
   81              // Start listening almost right away, so a "straight to voicemail" greeting is heard from word one.
   82              if AudioProcess.aircallAppOnCall(in: AudioProcess.others()) || Date().timeIntervalSince(since) > 1 {
   83                  pendingDialSince = nil
   84                  waitingForNewCall = false
   85                  startCall()
   86              }
   87              return
   88          }
   89          if status == .ready, !leads.isActive, !onCall || waitingForNewCall {
   90              tabTicks += 1
   91              if tabTicks % 2 == 0 {
   92                  callList.captureIfListView()
   93                  if openingID == nil { callList.refreshUpNext() }
   94                  syncRecord()
   95              }
   96          }
   97          // In-app phone, call placed on the phone itself (not the Dial button): its red hang-up
   98          // button showing is the sign of a real call. Its open mic alone never is.
   99          if status == .ready, AircallPhone.isOn, pendingDialSince == nil { checkPhoneForNewCall() }
  100          switch status {
  101          case .ready where onCall:
  102              if waitingForNewCall || AircallPhone.isOn {
  103                  // In-app phone: its own mic is held open all session, so sound alone never means a call.
  104                  // Calls start from Dial, or when Aircall itself shows a new call.
  105                  waitingForNewCall = true
  106                  // Chrome is still holding the last call's mic/speaker: start only when Aircall shows a new call.
  107                  checkAircallForNewCall()
  108              } else {
  109                  startCall()
  110              }
  111          case .ready:
  112              waitingForNewCall = false // Chrome let go, so the next time it grabs the mic is a new call
  113          case .live:
  114              if onCall {
  115                  heardCallAudio = true
  116                  // Chrome's Aircall: call audio means the call was placed. (The in-app phone holds its mic open, so not there.)
  117                  if !AircallPhone.isOn { markPlaced("call audio") }
  118              }
  119              // Safety net: nobody has said a word for 90 s = the call is over (no real call is that quiet).
  120              let silentFor = Date().timeIntervalSince(lastWordsAt ?? callStartedAt)
  121              if silentFor > 90, !startedByHand {
  122                  ActivityLog.problem("Call ended: 90 s with no words")
  123                  endCall(); return
  124              }
  125              // Only count quiet after the call's audio has shown up once, so a call that's
  126              // still ringing (we start listening right after dialing) isn't ended early.
  127              // In-app phone: its mic is held open all session, so "the call app went quiet" means nothing.
  128              // The phone's hang-up button and Aircall itself say when the call ends.
  129              if !startedByHand, !AircallPhone.isOn, heardCallAudio || Date().timeIntervalSince(callStartedAt) > 45 {
  130                  quietTicks = onCall ? 0 : quietTicks + 1
  131                  if quietTicks >= 6 { endCall(); return } // Chrome let go of the call for 3 seconds
  132              }
  133              // Rang 20 seconds and nobody spoke (no person, no recording): hang up for the rep, so the
  134              // redial or the next person starts by itself.
  135              if autoDial, AircallPhone.isOn, !startedByHand, !autoHungUpThisCall, !autoHangingUp,
  136                 !phoneTreeActive, !phoneTreeThisCall, !sawVoicemail, !screenerActive, !voicemailDropStarted,
  137                 !turns.contains(where: { $0.speaker == .prospect }),
  138                 Date().timeIntervalSince(callStartedAt) > ringLimit {
  139                  hangUpUnanswered()
  140              }
  141              if sawVoicemail || voicemailActive || kind == .voicemail { scheduleVoicemailDrop() } // whichever part spotted it
  142              checkAircallEveryFewSeconds()
  143              if aircallTicks % 2 == 0, Date().timeIntervalSince(callStartedAt) < 30 { followCallAudio() }
  144              if AudioProcess.doubleCall(in: AudioProcess.others()) {
  145                  problem = "Two calls at once: Aircall is signed in here and in Salesforce. Log out of the Aircall panel in Salesforce."
  146              }
  147          default:
  148              break
  149          }
  150      }
  151  
  152      /// The End call button: hangs up the phone for real (Aircall's own button), then resets the app.
  153      func hangUpAndEnd() {
  154          guard status != .ready else { return }
  155          autoHungUpThisCall = true
  156          // Reset right now, don't wait for Aircall: the hang-up click happens in the background.
  157          if AircallPhone.isOn { Task { _ = await AircallPhone.shared.hangUp() } }
  158          endCall()
  159      }
  160  
  161      /// How long to let it ring: 20 s only on the first dial when "Call twice" is on (a redial follows).
  162      /// Any other dial rings until their voicemail answers, so the drop can wait for the end of the greeting.
  163      var ringLimit: TimeInterval {
  164          currentAttempts < maxAttempts ? 20 : .infinity
  165      }
  166  
  167      /// 20 seconds of ringing and nobody spoke: hang up, then the normal flow (redial, or the next person).
  168      func hangUpUnanswered() {
  169          autoHungUpThisCall = true
  170          ActivityLog.add("Rang 20 s with no answer for \(calling ?? "?"): hanging up")
  171          Task { [weak self] in
  172              guard let self, self.status == .live else { return }
  173              let done = await AircallPhone.shared.hangUp()
  174              guard done else { ActivityLog.problem("Ringing hang-up: couldn't find Aircall's hang-up button"); return }
  175              for _ in 0..<4 {
  176                  try? await Task.sleep(for: .seconds(1))
  177                  if await Aircall.lineIsOnCall() == false { break }
  178              }
  179              if self.status == .live { self.endCall() }
  180          }
  181      }
  182  
  183      /// A short note at the top that fades by itself.
  184      func showToast(_ text: String) {
  185          toast = text
  186          toastTask?.cancel()
  187          toastTask = Task { [weak self] in
  188              try? await Task.sleep(for: .seconds(5))
  189              if !Task.isCancelled { self?.toast = nil }
  190          }
  191      }
  192  
  193      /// The rep clicked End call (or Aircall/Chrome says it's over): reset for the next call.
  194      func endCall() {
  195          guard status != .ready else { return }
  196          callEndedAt = Date() // the real hang-up time (not when the app finishes resetting)
  197          SpaceKey.callLive = false
  198          // A possible opt-out still waiting when the call ends is an opt-out: write it now, for this lead (Fix 1b).
  199          if let p = pendingAmbiguousOptOut, !doNotCall {
  200              pendingAmbiguousOptOut = nil
  201              pendingOptOutTask?.cancel()
  202              // Include words still in progress ("...until Tuesday" not final yet when they hung up).
  203              let later = (uncoached + " " + (interim[.prospect] ?? "")).trimmingCharacters(in: .whitespaces)
  204              if PendingOptOut.resolve(pending: p, later: later, utteranceEnded: false, callEnded: true, secondsWaited: 0) == .optOut {
  205                  CallTrace.event("optout.flushed", ["said": p, "why": "the call ended before the full pause"])
  206                  handleOptOut((p + " " + later).trimmingCharacters(in: .whitespaces))
  207              }
  208          }
  209          CallTrace.endCall(["lead": calling ?? "?", "seconds": Int(Date().timeIntervalSince(callStartedAt)),
  210                             "voicemail": sawVoicemail, "they_spoke": turns.contains { $0.speaker == .prospect },
  211                             "turns": turns.count, "last_line": suggestion.say])
  212          let hadVoicemail = sawVoicemail // for the log
  213          if hadVoicemail, !(currentAttempts < maxAttempts && autoDial), !autoHungUpThisCall, repWordsInCall >= 8,
  214             let key = currentAttemptKey,
  215             Cadence.leavesVoicemail(for: key),
  216             let said = voicemailScript?.say, voicemailFor == calling {
  217              DialHistory.logVoicemail(key, body: said)
  218          }
  219          // Didn't connect: over in under 12 seconds, nobody talked, no voicemail. That's a bad
  220          // number's beeping tone or a dropped call, not a person who didn't pick up (that rings 20+ s).
  221          let quickFail = !badNumberThisCall && !startedByHand && !sawVoicemail
  222              && Date().timeIntervalSince(callStartedAt) < 12
  223              && !turns.contains { $0.speaker == .prospect }
  224          ActivityLog.add("Call ended: \(calling ?? "?") after \(Int(Date().timeIntervalSince(callStartedAt))) s. voicemail=\(sawVoicemail) theySpoke=\(turns.contains(where: { $0.speaker == .prospect })) bad=\(badNumberThisCall)")
  225          if !turns.isEmpty {
  226              let words = turns.map { "\($0.speaker == .rep ? "Rep" : "Them"): \($0.text)" }.joined(separator: " | ")
  227              ActivityLog.add("Transcript: \(words.prefix(6000))")
  228          }
  229          if quickFail { attempt?.badNumberDetected() }
  230          if quickFail, let key = currentAttemptKey {
  231              outcomeSaved.insert(String(key.prefix(15))) // nothing to rate
  232              let fails = DialHistory.logFailedConnect(key)
  233              if fails >= 2 { markNotQualityProspect(key, reason: "didn't connect twice") }
  234              nextCall()
  235              waitingForNewCall = true
  236              endedAt = Date()
  237              followUp = nil
  238              lastCallAnswered = true // no redial
  239              problem = fails >= 2 ? "Didn't connect again. Bad number: taken off your list." : "Didn't connect (bad number or network). Moving on."
  240              afterHangUp { [weak self] in self?.startNextSequence() }
  241              return
  242          }
  243          if badNumberThisCall {
  244              // Number doesn't work: no voicemail, no text, no redial. Off the list, on to the next.
  245              badNumberThisCall = false
  246              if let key = currentAttemptKey { outcomeSaved.insert(String(key.prefix(15))) }
  247              nextCall()
  248              waitingForNewCall = true
  249              endedAt = Date()
  250              followUp = nil
  251              lastCallAnswered = true
  252              problem = phoneTreeThisCall ? "Phone tree. Disqualified and taken off your list." : "Bad number. Taken off your list."
  253              afterHangUp { [weak self] in self?.startNextSequence() }
  254              return
  255          }
  256          // 2nd try went to voicemail: they've had both calls. Move on by itself.
  257          let moveOn = sawVoicemail && currentAttempts >= maxAttempts
  258          nextCall()
  259          waitingForNewCall = true
  260          endedAt = Date()
  261          // Didn't reach them (no answer or voicemail): the text and LinkedIn card shows after
  262          // every such call, even when the voicemail greeting wasn't caught.
  263          if !lastCallAnswered, followUp == nil || followUp?.key != currentAttemptKey {
  264              startFollowUp()
  265              ActivityLog.add("Follow-up card for \(calling ?? "?") (voicemail heard: \(hadVoicemail))")
  266          }
  267          if let key = currentAttemptKey, RemovedList.contains(key) {
  268              // Marked Unqualified (or Not Quality Prospect / Negative) during the call: no text, no redial.
  269              ActivityLog.add("Call ended for someone taken off the list: on to the next person")
  270              followUp = nil
  271              waitingForText = false
  272              afterHangUp { [weak self] in self?.startNextSequence() }
  273          } else if shouldOfferRedial, autoDial {
  274              // 1st try, no answer: "Calling Jane Doe again in 3", then redial the same person.
  275              startAutoRedial()
  276          } else if !shouldOfferRedial, !lastCallAnswered, let f = followUp {
  277              // Done with them for now (both dials): send the text, then the next call starts.
  278              // No wait when no text can go out: none due today, already sent, a phone tree, or no
  279              // Mobile (landline only). An empty phone box always means no Mobile, so the text is skipped.
  280              let noMobile = f.noMobile || f.phone.trimmingCharacters(in: .whitespaces).isEmpty
  281              if f.textDue, !f.textDone, noMobile {
  282                  followUp?.noMobile = true
  283                  applyPlan() // hides the text and says why
  284                  ActivityLog.add("No Mobile for \(calling ?? "?"): text skipped, on to the next person")
  285              }
  286              if f.textDone || !f.textDue || noMobile || phoneTreeThisCall {
  287                  afterHangUp { [weak self] in self?.startNextSequence() }
  288              } else if autoDial, Aircall.isSetUp, Prefs.autoText, !f.text.isEmpty {
  289                  // The text goes out in the background while the next person loads. No waiting.
  290                  sendTextInBackground(f)
  291                  afterHangUp { [weak self] in self?.startNextSequence() }
  292              } else {
  293                  waitingForText = true
  294                  startTextCountdown() // waits for its words, then sends by itself in 5 seconds (or the rep sends it)
  295              }
  296          } else if lastCallAnswered, autoDial, currentAttemptKey != nil {
  297              // A real talk just ended: Claude fills "How did it go?" from the transcript (you can change it),
  298              // then 10 seconds, then the next person. Wait stops it.
  299              autoOutcome()
  300              afterHangUp { [weak self] in self?.startMoveOn(after: 10) }
  301          } else if moveOn {
  302              afterHangUp { [weak self] in self?.startNextSequence() }
  303          }
  304      }
  305  
  306      /// Reached a recording (100% sure: words only a machine says) and auto-dial is on:
  307      /// - 1st try: hang up, then redial in 1 s.
  308      /// - Last try on a no-voicemail day: hang up, then on to the next person (after the text, if one is due).
  309      /// Clicks Aircall's hang-up button and waits until Aircall says the line is free.
  310      /// If anything is off (no button, line still busy), it does nothing and the rep hangs up as usual.
  311      func autoHangUpForRedial(why: String = "beep words") {
  312          guard autoDial, AircallPhone.isOn, !autoHangingUp, !autoHungUpThisCall, !voicemailDropStarted, // the drop is playing
  313                !phoneTreeActive, !phoneTreeThisCall, // never hang up on a phone menu
  314                let key = currentAttemptKey, !RemovedList.contains(key) else { return }
  315          let redialNext = currentAttempts < maxAttempts && !DialHistory.isMaxed(key)
  316          let noVoicemailToday = !Cadence.leavesVoicemail(for: key)
  317          guard redialNext || noVoicemailToday else { return } // a voicemail day's last try: leave the message
  318          autoHangingUp = true
  319          autoHungUpThisCall = true
  320          ActivityLog.add(redialNext ? "Recording for sure (\(why)) on the 1st try for \(calling ?? "?"): hanging up to redial"
  321                                     : "Recording (\(why)) on the last try, no voicemail today, for \(calling ?? "?"): hanging up, on to the next person")
  322          Task { [weak self] in
  323              guard let self, self.status == .live else { self?.autoHangingUp = false; return }
  324              var done = await AircallPhone.shared.hangUp()
  325              if done {
  326                  // Only end the call on our side once Aircall says the line is free (up to 5 s).
  327                  done = false
  328                  for _ in 0..<5 {
  329                      try? await Task.sleep(for: .seconds(1))
  330                      if await Aircall.lineIsOnCall() == false { done = true; break }
  331                  }
  332              }
  333              self.autoHangingUp = false
  334              guard self.status == .live else { return }
  335              if done {
  336                  self.redialRightAway = redialNext
  337                  self.endCall() // last try: endCall moves on to the next person
  338              } else {
  339                  ActivityLog.problem("Auto hang-up didn't finish: the rep hangs up, redial as usual")
  340              }
  341          }
  342      }
  343  
  344      /// Counts down 3 seconds (1 after an automatic hang-up), then calls the same person again. Wait stops it.
  345      func startAutoRedial() {
  346          autoNextTask?.cancel()
  347          autoNextName = Screener.fullName(calling).map { "\($0) again" }
  348          let countdown = redialRightAway ? 1 : 3
  349          redialRightAway = false
  350          autoNextTask = Task { [weak self] in
  351              for left in stride(from: countdown, through: 1, by: -1) {
  352                  self?.autoNextIn = left
  353                  try? await Task.sleep(for: .seconds(1))
  354                  guard let self, !Task.isCancelled else { return }
  355                  if self.status != .ready { self.cancelAutoNext(); return }
  356              }
  357              guard let self, !Task.isCancelled, self.shouldOfferRedial else { return }
  358              self.autoNextIn = nil
  359              self.redial()
  360          }
  361      }
  362  
  363      /// Counts down 5 seconds, then loads the next lead (and calls them, if "Next calls right away" is on).
  364      func startAutoNext(seconds: Int = 1) {
  365          guard nextLeadName != nil else { return }
  366          autoNextTask?.cancel()
  367          autoNextTask = Task { [weak self] in
  368              for left in stride(from: seconds, through: 1, by: -1) {
  369                  self?.autoNextIn = left
  370                  try? await Task.sleep(for: .seconds(1))
  371                  guard let self, !Task.isCancelled else { return }
  372                  // A call started some other way: stop counting.
  373                  if self.status != .ready { self.cancelAutoNext(); return }
  374              }
  375              guard let self, !Task.isCancelled else { return }
  376              self.nextLead()
  377          }
  378      }
  379  
  380      /// Counts down, then moves to the next person (and calls them). Used after a real talk and
  381      /// after "How did it go?" is saved. Wait stops it.
  382      /// Reads the call and picks "How did it go?" (Interested, Not now, Not a fit, or nothing if unclear).
  383      /// Saves after 4 s unless the rep picked one first. Uses Haiku: fast and cheap.
  384      func autoOutcome() {
  385          guard let key = currentAttemptKey, turns.contains(where: { $0.speaker == .prospect }) else { return }
  386          let object = key.hasPrefix("003") ? "Contact" : "Lead"
  387          let options = Outcomes.quick(object)
  388          let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Them"): \($0.text)" }.joined(separator: "\n")
  389          let who = calling
  390          Task { [weak self] in
  391              let system = """
  392              You read a finished cold call and pick how it went. Options: \(options.map(\.label).joined(separator: ", ")), or None.
  393              Interested: they agreed to a meeting or asked to hear more. Not now: bad timing, call back later, send an email.
  394              Not a fit: the right person said they're clearly not interested, wrong company, or no need. None: only a front desk, a hang-up, a wrong number or someone else answered, or too short to tell.
  395              If Not a fit, also pick the closest reason from: \(Salesforce.unqualifiedReasons.joined(separator: ", ")), or "".
  396              Return only JSON: {"outcome": "", "reason": "", "why": "one short sentence"}
  397              """
  398              guard let json = try? await CallLab.ask(system: system, user: transcript, effort: "low", model: "claude-haiku-5-5"),
  399                    let label = json["outcome"] as? String, let pick = options.first(where: { $0.label == label }) else {
  400                  ActivityLog.add("How did it go: left for you (Claude wasn't sure for \(who ?? "?"))")
  401                  return
  402              }
  403              let reason = (json["reason"] as? String).flatMap { Salesforce.unqualifiedReasons.contains($0) ? $0 : nil }
  404              guard let self else { return }
  405              ActivityLog.add("How did it go: Claude picked \(pick.label) for \(who ?? "?") (\((json["why"] as? String) ?? ""))")
  406              self.showToast("How did it go: \(pick.label). Saving in 4 s, click another to change.")
  407              try? await Task.sleep(for: .seconds(4))
  408              guard !self.outcomeSaved.contains(String(key.prefix(15))), self.statusRecordID?.prefix(15) == key.prefix(15), !self.savingStatus else { return }
  409              if pick.value == "Unqualified", object == "Lead", reason == nil { // Salesforce needs a reason
  410                  ActivityLog.add("How did it go: Not a fit needs a reason, left for you")
  411                  return
  412              }
  413              self.saveStatus(pick.value, unqualifiedReason: reason)
  414          }
  415      }
  416  
  417      func startMoveOn(after seconds: Int) {
  418          guard status == .ready else { return }
  419          autoNextTask?.cancel()
  420          autoNextName = nextLeadName
  421          autoNextTask = Task { [weak self] in
  422              for left in stride(from: seconds, through: 1, by: -1) {
  423                  self?.autoNextIn = left
  424                  try? await Task.sleep(for: .seconds(1))
  425                  guard let self, !Task.isCancelled else { return }
  426                  if self.status != .ready { self.cancelAutoNext(); return }
  427              }
  428              guard let self, !Task.isCancelled else { return }
  429              self.autoNextIn = nil
  430              self.startNextSequence()
  431          }
  432      }
  433  
  434      /// Sends the text from a copy of the card, 3 seconds from now, while the next person loads. The
  435      /// card can change meanwhile. A failure shows a note and never holds up the dialing.
  436      func sendTextInBackground(_ f: FollowUp) {
  437          bgTextTask?.cancel()
  438          bgTextTask = Task { [weak self] in
  439              try? await Task.sleep(for: .seconds(3))
  440              guard let self, !Task.isCancelled else { return }
  441              ActivityLog.add("Text: sending in the background for \(f.prospect ?? "?")")
  442              self.sendText(f, background: true)
  443          }
  444      }
  445  
  446      /// A text is due: wait for its words, count down 5 seconds, then send it. Editing the text,
  447      /// Edit or Skip stops the countdown (the rep then sends it by hand).
  448      func startTextCountdown() {
  449          textTask?.cancel()
  450          guard autoDial, Aircall.isSetUp else { return }
  451          textTask = Task { [weak self] in
  452              var waited = 0
  453              while let self, !Task.isCancelled, self.waitingForText, self.followUp?.text.isEmpty ?? true, waited < 20 {
  454                  try? await Task.sleep(for: .milliseconds(500))
  455                  waited += 1
  456              }
  457              for left in stride(from: 5, through: 1, by: -1) {
  458                  guard let self, !Task.isCancelled, self.waitingForText, self.status == .ready,
  459                        self.followUp?.textEdited != true else { self?.textSendIn = nil; return }
  460                  self.textSendIn = left
  461                  try? await Task.sleep(for: .seconds(1))
  462              }
  463              guard let self, !Task.isCancelled, self.waitingForText, self.status == .ready,
  464                    self.followUp?.textEdited != true else { self?.textSendIn = nil; return }
  465              self.textSendIn = nil
  466              ActivityLog.add("Text: sending by itself after the countdown")
  467              self.sendFollowUpText()
  468              // Failsafe: if nothing was sent (no text written, or it couldn't go), move on after 20 s.
  469              try? await Task.sleep(for: .seconds(20))
  470              guard !Task.isCancelled, self.waitingForText, self.status == .ready else { return }
  471              ActivityLog.problem("Text: nothing went out for \(self.followUp?.prospect ?? "?") after 25 s, moving on to the next person")
  472              self.waitingForText = false
  473              self.startNextSequence()
  474          }
  475      }
  476  
  477      func stopTextCountdown() {
  478          textTask?.cancel()
  479          textTask = nil
  480          textSendIn = nil
  481      }
  482  
  483      /// The rep clicked Wait (or moved on by hand).
  484      func cancelAutoNext() {
  485          stopTextCountdown()
  486          hangUpGen += 1
  487          waitingForText = false
  488          autoNextName = nil
  489          readyTask?.cancel()
  490          gettingReady = nil
  491          gettingReadyDetail = nil
  492          autoNextTask?.cancel()
  493          autoNextTask = nil
  494          autoNextIn = nil
  495      }
  496  
  497      func checkAircallForNewCall() {
  498          aircallTicks += 1
  499          guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
  500          aircallCheck = Task { [weak self] in
  501              let since = self?.endedAt ?? Date()
  502              let onCall = await Aircall.lineIsOnCall(since: since)
  503              guard let self else { return }
  504              self.aircallCheck = nil
  505              if onCall == true, self.status == .ready, self.waitingForNewCall {
  506                  self.waitingForNewCall = false
  507                  self.startCall()
  508              }
  509          }
  510      }
  511  
  512      /// Between calls: the hang-up button seen on 2 checks in a row (and not just the last call's
  513      /// button fading out) = a call started on the phone. Start listening.
  514      func checkPhoneForNewCall() {
  515          guard phoneButtonCheck == nil, Date().timeIntervalSince(endedAt) > 3 else { return }
  516          phoneButtonCheck = Task { [weak self] in
  517              let visible = await AircallPhone.shared.hangUpButtonVisible()
  518              guard let self else { return }
  519              self.phoneButtonCheck = nil
  520              guard self.status == .ready, self.pendingDialSince == nil else { return }
  521              self.phoneCallSeen = visible == true ? self.phoneCallSeen + 1 : 0
  522              if self.phoneCallSeen >= 2 {
  523                  self.phoneCallSeen = 0
  524                  self.waitingForNewCall = false
  525                  ActivityLog.add("Call placed on the phone itself: listening")
  526                  self.startCall()
  527              }
  528          }
  529      }
  530  
  531      /// A second, faster signal: the phone's red hang-up button disappears the moment the call ends.
  532      /// Only trusted after it has been seen once in this call, and gone for 3 checks in a row (about 1.5 s).
  533      func checkPhoneButton() {
  534          guard AircallPhone.isOn, phoneButtonCheck == nil else { return }
  535          phoneButtonCheck = Task { [weak self] in
  536              let visible = await AircallPhone.shared.hangUpButtonVisible()
  537              guard let self else { return }
  538              self.phoneButtonCheck = nil
  539              guard self.status == .live, let visible else { return }
  540              if visible { self.phoneSawHangUp = true; self.phoneButtonGone = 0; return }
  541              guard self.phoneSawHangUp else { return }
  542              self.phoneButtonGone += 1
  543              if self.phoneButtonGone >= 3 {
  544                  ActivityLog.add("The phone's hang-up button is gone: the call is over")
  545                  self.endCall()
  546              }
  547          }
  548      }
  549  
  550      func checkAircallEveryFewSeconds() {
  551          checkPhoneButton()
  552          aircallTicks += 1
  553          guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
  554          // Give Aircall a moment to register a brand-new call before trusting a "no".
  555          guard Date().timeIntervalSince(callStartedAt) > 5 else { return }
  556          aircallCheck = Task { [weak self] in
  557              let onCall = await Aircall.lineIsOnCall()
  558              guard let self else { return }
  559              self.aircallCheck = nil
  560              guard self.status == .live, let onCall else { return }
  561              if onCall { self.aircallSawCall = true; self.markPlaced("Aircall shows the call") }
  562              // Trust Aircall's "no call" once it has listed this call, or after 20 s if it never
  563              // lists it (some setups don't). But never while people are still talking.
  564              let age = Date().timeIntervalSince(self.callStartedAt)
  565              let talking = self.lastWordsAt.map { Date().timeIntervalSince($0) < 8 } ?? false
  566              guard self.aircallSawCall || age > 20, !talking else { self.aircallSaysOver = 0; return }
  567              self.aircallSaysOver = onCall ? 0 : self.aircallSaysOver + 1
  568              if self.aircallSaysOver >= 2 {
  569                  ActivityLog.add("Aircall says the call is over")
  570                  self.endCall()
  571              }
  572          }
  573      }
  574  
  575      func startByHand() {
  576          waitingForNewCall = false
  577          startedByHand = true
  578          startCall()
  579      }
  580  
  581      // MARK: Block timer: 50 minutes of calling, then a 10 minute break
  582  
  583      /// The sprint's length, picked on the Call Sprint card (20, 30 or 50 minutes).
  584      static var blockLength: TimeInterval {
  585          let m = UserDefaults.standard.integer(forKey: "sprintMinutes")
  586          return TimeInterval((m > 0 ? m : 20) * 60)
  587      }
  588      /// The sprint starts by itself on the first dial unless the rep ended one by hand.
  589      static var sprintArmed: Bool {
  590          get { UserDefaults.standard.object(forKey: "sprintArmed") as? Bool ?? true }
  591          set { UserDefaults.standard.set(newValue, forKey: "sprintArmed") }
  592      }
  593  
  594      /// A dial started: begins the sprint if one is waiting for its first dial.
  595      func sprintSawDial() {
  596          guard blockStartedAt == nil, !sprintDone else { return }
  597          startBlock()
  598      }
  599  
  600      /// Sprint Complete → New Sprint: back to the setup, waiting for the next first dial.
  601      func newSprint() {
  602          blockStartedAt = nil
  603          sprintDone = false
  604          breakUntil = nil
  605      }
  606      static let breakLength: TimeInterval = 10 * 60
  607  
  608      func startBlock() {
  609          Self.sprintArmed = true
  610          blockStartedAt = Date()
  611          breakUntil = nil
  612          BlockLog.add(blockStartedAt!)
  613          ActivityLog.add("Sprint started on the first dial")
  614      }
  615  
  616      func stopBlock() {
  617          Self.sprintArmed = false // ended by hand: don't restart on the next dial
  618          if breakUntil != nil { autoDial = autoDialBeforeBreak }
  619          blockStartedAt = nil
  620          breakUntil = nil
  621      }
  622  
  623      /// The block ran out (and no call is on): break time. The break ran out: back to calling.
  624      func checkBlock() {
  625          if let until = breakUntil {
  626              if Date() >= until { endBreak() }
  627              return
  628          }
  629          // Time's up: mark it complete. Never touches a call or auto dial; the rep keeps calling.
  630          guard let start = blockStartedAt, !sprintDone,
  631                Date().timeIntervalSince(start) >= Self.blockLength else { return }
  632          sprintDone = true
  633          NSSound(named: "Glass")?.play()
  634          ActivityLog.add("Sprint complete")
  635      }
  636  
  637      /// Skip break, or the break is over: auto dial back on, new block, next call.
  638      func endBreak() {
  639          autoDial = autoDialBeforeBreak
  640          breakUntil = nil
  641          blockStartedAt = Date()
  642          BlockLog.add(blockStartedAt!)
  643          ActivityLog.add("Block: break over, calling again")
  644          if autoDial { startNextSequence() }
  645      }
  646  
  647      /// Skip to the next person, but never run away: 3 skips in a row with no call stops auto dial
  648      /// and says why, instead of flipping through the list opening and closing pages.
  649      func skipNext(why: String) {
  650          skipsInARow += 1
  651          if skipsInARow >= 3 {
  652              ActivityLog.problem("Skipped \(skipsInARow) people in a row (last: \(why)). Auto dial stopped so the app doesn't flip through your list.")
  653              problem = "Skipped \(skipsInARow) people in a row: \(why). Auto dial stopped. Check the call list settings, then press Next."
  654              Prefs.autoDial = false
  655              skipsInARow = 0
  656              return
  657          }
  658          nextLead(dial: Prefs.autoDial)
  659      }
  660  
  661      func startCall() {
  662          skipsInARow = 0
  663          problem = nil
  664          redialRightAway = false
  665          autoHungUpThisCall = false
  666          phoneTreeThisCall = false
  667          phoneTreeActive = false
  668          phoneTreeTask?.cancel()
  669          keysMessage = nil
  670          guard startAudio() else { return }
  671          if !leads.isActive { callList.markCurrentCalled() } // so Next skips them today (Chrome list)
  672          if let key = recordKey() {
  673              currentAttemptKey = key
  674              attempts[key, default: 0] += 1
  675          }
  676          // The dial is counted when the call ends, and only if the phone confirmed it was placed.
  677          attempt = CallAttempt(leadID: currentAttemptKey, campaign: touchpoints.currentCampaign)
  678          callEndedAt = nil
  679          if AudioProcess.aircallAppOnCall(in: AudioProcess.others()) || !Aircall.isSetUp { markPlaced(Aircall.isSetUp ? "Aircall app on a call" : "no Aircall check available") }
  680          if let a = attempt { CallAttemptStore.shared.upsert(a) }
  681          callMessage = nil
  682          pendingDialSince = nil // this dial is now the live call
  683          BeepDetector.shared.reset()
  684          CallTrace.beginCall(lead: calling, attempt: currentAttempts)
  685          questionTracker = QuestionTracker()
  686          objectionTracker = ObjectionTracker()
  687          CoachPrompt.objectionFacts = ""
  688          CoachPrompt.shownLines = []
  689          CoachPrompt.saidLines = []
  690          CoachPrompt.likelyCoveredLines = []
  691          recentRepChunks = []
  692          CoachPrompt.lastSaidStage = ""
  693          repEndpointed = false
  694          lastEarlyBasis = nil
  695          earlyDraftsThisTurn = 0
  696          repWordsAtLastAsk = 0
  697          repLedIDs = []
  698          yesBranch = nil
  699          yesBranchTask?.cancel()
  700          loggedSystemHash = ""
  701          logSystemIfChanged() // the full static instructions + script Claude gets this call
  702          phoneSawHangUp = false
  703          holdLine = false
  704          pending = nil
  705          phoneButtonGone = 0
  706          CoachPrompt.liveSummary = ""
  707          CoachPrompt.summaryCoversTurns = 0
  708          summaryInFlight = false // a summary left from the last call never blocks this one
  709          screenerRetries = 0
  710          prospectNos = 0
  711          callClosed = false
  712          callLinesShown = 0
  713          callLinesUsed = 0
  714          prospectTurnsAfterFirstNo = 0
  715          closedOnSecondNo = false
  716          followsThisStretch = 0
  717          frozenShownID = -1
  718          installSpaceKey()
  719          SpaceKey.onFresh = { [weak self] in self?.freshLine() }
  720          SpaceKey.install()
  721          SpaceKey.callLive = true // Space in Chrome = fresh line, during this call only
  722          CoachPrompt.questionFacts = "" // never carry the last call's questions into this one
  723          CoachPrompt.answeredQuestions = []
  724          CoachPrompt.recentText = ""
  725          doNotCall = false
  726          timeline = SpeechTimeline()
  727          CoachPrompt.blockerHints = BlockerBook.hints(campaign.id)
  728          ActivityLog.add("Call started: \(calling ?? "?") (try \(currentAttempts))")
  729          // Haiku vs Sonnet test: each call alternates; the redial of the same person keeps the same model.
  730          if currentAttempts <= 1 { LiveCoach.callModel = LiveCoach.pickModelForNextCall() }
  731          CallTrace.event("ab.model", ["live_model": LiveCoach.callModel, "why": "calls alternate Haiku and Sonnet to compare them"])
  732          ActivityLog.add("Models this call: live lines \(ClaudeClient.displayName(LiveCoach.client("").model)), "
  733              + "opener \(ClaudeClient.displayName(CoachSpeed.current.client(apiKey: "").model)) (speed: \(CoachSpeed.current.label)), "
  734              + "voicemail \(ClaudeClient.displayName(CoachSpeed.fastest.client(apiKey: "").model)), "
  735              + "fixes in code, then one retry on the live model")
  736          attempt?.liveModel = LiveCoach.callModel
  737          // Calling someone new: the last person's follow-up card goes away.
  738          if let f = followUp, f.key != nil, f.key != currentAttemptKey { followUp = nil }
  739          status = .live
  740          streak = Date().timeIntervalSince(lastDialAt) < 180 ? streak + 1 : 1
  741          lastDialAt = Date()
  742          voicemailDropStarted = false
  743          dropWhyLogged = false
  744          if let key = currentAttemptKey { outcomeSaved.remove(String(key.prefix(15))) } // a new call: rate it again
  745          prewarmNext() // get the next person ready while this call rings
  746          quietTicks = 0
  747          availability.refresh() // fresh free times for this call
  748          callOpener = kind == .opener ? openerStyle : nil
  749          goalHit = false
  750          goalPending = false
  751          meetingThisWeek = nil
  752          sawVoicemail = false
  753          stagesSeen = []
  754          callStartedAt = Date()
  755          heardCallAudio = false
  756          retargets = 0
  757          aircallSaysOver = 0
  758          aircallSawCall = false
  759          aircallTicks = 0
  760          journeyStep = 0
  761          history = Array(history.suffix(1)) // keep the opener as the first line
  762          historyIndex = nil
  763          repWordsInCall = 0
  764          repWordsSinceShown = 0
  765          offeredTimes = []
  766          codeByDate = [:]
  767          nextOffer = []
  768          screenerActive = false
  769          openerBeforeScreener = nil
  770          voicemailActive = false
  771          badNumberThisCall = false
  772          mailboxFullShown = false
  773          followUpThisCall = false
  774          cancelAutoNext()
  775          if voicemailScript == nil { prepareVoicemail() }
  776          firstProspectAt = nil
  777          lastWordsAt = nil
  778      }
  779  
  780      /// Stages that only happen with the actual prospect, not a front desk or assistant.
  781      static let prospectStages: Set<String> = ["Discovery", "Value", "Objection", "Closing", "Goal reached"]
  782  
  783      /// The phone confirmed the call was placed: it counts as a dial.
  784      func markPlaced(_ why: String) {
  785          guard var a = attempt, a.placedAt == nil, !a.finalized else { return }
  786          a.placed()
  787          attempt = a
  788          CallAttemptStore.shared.upsert(a)
  789          CallTrace.event("call.placed", ["why": why])
  790      }
  791  
  792      /// Decides how the call ended (once), saves it, and counts it. Returns: a real person answered.
  793      @discardableResult
  794      func finalizeAttempt() -> Bool {
  795          guard var a = attempt else { return false }
  796          attempt = nil
  797          // finalize() only works once: a second call (any path) counts nothing again.
  798          guard a.finalize(endedAt: callEndedAt ?? Date()) else { return a.outcome?.humanAnswered ?? false }
  799          callEndedAt = nil
  800          CallAttemptStore.shared.upsert(a)
  801          CallTrace.event("call.outcome", ["outcome": a.outcome?.rawValue ?? "?", "why": a.classificationSource,
  802                                           "placed": a.placedAt != nil, "conversation": a.conversation,
  803                                           "model_stages": a.modelStages, "live_model": a.liveModel ?? ""])
  804          ActivityLog.add("Call outcome for \(calling ?? a.leadID ?? "?"): \(a.outcome?.rawValue ?? "?") (\(a.classificationSource))")
  805          applyOutcome(a, live: true)
  806          return a.outcome?.humanAnswered ?? false
  807      }
  808  
  809      /// Counts one finished call everywhere from its record: My numbers, the call plan, Salesforce.
  810      func applyOutcome(_ a: CallAttempt, live: Bool) {
  811          PickedUpSync.flush() // anything still waiting from an earlier call
  812          guard let o = a.outcome, a.placedAt != nil else { return } // never placed: not a dial
  813          touchpoints.log(.dial, at: a.startedAt, campaign: a.campaign, lead: a.leadID)
  814          if let key = a.leadID { DialHistory.logDial(key) }
  815          if o == .voicemail, !(a.leadID.map { CallAttemptStore.shared.voicemailCountedToday(lead: $0, except: a.attemptID) } ?? false) {
  816              touchpoints.log(.voicemail, at: a.startedAt, campaign: a.campaign, lead: a.leadID)
  817          }
  818          guard o.humanAnswered else { return }
  819          touchpoints.log(.pickup, at: a.startedAt, campaign: a.campaign, lead: a.leadID)
  820          if live { NSSound(named: "Tink")?.play() } // a soft sound: someone picked up
  821          if a.conversation { touchpoints.log(.conversation, at: a.startedAt, campaign: a.campaign, lead: a.leadID) }
  822          if live, goalHit { touchpoints.log(.meeting) }
  823          // A gatekeeper (or wrong number) answered: they stay on the plan, no checkbox.
  824          guard o.prospectReached, let key = a.leadID else {
  825              if o == .humanGatekeeper { ActivityLog.add("Gatekeeper only for \(a.leadID ?? "?") (\(a.classificationSource)): stays on the plan") }
  826              return
  827          }
  828          DialHistory.logPickup(key) // the prospect picked up: the call plan stops for them
  829          // A real conversation with the prospect: check "Picked Up Cold Call" in Salesforce (same rule as before).
  830          guard a.conversation else {
  831              ActivityLog.add("Short pickup for \(key): Picked Up Cold Call not checked")
  832              return
  833          }
  834          PickedUpSync.mark(key)
  835      }
  836  
  837      /// Clears everything about this prospect and gets the next opener ready.
  838      func nextCall() {
  839          SpaceKey.callLive = false // Space is normal again everywhere
  840          yesShowTask?.cancel()
  841          openerWaitTask?.cancel()
  842          testLineCounted = false
  843          followPausedUntilQuiet = false
  844          // The call is over: the next person starts clean, before their opener is prepared below (round 3).
  845          doNotCall = false
  846          pendingAmbiguousOptOut = nil
  847          pendingOptOutTask?.cancel()
  848          if status != .ready {
  849              // Reached a person = they spoke, and it wasn't a voicemail or only a screener.
  850              lastCallAnswered = finalizeAttempt()
  851          }
  852          history = []
  853          historyIndex = nil
  854          journeyStep = 0
  855          scoreOpener()
  856          stopAudio()
  857          coachTask?.cancel()
  858          holdTask?.cancel()
  859          startedByHand = false
  860          turns = []
  861          interim = [:]
  862          uncoached = ""
  863          latestProspect = ""
  864          latency = nil
  865          status = .ready
  866          if leads.isActive {
  867              applyLead()
  868          } else {
  869              // The call is over: the voicemail (or any mid-call line) goes away and a fresh
  870              // "when they pick up" opener shows right away, ready for the redial.
  871              prepareOpener()
  872              // Read Chrome a moment later, not while Aircall plays the hang-up tone.
  873              afterHangUp { [weak self] in self?.syncRecord() } // same person: keep their ready voicemail
  874          }
  875      }
  876  
  877      /// Runs work 2 seconds after a call ends. Doing it all at the hang-up moment
  878      /// (Chrome reads, saving, loading the next person) makes Aircall's hang-up tone skip.
  879      func afterHangUp(_ work: @escaping () -> Void) {
  880          let gen = hangUpGen
  881          Task { [weak self] in
  882              try? await Task.sleep(for: .seconds(1))
  883              // Skip it if the rep already moved on by hand (Next, Redial, Call).
  884              guard let self, self.status == .ready, self.hangUpGen == gen else { return }
  885              work()
  886          }
  887      }
  888  
  889      /// Scores the call if a real person answered (not voicemail): credits the opener,
  890      /// then saves it to the Script Lab.
  891      func scoreOpener() {
  892          defer { callOpener = nil }
  893          let prospectTurns = turns.filter { $0.speaker == .prospect }.count
  894          // Skip voicemails, no-answers, and calls where only a screener ever talked.
  895          guard status != .ready, !sawVoicemail, !screenerActive, prospectTurns > 0, let start = firstProspectAt else { return }
  896          let talk = max(0, (lastWordsAt ?? start).timeIntervalSince(start))
  897          let score = CallScore.compute(talkSeconds: talk, stages: stagesSeen, goal: goalHit)
  898          let usedOpener = callOpener.flatMap { $0 == openers.current ? $0 : nil }
  899          if usedOpener != nil {
  900              openers.record(score: score, kept: prospectTurns >= 3, goal: goalHit)
  901          }
  902          if let key = currentAttemptKey { DialHistory.logTalked(key) }
  903          let record = CallRecord(
  904              campaignID: campaign.id, campaignVersion: campaign.version, openerID: usedOpener?.id,
  905              talkSeconds: talk, prospectTurns: prospectTurns, stages: Array(stagesSeen).sorted(),
  906              goal: goalHit, score: score, liveModel: LiveCoach.callModel,
  907              linesShown: callLinesShown, linesUsed: callLinesUsed,
  908              hadNo: prospectNos > 0, pastFirstNo: prospectNos > 0 && prospectTurnsAfterFirstNo >= 2 && !closedOnSecondNo
  909          )
  910          let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
  911          lab.add(record, campaign: campaign, transcript: transcript, person: calling)
  912          ActivityLog.add(lab.modelComparison())
  913      }
  914  
  915      func togglePause() {
  916          if status == .paused {
  917              if startAudio() { status = .live }
  918          } else if status == .live {
  919              stopAudio()
  920              coachTask?.cancel()
  921              status = .paused
  922          }
  923      }
  924  }
  925  
```


## `mac/Sources/ClarityLiveCoach/CoachModel+Script.swift`

```swift
    1  import AppKit
    2  import AVFoundation
    3  import Combine
    4  import CoreAudio
    5  import Foundation
    6  
    7  /// Lines taken straight from the campaign script: opener, texts, LinkedIn notes, voicemails.
    8  extension CoachModel {
    9      func instantOpener(for calling: String?) -> Suggestion {
   10          // Rotation off: the campaign script's own opener, never a built-in one.
   11          // (Claude's version, fitted to them, replaces it a moment later.)
   12          if openerStyle == nil {
   13              if let line = scriptOpenerLine() {
   14                  return Suggestion(say: fillBlanks(fillTags(line, for: calling), for: calling),
   15                                    cue: "Your script's opener", stage: "Opener", sayComplete: true)
   16              }
   17              return Suggestion(say: "Reading your script's opener...", cue: "Your script's opener", stage: "Opener", sayComplete: false)
   18          }
   19          var t = openerStyle?.template ?? Opener.all[0].template
   20          if t.contains("[a ") { t = Opener.all[0].template } // needs Claude to fill in; use the plain one
   21          let rep = Prefs.repName
   22          t = t.replacingOccurrences(of: "[first name]", with: Screener.firstName(calling) ?? "there")
   23              .replacingOccurrences(of: "[rep]", with: rep.isEmpty ? "[your name]" : rep)
   24              .replacingOccurrences(of: "[company]", with: shortCompany)
   25              .replacingOccurrences(of: " [industry] teams", with: " teams") // Claude's version names their industry
   26          return Suggestion(say: t, cue: openerStyle?.name ?? "Opener", stage: "Opener", sayComplete: true)
   27      }
   28  
   29      /// The script's first line for when they pick up: what Claude found reading the whole script,
   30      /// else the first quoted line of the campaign's Opening. Raw (blanks and placeholders as written).
   31      func scriptOpenerLine() -> String? {
   32          let found = ScriptTemplates.shared.templates(for: campaignText) { [weak self] in self?.scriptRead() }
   33          if let line = found?.opener { return line }
   34          let opening = campaign.opening.trimmingCharacters(in: .whitespacesAndNewlines)
   35          guard !opening.isEmpty else { return nil }
   36          for (open, close) in [("\"", "\""), ("“", "”")] {
   37              if let a = opening.range(of: open), let b = opening.range(of: close, range: a.upperBound..<opening.endIndex) {
   38                  return String(opening[a.upperBound..<b.lowerBound])
   39              }
   40          }
   41          return opening
   42      }
   43  
   44      /// "Is this ___?" → "Is this Adam?": a blank right after words that ask for the person.
   45      func fillBlanks(_ text: String, for calling: String?) -> String {
   46          guard let first = Screener.firstName(calling) else { return text }
   47          var t = text
   48          for lead in ["is this", "am i speaking with", "speaking with", "is that", "calling for", "looking for", "hi", "hey", "hello"] {
   49              t = t.replacingOccurrences(of: #"(?i)\b(\#(lead))\s+_{2,}"#, with: "$1 \(first)", options: .regularExpression)
   50          }
   51          return t
   52      }
   53  
   54      /// The script was just read by Claude: refresh the card's templates and the opener on screen.
   55      func scriptRead() {
   56          refillFromScript()
   57          if var v = voicemailScript, voicemailFor == calling {
   58              applyScriptVoicemail(&v, for: calling)
   59              voicemailScript = v
   60          }
   61          if status == .ready, openerStyle == nil { prepareOpener() }
   62      }
   63  
   64      /// Fills {first name}, {rep}, {company} and their [bracket] versions (any capitalization).
   65      func fillTags(_ text: String, for calling: String?) -> String {
   66          var t = text
   67          let rep = Prefs.repName
   68          let first = Screener.firstName(calling) ?? "there"
   69          let tags: [(names: [String], value: String)] = [
   70              (["first name", "firstname", "first", "name", "prospect", "prospect name"], first),
   71              (["rep", "rep name", "your name", "my name", "rep first name", "sdr", "sdr name", "caller", "caller name"],
   72               rep.isEmpty ? "[your name]" : rep),
   73              (["company", "your company", "rep company"], shortCompany),
   74          ]
   75          // Their company, when Salesforce has it: [Firm], [Their company], [Account].
   76          if let theirs = (leads.isActive ? leads.details?.company : recordCompany)?.trimmingCharacters(in: .whitespaces), !theirs.isEmpty {
   77              for n in ["firm", "their company", "account", "account name"] {
   78                  for (o, c) in [("{", "}"), ("[", "]")] {
   79                      t = t.replacingOccurrences(of: o + n + c, with: theirs, options: .caseInsensitive)
   80                  }
   81              }
   82          }
   83          for (names, value) in tags {
   84              for n in names {
   85                  for (o, c) in [("{", "}"), ("[", "]")] {
   86                      t = t.replacingOccurrences(of: o + n + c, with: value, options: .caseInsensitive)
   87                  }
   88              }
   89          }
   90          return t
   91      }
   92  
   93      /// A message the campaign script spells out, found by its label (like "Missed call text:").
   94      /// The label must start the line (after any bullet). Takes the words after it on the same line, or the lines under it up to the next
   95      /// blank line or heading. Quotes around it are dropped. nil if the script has no such label.
   96      func scriptPiece(_ labels: [String]) -> String? {
   97          let lines = campaignText.components(separatedBy: "\n")
   98          for label in labels {
   99              for (i, line) in lines.enumerated() {
  100                  // Only a label at the start of a line (after bullets, numbers or "#"), not the
  101                  // same words in the middle of a sentence.
  102                  let head = String(line.drop { " \t#*-•–0123456789.)".contains($0) })
  103                  // Little words don't matter: "Text after a missed call" matches "text after missed call".
  104                  guard Self.plain(head).hasPrefix(Self.plain(label)) else { continue }
  105                  // "Label: message" or "Label - message" or "Label “message”" = the message is on this line.
  106                  // Anything else after the label ("(under 200 characters)", "/connection request") is
  107                  // part of the heading, and the message is on the lines under it.
  108                  var rest = ""
  109                  if let colon = head.firstIndex(of: ":") {
  110                      rest = String(head[head.index(after: colon)...])
  111                  } else if let q = head.firstIndex(where: { "\"“".contains($0) }) {
  112                      rest = String(head[q...])
  113                  } else if let dash = head.range(of: " - ") ?? head.range(of: " – ") ?? head.range(of: " — ") {
  114                      rest = String(head[dash.upperBound...])
  115                  }
  116                  var body = rest.trimmingCharacters(in: .whitespaces)
  117                  if body.isEmpty {
  118                      var under: [String] = []
  119                      for next in lines[(i + 1)...] {
  120                          let t = next.trimmingCharacters(in: .whitespaces)
  121                          if t.isEmpty { if under.isEmpty { continue } else { break } }
  122                          if t.hasPrefix("#") || (t.hasSuffix(":") && t.count < 40) { break }
  123                          // The next label starts: stop.
  124                          let next = t.drop { " \t#*-•–0123456789.)".contains($0) }.lowercased()
  125                          if ["linkedin", "missed call", "voicemail", "sms", "email", "text message", "follow-up", "follow up"]
  126                              .contains(where: { next.hasPrefix($0) }) { break }
  127                          under.append(t)
  128                      }
  129                      body = under.joined(separator: " ")
  130                  }
  131                  body = ScriptTemplates.cleanTemplate(body)
  132                  if body.count >= 15 { return String(body.prefix(1000)) }
  133              }
  134          }
  135          return nil
  136      }
  137  
  138      /// Lowercase, no "a", "an" or "the", single spaces, straight apostrophes: for matching labels.
  139      static func plain(_ text: String) -> String {
  140          text.lowercased().replacingOccurrences(of: "’", with: "'")
  141              .split(whereSeparator: { $0 == " " || $0 == "\t" })
  142              .filter { !["a", "an", "the"].contains($0) }
  143              .joined(separator: " ")
  144      }
  145  
  146      /// The campaign's own missed call text and LinkedIn notes win over anything written for them.
  147      /// The script's text is used for the first text to this person; later texts are written fresh
  148      /// in the same voice. The LinkedIn note and message fall back to the missed call text.
  149      func applyScriptMessages(_ s: inout Suggestion, for calling: String?) {
  150          // Best: Claude read the whole script and found the templates (any headings, any layout).
  151          // Until that's done (a few seconds, once per script), a simple label match fills in.
  152          let found = ScriptTemplates.shared.templates(for: campaignText) { [weak self] in self?.scriptRead() }
  153              ?? labeledTemplates()
  154          // Text 1 is the missed call text, text 2 the next template, and so on. Past the last one, Claude writes them.
  155          let sent = recordKey().map { DialHistory.sentTexts($0).count } ?? 0
  156          if sent < found.texts.count { s.textMessage = fillTags(found.texts[sent], for: calling) }
  157          let text = found.texts.first
  158          if let n = found.linkedinNote ?? found.linkedinMessage ?? text { s.linkedin = fillTags(n, for: calling) }
  159          if let m = found.linkedinMessage ?? found.linkedinNote ?? text { s.linkedinMessage = fillTags(m, for: calling) }
  160          // Portland and SW Washington: the lunch invite beats the script's notes. Later texts are Claude's,
  161          // written as lighter nudges about the same lunch.
  162          if isLocalLead {
  163              let first = Screener.firstName(calling) ?? "there"
  164              let rep = Prefs.repName
  165              s.linkedin = LocalLunch.linkedinNote(first: first)
  166              s.linkedinMessage = LocalLunch.linkedinMessage(first: first)
  167              if sent == 0 { s.textMessage = LocalLunch.text(first: first, rep: rep.isEmpty ? "[your name]" : rep, company: shortCompany) }
  168          }
  169      }
  170  
  171      /// In Portland or SW Washington: from the lead's city and state, else the Salesforce page text,
  172      /// else a 503 or 971 phone number.
  173      var isLocalLead: Bool {
  174          if leads.isActive, let d = leads.details {
  175              return LocalLunch.isLocal(city: d.city, state: d.state, phones: [d.mobile, d.phone])
  176          }
  177          return LocalLunch.isLocal(pageText: recordDetails)
  178              || LocalLunch.isLocal(city: nil, state: nil, phones: [followUp?.phone, Aircall.phone(in: recordDetails)])
  179      }
  180  
  181      /// The campaign script's voicemail, word for word with the blanks filled, in place of a written one.
  182      /// 1st voicemail to this person = the script's 1st, and so on. Past the last, Claude's version stays.
  183      func applyScriptVoicemail(_ s: inout Suggestion, for calling: String?) {
  184          guard let found = ScriptTemplates.shared.templates(for: campaignText, onReady: { [weak self] in self?.scriptRead() }),
  185                !found.voicemails.isEmpty else { return }
  186          let left = recordKey().map { DialHistory.person($0).voicemails.count } ?? 0
  187          guard left < found.voicemails.count else { return }
  188          s.say = fillBlanks(fillTags(found.voicemails[left], for: calling), for: calling)
  189          s.cue = "Your script's voicemail. Wait for the beep."
  190      }
  191  
  192      /// The script was just read: put its templates on the open card (anything not sent yet).
  193      func refillFromScript() {
  194          guard var f = followUp else { return }
  195          var s = Suggestion()
  196          applyScriptMessages(&s, for: calling)
  197          if !f.textDone, !f.textEdited, !s.textMessage.isEmpty { f.text = s.textMessage }
  198          if !f.linkedinDone, !s.linkedin.isEmpty { f.linkedin = s.linkedin }
  199          if !f.linkedinMessageDone, !s.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
  200          followUp = f
  201      }
  202  
  203      /// The quick fallback: templates found by their headings.
  204      func labeledTemplates() -> ScriptTemplates.Found {
  205          let text = scriptPiece(["missed call text", "missed-call text", "missed call sms", "missed call message",
  206                                  "text after missed call", "text after voicemail", "text after call", "voicemail text",
  207                                  "text message", "sms", "missed call"])
  208          let second = scriptPiece(["if no reply", "if they don't reply", "if no response", "no reply", "second text",
  209                                    "2nd text", "text 2", "follow-up text", "follow up text"])
  210          let note = scriptPiece(["linkedin connection message", "linkedin connection request", "linkedin connection note",
  211                                  "linkedin connect message", "linkedin connect", "linkedin connection",
  212                                  "connection request", "linkedin note", "linkedin request", "connect note"])
  213          let message = scriptPiece(["linkedin message", "linkedin dm", "linkedin direct message", "linkedin follow"])
  214          let texts = text.map { [$0] + (second.map { [$0] } ?? []) } ?? []
  215          return ScriptTemplates.Found(texts: texts, linkedinNote: note, linkedinMessage: message)
  216      }
  217  }
  218  
```


## `mac/Sources/ClarityLiveCoach/CoachModel+FollowUp.swift`

```swift
    1  import AppKit
    2  import AVFoundation
    3  import Combine
    4  import CoreAudio
    5  import Foundation
    6  
    7  /// Voicemail, the text and LinkedIn card, and the follow-up plan.
    8  extension CoachModel {
    9      /// Brings their LinkedIn (from Salesforce) up in Chrome, no clicks. Closes when the next person opens.
   10      private func showLinkedIn(_ f: FollowUp, key: String) {
   11          guard LinkedInBot.lastTab?.key != key, !linkedInShowing.contains(key) else { return }
   12          linkedInShowing = [key] // once per person on screen, however often their card updates
   13          Task { [weak self] in
   14              var url = f.linkedinURL
   15              if url == nil, Salesforce.isConnected { url = await Salesforce.linkedIn(of: key) }
   16              guard let url, let self, self.isOnScreen(key) else { return }
   17              await LinkedInBot.showProfile(url, key: key)
   18          }
   19      }
   20  
   21      /// The record open right now is this person (and their details are loaded).
   22      func isOnScreen(_ key: String) -> Bool {
   23          guard let now = recordKey() else { return false }
   24          return now.prefix(15) == key.prefix(15)
   25      }
   26  
   27      /// The moment a lead opens (any lead we haven't sent a request to yet): the bot sends the connection
   28      /// note in the background, while the call goes on. Waits up to 8 s for Claude's note, then uses the plain one.
   29      private func autoLinkedInNow() {
   30          guard LinkedInBot.autoSend, let f = followUp, let key = f.key, isOnScreen(key) else { return } // only the person on screen
   31          if linkedInTried.contains(key) { showLinkedIn(f, key: key); return }
   32          // Why not, said once per person in the log, so a skip is never a mystery.
   33          var why: String?
   34          if f.linkedinDone { why = "LinkedIn already marked done for today" }
   35          else if !DialHistory.person(key).linkedIns.isEmpty { why = "a connection request already went out on an earlier day" }
   36          else if RemovedList.contains(key) { why = "they're off the list" }
   37          else if leads.details?.foreignNumber != nil { why = "non-US number (skipped lead)" }
   38          if let why {
   39              if !RemovedList.contains(key), leads.details?.foreignNumber == nil { showLinkedIn(f, key: key) } // already sent: just show it
   40              if !linkedInWhyLogged.contains(key) {
   41                  linkedInWhyLogged.insert(key)
   42                  ActivityLog.add("LinkedIn bot: not running for \(f.prospect ?? "?"): \(why)")
   43              }
   44              return
   45          }
   46          if !f.linkedin.isEmpty { queueLinkedIn(f); return }
   47          guard !linkedInWaitingNote.contains(key) else { return }
   48          linkedInWaitingNote.insert(key)
   49          Task { [weak self] in
   50              try? await Task.sleep(for: .seconds(8))
   51              guard let self, let cur = self.followUp, cur.key == key, !cur.linkedinDone, self.isOnScreen(key) else { return }
   52              self.queueLinkedIn(cur)
   53          }
   54      }
   55  
   56      func followUpChanged() {
   57          LinkedInBot.closeLast(keeping: followUp?.key) // next person or skipped: close the last profile
   58          autoOpenLinkedIn()
   59          autoLinkedInNow()
   60          if waitingForLinkedIn, status == .ready, followUp?.linkedinDone ?? true {
   61              waitingForLinkedIn = false
   62              ActivityLog.add("LinkedIn note done: on to the next person")
   63              Task { @MainActor [weak self] in self?.startNextSequence() } // not inside followUp's didSet
   64          }
   65          if followUp?.textEdited == true, textSendIn != nil { stopTextCountdown() } // the rep is typing
   66          let done = followUp?.textDone == true
   67          defer { textWasDone = done }
   68          guard waitingForText, status == .ready else { return }
   69          // Text just sent, or the card was closed: on to the next person.
   70          if (done && !textWasDone) || followUp == nil {
   71              waitingForText = false
   72              startNextSequence()
   73          }
   74      }
   75  
   76      /// The rep clicked Drop now on the voicemail card.
   77      func dropNow() {
   78          guard voicemailDropStarted, status == .live else { return }
   79          dropNowRequested = true
   80          ActivityLog.add("Voicemail drop: Drop now clicked")
   81      }
   82  
   83      /// Saves this greeting; every 20th one, the app re-tunes the drop timing from all saved greetings.
   84      func saveVoicemailSample(droppedAt: Double?, how: String, transcript: String) {
   85          let total = VoicemailSamples.shared.finish(droppedAt: droppedAt, how: how, transcript: transcript)
   86          guard total > 0, total % 20 == 0 else { return }
   87          Task { [weak self] in
   88              guard let r = await VoicemailTuner.run() else { return }
   89              let line = String(format: "Voicemail timing check (%d greetings): too early %d → %d, average wait after the beep %.1f s → %.1f s. %@",
   90                                r.samples, r.earlyBefore, r.earlyAfter, r.waitBefore, r.waitAfter,
   91                                r.applied ? "New settings: \(r.tuning.summary)" : "Current settings are already best.")
   92              ActivityLog.add(line)
   93              _ = await BugReporter.digest(":telephone_receiver: " + line)
   94              if r.applied { self?.showToast("Voicemail drop timing improved from your last 20 voicemails.") }
   95          }
   96      }
   97  
   98      /// Instant voicemail card: the script written before the call, or "mailbox full, move on".
   99      func showVoicemail(mailboxFull: Bool) {
  100          yesShowTask?.cancel()
  101          if !sawVoicemail { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: PrefKey.voicemailsSeen) + 1, forKey: PrefKey.voicemailsSeen) }
  102          voicemailActive = true
  103          sawVoicemail = true
  104          attempt?.voicemailDetected() // a voicemail rule (or the rep's Voicemail button) fired
  105          screenerActive = false
  106          coachTask?.cancel()
  107          thinking = false
  108          specTimer?.cancel()
  109          holdTask?.cancel()
  110          pending = nil
  111          specBasis = nil
  112          uncoached = ""
  113          seq += 1
  114          startFollowUp()
  115          if mailboxFull {
  116              mailboxFullShown = true
  117              show(Suggestion(say: currentAttempts < maxAttempts ? "Mailbox is full. Hang up and click Redial." : "Mailbox is full. Hang up. The next call starts by itself.",
  118                              cue: "No message possible.",
  119                              stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
  120          } else if let step = currentAttemptKey.flatMap(Cadence.step(for:)), let k = currentAttemptKey, !Cadence.leavesVoicemail(for: k) {
  121              // Not a voicemail day in the 21-day plan.
  122              show(Suggestion(say: currentAttempts < maxAttempts ? "No voicemail today. Hang up. The redial starts by itself."
  123                                                       : "No voicemail today. Hang up and move on.",
  124                              cue: "The plan leaves one voicemail, on day 1. Today is day \(Cadence.callDays[step.index]).",
  125                              stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
  126          } else if var script = voicemailScript, voicemailFor == calling {
  127              if currentAttempts < maxAttempts {
  128                  script.cue = "1st try: hang up and click Redial. Leave this message on the 2nd try."
  129              } else if let step = currentAttemptKey.flatMap(Cadence.step(for:)) {
  130                  script.cue = "Day \(step.planDay) voicemail (the only one in the plan). Wait for the beep."
  131              }
  132              show(script, id: seq, kind: .voicemail)
  133              scheduleVoicemailDrop()
  134          } else {
  135              // Not written yet: ask now. The beep usually gives a few seconds.
  136              show(Suggestion(say: "Writing your voicemail...", cue: "Wait for the beep.", stage: "Voicemail", sayComplete: true),
  137                   id: seq, kind: .voicemail)
  138              ask(.voicemail, user: CoachPrompt.voicemail(calling: calling, details: recordDetails,
  139                                                           earlierTexts: recordKey().map(DialHistory.sentTexts) ?? [],
  140                                                           earlierMessages: recordKey().map(DialHistory.sentLinkedInMessages) ?? [],
  141                                                           history: recordKey().map(DialHistory.historySummary) ?? "",
  142                                                           localLunch: isLocalLead))
  143          }
  144      }
  145  
  146      /// Sets up the follow-up card for this prospect, filled from the pre-written voicemail if ready.
  147      func startFollowUp() {
  148          let name = Screener.fullName(calling)
  149          // A fresh card for every voicemail, so nothing (like an old error) carries over.
  150          // Same person as last time (2nd try): keep what was already sent, so they don't get it twice.
  151          let lead = leads.isActive ? leads.details : nil
  152          let key = recordKey()
  153          let earlier = followUp?.key != nil && followUp?.key == key ? followUp : nil
  154          followUpThisCall = true
  155          followUp = FollowUp(key: key,
  156                              prospect: lead?.name ?? name,
  157                              text: earlier?.text ?? "",
  158                              linkedin: earlier?.linkedin ?? "",
  159                              textDone: earlier?.textDone ?? key.map(DialHistory.textedToday) ?? false,
  160                              linkedinDone: earlier?.linkedinDone ?? key.map(DialHistory.linkedInToday) ?? false,
  161                              phone: lead?.textNumber ?? Aircall.phone(in: recordDetails) ?? (leads.isActive ? nil : SalesforceChrome.mobileNumber()) ?? "",
  162                              linkedinURL: lead?.linkedIn ?? Self.linkedInProfile(details: recordDetails),
  163                              linkedinMessage: earlier?.linkedinMessage ?? "",
  164                              linkedinMessageDone: earlier?.linkedinMessageDone ?? key.map(DialHistory.linkedInMessageToday) ?? false)
  165          if followUp?.textDone == true, earlier == nil { followUp?.textStatus = "Already texted today" }
  166          // Their Mobile, straight from Salesforce, so the text number is always filled in. Only an office
  167          // Phone (no Mobile): no text at all (texts only ever go to mobiles).
  168          if let key {
  169              Task { [weak self] in
  170                  let numbers = await Salesforce.numbers(of: key)
  171                  guard numbers.checked else { return }
  172                  KnownNumbers.set(key, mobile: numbers.mobile, phone: numbers.phone) // calls use these (Mobile first)
  173                  if numbers.mobile == nil, numbers.phone == nil { self?.dropNoNumber(key); return }
  174                  guard let self, self.followUp?.key == key, self.followUp?.textDone != true else { return }
  175                  if let number = numbers.mobile {
  176                      self.followUp?.phone = number
  177                      self.followUp?.noMobile = false
  178                  } else {
  179                      self.followUp?.phone = ""
  180                      self.followUp?.noMobile = true
  181                  }
  182                  self.applyPlan()
  183              }
  184          }
  185          // Not on the page yet: read their LinkedIn field from Salesforce, so the card opens the profile.
  186          if followUp?.linkedinURL == nil, let key {
  187              Task { [weak self] in
  188                  guard let url = await Salesforce.linkedIn(of: key) else { return }
  189                  if self?.followUp?.key == key, self?.followUp?.linkedinURL == nil { self?.followUp?.linkedinURL = url }
  190              }
  191          }
  192          applyPlan()
  193          // The script's own messages show right away, no waiting on Claude.
  194          if var f = followUp {
  195              var s = Suggestion()
  196              applyScriptMessages(&s, for: calling)
  197              if f.text.isEmpty { f.text = s.textMessage }
  198              if f.linkedin.isEmpty { f.linkedin = s.linkedin }
  199              if f.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
  200              followUp = f
  201          }
  202          if let script = voicemailScript, voicemailFor == calling { fillFollowUp(from: script) }
  203          else if detailsTried || leads.isActive, voicemailTask == nil || voicemailFor != calling {
  204              prepareVoicemail() // it fills the card when done (in Chrome mode, only once the page is read)
  205          }
  206          watchFollowUp()
  207      }
  208  
  209      /// The card must never sit on "Writing..." forever (Claude failed, timed out, or answered for
  210      /// someone else). After 12 s with nothing: ask Claude again. After 20 s: fill the empty boxes
  211      /// with the ready-made text and notes (with their name). Claude's version replaces them if it
  212      /// comes in later, as long as nothing was sent yet.
  213      func watchFollowUp() {
  214          followUpWatchdog?.cancel()
  215          let who = calling
  216          let key = followUp?.key
  217          func stillEmpty(_ m: CoachModel) -> Bool {
  218              guard m.calling == who, let f = m.followUp, f.key == key else { return false }
  219              return f.text.isEmpty || f.linkedin.isEmpty || f.linkedinMessage.isEmpty
  220          }
  221          followUpWatchdog = Task { [weak self] in
  222              try? await Task.sleep(for: .seconds(12))
  223              guard let self, !Task.isCancelled, stillEmpty(self) else { return }
  224              if self.voicemailTask == nil, self.voicemailScript == nil, self.status == .ready {
  225                  ActivityLog.problem("Follow-ups still writing for \(who ?? "?") after 12 s: asking Claude again")
  226                  self.prepareVoicemail()
  227              }
  228              try? await Task.sleep(for: .seconds(8))
  229              guard !Task.isCancelled, stillEmpty(self), var f = self.followUp else { return }
  230              let s = self.instantVoicemail(for: who)
  231              if f.text.isEmpty { f.text = s.textMessage }
  232              if f.linkedin.isEmpty { f.linkedin = s.linkedin }
  233              if f.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
  234              self.followUp = f
  235              ActivityLog.problem("Used the ready-made text and LinkedIn notes for \(who ?? "?"). Claude: \(self.lastVoicemailError ?? "no answer in 20 s")")
  236          }
  237      }
  238  
  239      /// Today's checklist for this person, from the 21-day plan: each step and whether it's done.
  240      func todaySteps(for key: String?) -> [(title: String, done: Bool)] {
  241          guard let key else { return [] }
  242          let p = DialHistory.person(key)
  243          guard let step = Cadence.step(for: key), !Cadence.pickedUp(key) else { return [] }
  244          let dialsToday = p.dials.filter { Calendar.current.isDateInToday($0) }.count
  245          var steps: [(String, Bool)] = [("2 dials (\(min(dialsToday, 2)) of 2)", dialsToday >= 2)]
  246          if Cadence.leavesVoicemail(for: key) {
  247              steps.append(("Voicemail on the 2nd dial", p.voicemails.contains { Calendar.current.isDateInToday($0) }))
  248          }
  249          if step.textToday {
  250              let wa = followUp.map { Cadence.isWashington($0.phone) } ?? false
  251              let noMobile = followUp.map { $0.key == key && $0.noMobile } ?? false
  252              if !wa, !noMobile { steps.append(("Text", DialHistory.textedToday(key))) }
  253          }
  254          if step.linkedInConnect {
  255              steps.append(("LinkedIn request", DialHistory.linkedInToday(key)))
  256              steps.append(("LinkedIn message", DialHistory.linkedInMessageToday(key)))
  257          }
  258          return steps
  259      }
  260  
  261      /// Today's 21-day plan step decides which follow-ups show: text only on the 2nd call day
  262      /// (never to Washington numbers), LinkedIn note on the 1st, LinkedIn message on the last.
  263      func applyPlan() {
  264          guard var f = followUp else { return }
  265          guard let key = f.key else {
  266              // Don't know who this is: show nothing rather than risk over-contacting.
  267              f.textDue = false; f.linkedInDue = false; followUp = f; return
  268          }
  269          let step = Cadence.step(for: key)
  270          let washington = Cadence.isWashington(f.phone)
  271          let failedBefore = f.key.map(TextFailed.contains) ?? false
  272          f.textDue = (step?.textToday ?? false) && !washington && !f.noMobile && !failedBefore
  273          if failedBefore, step?.textToday == true, !f.textDone { f.textStatus = "No text: an earlier text to them failed." }
  274          if washington, step?.textToday == true, !f.textDone { f.textStatus = "No text: Washington number (texts need consent there)." }
  275          if f.noMobile, step?.textToday == true, !f.textDone { f.textStatus = "No text: no Mobile in Salesforce (texts only go to mobiles, never office lines)." }
  276          f.linkedInDue = (step?.linkedInConnect ?? false) || (step?.linkedInMessage ?? false)
  277          f.linkedInMessageFirst = step?.linkedInMessage ?? false
  278          followUp = f
  279      }
  280  
  281      /// Fills in the text and LinkedIn note. The rep sends each one with a button.
  282      /// - Parameter replace: a better version (written from their Salesforce page) replaces
  283      ///   anything not sent yet.
  284      func fillFollowUp(from written: Suggestion, replace: Bool = false) {
  285          // Only into the card of the person this voicemail was written for.
  286          guard var f = followUp, f.key == nil || voicemailKey == nil || f.key == voicemailKey else { return }
  287          var s = written
  288          applyScriptMessages(&s, for: calling)
  289          // Claude sometimes copies the script's slots ([SDR], {first name}): fill them.
  290          s.textMessage = fillTags(s.textMessage, for: calling)
  291          s.linkedin = fillTags(s.linkedin, for: calling)
  292          s.linkedinMessage = fillTags(s.linkedinMessage, for: calling)
  293          if (f.text.isEmpty || (replace && !f.textDone && !f.textEdited)), !s.textMessage.isEmpty { f.text = s.textMessage }
  294          if (f.linkedin.isEmpty || (replace && !f.linkedinDone)), !s.linkedin.isEmpty { f.linkedin = s.linkedin }
  295          if (f.linkedinMessage.isEmpty || (replace && !f.linkedinMessageDone)), !s.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
  296          followUp = f
  297      }
  298  
  299      /// Sends the follow-up text through Aircall and checks it off.
  300      func sendFollowUpText() {
  301          guard let f = followUp, !f.text.isEmpty, !f.sending else { return }
  302          sendText(f, background: false)
  303      }
  304  
  305      /// Sends a text from a copy of the card (the card on screen may be someone else's by now).
  306      /// `background`: no one is watching; a problem shows as a short note and never holds up dialing.
  307      func sendText(_ f: FollowUp, background: Bool) {
  308          func note(_ s: String?) {
  309              if followUp?.key == f.key { followUp?.textStatus = s }
  310          }
  311          func problemNote(_ s: String) {
  312              note(s)
  313              if background { showToast("Text to \(Screener.firstName("Lead \"\(f.prospect ?? "")\"") ?? "them") didn't send: \(s)") }
  314          }
  315          // Never send a blank slot like [SDR] or [your name].
  316          if let slot = f.text.range(of: #"\[[^\]]{1,30}\]|\{[^}]{1,30}\}"#, options: .regularExpression) {
  317              problemNote(Prefs.repName.isEmpty
  318                  ? "Add your first name first (Setup > Your first name). Then fix \(f.text[slot]) in the text."
  319                  : "Fill in \(f.text[slot]) in the text first.")
  320              return
  321          }
  322          if let key = f.key, DialHistory.textedToday(key) {
  323              note("Already texted today. Not sent again.")
  324              if followUp?.key == f.key { followUp?.textDone = true }
  325              return
  326          }
  327          if let key = f.key, DialHistory.alreadySent(f.text, to: key) {
  328              problemNote("You already sent them these exact words.")
  329              ActivityLog.add("Text blocked: same words as an earlier text to \(f.prospect ?? "?")")
  330              return
  331          }
  332          note("Sending...")
  333          if followUp?.key == f.key { followUp?.sending = true }
  334          Task { [weak self] in
  335              do {
  336                  try await Aircall.sendText(to: f.phone, body: f.text)
  337                  self?.touchpoints.log(.text)
  338                  if let key = f.key { DialHistory.logText(key, body: f.text) }
  339                  ActivityLog.add("Text sent to \(f.prospect ?? "?") at \(f.phone)")
  340                  if background { self?.showToast("Text sent to \(f.prospect ?? "them")") }
  341                  // Only mark the card it was sent from (not a newer person's card).
  342                  guard self?.followUp?.key == f.key else { return }
  343                  self?.followUp?.textStatus = nil
  344                  self?.followUp?.sending = false
  345                  self?.followUp?.textDone = true
  346              } catch {
  347                  // A failed text is never retried for this person (the number can't take texts, or opted out).
  348                  if let key = f.key { TextFailed.add(key) }
  349                  ActivityLog.problem("Text failed: \(error.localizedDescription). Won't text them again.")
  350                  if background { self?.showToast("Text didn't send: \(error.localizedDescription)") }
  351                  guard self?.followUp?.key == f.key else { return }
  352                  self?.followUp?.textStatus = error.localizedDescription
  353                  self?.followUp?.sending = false
  354              }
  355          }
  356      }
  357  
  358      /// Opens their LinkedIn profile (from the Salesforce record), with the note already copied.
  359      /// Falls back to a name + company search only when the record has no LinkedIn link.
  360      /// - Parameter message: true = copy the direct message (already connected), false = the connection note.
  361      func openLinkedIn(message: Bool = false) {
  362          guard let f = followUp else { return }
  363          NSPasteboard.general.clearContents()
  364          NSPasteboard.general.setString(message ? f.linkedinMessage : f.linkedin, forType: .string)
  365          // The message only gets copied: the profile is already open from the note button.
  366          if message {
  367              if followUp?.linkedinMessageDone != true, !(f.key.map(DialHistory.linkedInMessageToday) ?? false) {
  368                  touchpoints.log(.linkedinMessage)
  369                  if let key = f.key { DialHistory.logLinkedInMessage(key, body: f.linkedinMessage) }
  370              }
  371              followUp?.linkedinMessageDone = true
  372              return
  373          }
  374          openProfile(f)
  375          // Count once per person per day.
  376          if followUp?.linkedinDone != true, !(f.key.map(DialHistory.linkedInToday) ?? false) {
  377              touchpoints.log(.linkedin)
  378              if let key = f.key { DialHistory.logLinkedIn(key) }
  379          }
  380          followUp?.linkedinDone = true
  381      }
  382  
  383      /// The next person just loaded and Salesforce has their LinkedIn link: open the profile in a
  384      /// background Chrome tab, once per person, so it's ready when the rep looks. Never during a call.
  385      private func autoOpenLinkedIn() {
  386          guard Prefs.autoLinkedIn, !LinkedInBot.autoSend, status == .ready, // with auto-send on, the bot opens LinkedIn itself
  387                 let f = followUp, let key = f.key, let url = f.linkedinURL,
  388                linkedInOpenedFor != key else { return }
  389          linkedInOpenedFor = key
  390          SalesforceChrome.openInBackground(url.absoluteString)
  391      }
  392  
  393      /// Automatic mode: notes wait their turn here and go out one at a time while the rep keeps calling.
  394      func queueLinkedIn(_ f: FollowUp) {
  395          guard let key = f.key, !linkedInTried.contains(key) else { return }
  396          // Never for someone being skipped (no Mobile on a Mobile-only list, or off the list).
  397          guard !MobileOnly.excluded(key), !RemovedList.contains(key) else { return }
  398          linkedInTried.insert(key)
  399          linkedInQueue.append(f)
  400          ActivityLog.add("LinkedIn bot: queued \(f.prospect ?? "?") (\(linkedInQueue.count) waiting)")
  401          drainLinkedInQueue()
  402      }
  403  
  404      private func drainLinkedInQueue() {
  405          guard !LinkedInBot.running, !linkedInQueue.isEmpty else { return }
  406          // A human-like 1 to 4 minute gap between requests: wait, then send to whoever is on screen then.
  407          let wait = LinkedInBot.waitLeft
  408          if wait > 0 {
  409              guard !linkedInGapWaiting else { return }
  410              linkedInGapWaiting = true
  411              Task { [weak self] in
  412                  try? await Task.sleep(for: .seconds(wait))
  413                  guard let self else { return }
  414                  self.linkedInGapWaiting = false
  415                  self.linkedInQueue.removeAll { !self.isOnScreen($0.key ?? "") }
  416                  self.drainLinkedInQueue()
  417              }
  418              return
  419          }
  420          let f = linkedInQueue.removeFirst()
  421          runLinkedInBot(f)
  422      }
  423  
  424      /// Sends the connection note in Chrome (see LinkedInBot), then lets the flow move on.
  425      /// Whatever happens (sent, already connected, skipped, blocked) it's logged and the calls keep going.
  426      func runLinkedInBot(_ f: FollowUp) {
  427          guard let key = f.key else { return }
  428          if let why = LinkedInBot.whyNot {
  429              ActivityLog.add("LinkedIn bot: not running (\(why)). Send the note by hand or click Skip LinkedIn.")
  430              linkedInStatus = LinkedInBot.isOn ? "LinkedIn bot \(why). Send the note by hand or Skip." : nil
  431              return
  432          }
  433          guard isOnScreen(key) || !LinkedInBot.autoSend else {
  434              ActivityLog.add("LinkedIn bot: \(f.prospect ?? "?") is no longer on screen, not sending")
  435              Task { @MainActor [weak self] in self?.drainLinkedInQueue() }
  436              return
  437          }
  438          let company = leads.details?.company ?? recordCompany
  439          Task { [weak self] in
  440              guard let self else { return }
  441              var url = f.linkedinURL
  442              if url == nil, Salesforce.isConnected { url = await Salesforce.linkedIn(of: key) }
  443              guard let url else {
  444                  ActivityLog.add("LinkedIn bot: no LinkedIn link in Salesforce for \(f.prospect ?? "?"): skipped")
  445                  self.finishLinkedIn(key, note: "no LinkedIn link in Salesforce")
  446                  return
  447              }
  448              let first = Screener.firstName(f.prospect) ?? "there"
  449              let note = LinkedInBot.note(f.linkedin, first: first)
  450              ActivityLog.add("LinkedIn bot: \(f.prospect ?? "?") at \(url.absoluteString), note: \(note)")
  451              LinkedInBot.personKey = key
  452              let result = await LinkedInBot.connect(profile: url, note: note, company: company, name: f.prospect) { [weak self] status in
  453                  self?.linkedInStatus = status
  454              }
  455              switch result {
  456              case .sent:
  457                  ActivityLog.add("LinkedIn bot: connection note SENT to \(f.prospect ?? "?") (\(LinkedInBot.sentToday) of \(LinkedInBot.dailyCap) today)")
  458                  self.touchpoints.log(.linkedin)
  459                  DialHistory.logLinkedIn(key)
  460                  self.showToast("LinkedIn note sent")
  461                  self.finishLinkedIn(key, note: nil)
  462              case .alreadyConnected:
  463                  ActivityLog.add("LinkedIn bot: already connected to \(f.prospect ?? "?")")
  464                  self.finishLinkedIn(key, note: "already connected")
  465              case .pending:
  466                  ActivityLog.add("LinkedIn bot: request already pending for \(f.prospect ?? "?")")
  467                  self.finishLinkedIn(key, note: "request already sent")
  468              case .skipped(let why):
  469                  ActivityLog.add("LinkedIn bot: skipped \(f.prospect ?? "?"): \(why)")
  470                  self.finishLinkedIn(key, note: why)
  471              case .blocked(let why):
  472                  ActivityLog.problem("LinkedIn bot: STOPPED. \(why). Paused for 2 hours. The tab is left open for you.")
  473                  self.problem = "LinkedIn: \(why). The bot is paused for 2 hours. Calls keep going."
  474                  self.finishLinkedIn(key, note: why)
  475              }
  476          }
  477      }
  478  
  479      private func finishLinkedIn(_ key: String, note: String?) {
  480          linkedInStatus = note.map { "LinkedIn skipped: \($0)" }
  481          Task { @MainActor [weak self] in self?.drainLinkedInQueue() } // the next queued note
  482          if followUp?.key == key { followUp?.linkedinDone = true } // the flow moves on
  483          Task { [weak self] in
  484              try? await Task.sleep(for: .seconds(6))
  485              self?.linkedInStatus = nil
  486          }
  487      }
  488  
  489      /// The "LinkedIn profile" link on the card: opens it any day, without copying or counting anything.
  490      func openLinkedInProfile() {
  491          guard let f = followUp else { return }
  492          openProfile(f)
  493      }
  494  
  495      /// Opens their profile: the link we have, else their Salesforce LinkedIn field, else a LinkedIn search.
  496      private func openProfile(_ f: FollowUp) {
  497          let words = [f.prospect, recordCompany].compactMap { $0 }.joined(separator: " ")
  498          let search = words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
  499              .flatMap { URL(string: "https://www.linkedin.com/search/results/people/?keywords=\($0)") }
  500          if let profile = f.linkedinURL ?? (leads.isActive ? nil : Self.linkedInProfile(details: recordDetails)) {
  501              NSWorkspace.shared.open(profile)
  502          } else if let key = f.key, Salesforce.isConnected {
  503              // Their LinkedIn field first; search LinkedIn only when it's blank.
  504              Task {
  505                  if let url = await Salesforce.linkedIn(of: key) { NSWorkspace.shared.open(url) }
  506                  else if let search { NSWorkspace.shared.open(search) }
  507              }
  508          } else if let search {
  509              NSWorkspace.shared.open(search)
  510          }
  511      }
  512  
  513      /// The profile link from the record: the LinkedIn field's link on the page, or the URL in the page text.
  514      static func linkedInProfile(details: String?) -> URL? {
  515          var raw = SalesforceChrome.linkedInProfile()
  516          if raw == nil, let details,
  517             let r = details.range(of: #"linkedin\.com/(in|pub)/[A-Za-z0-9\-_%]+"#, options: .regularExpression) {
  518              raw = "https://www." + details[r]
  519          }
  520          guard var link = raw else { return nil }
  521          if link.hasPrefix("http://") { link = "https://" + link.dropFirst("http://".count) }
  522          return URL(string: link)
  523      }
  524  
  525      /// Writes this prospect's voicemail in the background, so it's instant when needed.
  526      func prepareVoicemail() {
  527          voicemailTask?.cancel()
  528          voicemailScript = nil
  529          let forWho = calling
  530          let usedDetails = detailsTried
  531          lastVoicemailTry = Date()
  532          voicemailFor = forWho
  533          voicemailKey = recordKey()
  534          // Written during the last call: use it now, no waiting for Claude.
  535          if var ready = prewarmedVoicemail(for: forWho) {
  536              applyScriptVoicemail(&ready, for: forWho)
  537              voicemailUsedDetails = true
  538              voicemailScript = ready
  539              prewarmHitFor = forWho
  540              fillFollowUp(from: ready, replace: true)
  541              ActivityLog.add("Voicemail for \(forWho ?? "?") was ready early")
  542              return
  543          }
  544          guard let key = Keychain.read(.anthropic) else { return }
  545          let client = CoachSpeed.fastest.client(apiKey: key) // voicemails always use Haiku: fast
  546          let system = self.system
  547          let user = CoachPrompt.voicemail(calling: calling, details: recordDetails,
  548                                           earlierTexts: recordKey().map(DialHistory.sentTexts) ?? [],
  549                                           earlierMessages: recordKey().map(DialHistory.sentLinkedInMessages) ?? [],
  550                                           history: recordKey().map(DialHistory.historySummary) ?? "",
  551                                           localLunch: isLocalLead)
  552          voicemailTask = Task { [weak self] in
  553              var text = ""
  554              do {
  555                  try await client.stream(system: system, user: user) { text = $0 }
  556              } catch {
  557                  let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
  558                  if !cancelled {
  559                      ActivityLog.problem("Voicemail failed for \(forWho ?? "?"): \(error.localizedDescription)")
  560                      self?.lastVoicemailError = error.localizedDescription
  561                      // Let the next try (or the voicemail card) write it again.
  562                      if self?.calling == forWho { self?.voicemailTask = nil; self?.voicemailFor = nil }
  563                  }
  564                  return
  565              }
  566              var s = Suggestion.parse(text)
  567              s.sayComplete = true
  568              s.stage = "Voicemail"
  569              self?.applyScriptVoicemail(&s, for: forWho)
  570              if !Task.isCancelled, !s.say.isEmpty, self?.calling == forWho {
  571                  ActivityLog.add("Voicemail ready for \(forWho ?? "?") (from page: \(usedDetails))")
  572                  self?.voicemailUsedDetails = usedDetails
  573                  self?.voicemailScript = s
  574                  self?.fillFollowUp(from: s, replace: usedDetails) // the card is always up for the person on screen
  575              }
  576              if !Task.isCancelled { self?.voicemailTask = nil }
  577          }
  578      }
  579  
  580      /// Voicemail drop: on a voicemail day's last try, wait for the greeting to end and the beep to pass,
  581      /// then click Aircall's voicemail drop button (the rep's recorded message). Only when the rep
  582      /// recorded one and turned it on (Set up > Voicemail drop).
  583      func scheduleVoicemailDrop() {
  584          guard status == .live, !voicemailDropStarted, currentAttempts >= maxAttempts else { return }
  585          // Why not, said once per call.
  586          var why: String?
  587          if !Prefs.voicemailDropOn { why = "off in Settings" }
  588          else if !autoDial { why = "Auto dial is off" }
  589          else if !AircallPhone.isOn { why = "the Aircall phone isn't inside the app" }
  590          else if currentAttemptKey == nil { why = "no lead on screen" }
  591          else if let k = currentAttemptKey, !Cadence.leavesVoicemail(for: k) { why = "they already got a voicemail" }
  592          if let why {
  593              if !dropWhyLogged { dropWhyLogged = true; ActivityLog.add("Voicemail drop: not dropping (\(why))") }
  594              return
  595          }
  596          guard let key = currentAttemptKey else { return }
  597          voicemailDropStarted = true
  598          seq += 1
  599          show(Suggestion(say: "Waiting for the beep. Your recorded voicemail drops by itself.",
  600                          cue: "Voicemail drop. Nothing to read.", stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
  601          let detectedAt = Date()
  602          Task { [weak self] in
  603              // When to drop, best first:
  604              // 1. The beep: a pure tone heard after some greeting. Drop 0.35 s after it ends.
  605              // 2. No beep: the greeting's sound (from the audio, not the transcript) stopped for 2 s after
  606              //    ending words ("leave a message", "after the tone"), or 3.5 s without them.
  607              // 3. No audio reaching the app: the old transcript timing, a little longer.
  608              // Never before 3 s (a pause mid-greeting), never after 30 s (it would be recording silence).
  609              let beep = BeepDetector.shared
  610              let tune = VMTuning.current
  611              VoicemailSamples.shared.start() // the greeting, saved to tune the timing
  612              var how = "no beep in 35 s"
  613              while let self, self.status == .live {
  614                  if self.dropNowRequested { how = "you clicked Drop now"; break }
  615                  let now = Date()
  616                  let since = now.timeIntervalSince(detectedAt)
  617                  // The beep: only after real greeting (3+ s), and only once the line stayed quiet after it
  618                  // (a tone at the start of a greeting, followed by more talking, doesn't count).
  619                  if let end = beep.lastBeepEnd, beep.voicedSeconds >= 3,
  620                     now.timeIntervalSince(end) >= tune.afterBeep, (beep.lastSoundAt ?? .distantPast) <= end.addingTimeInterval(0.2) {
  621                      how = String(format: "after the beep (%.0f Hz)", beep.lastBeepFreq)
  622                      break
  623                  }
  624                  let said = (self.turns.last { $0.speaker == .prospect }?.text ?? "").lowercased()
  625                  let endings = ["message", "tone", "beep", "as soon as", "get back to you", "return your call",
  626                                 "record", "options", "thank you", "after the", "call you back"]
  627                  let ended = endings.contains { said.suffix(90).contains($0) }
  628                  // No beep: the greeting is over only when BOTH the sound and the words stopped.
  629                  let wordsQuiet = now.timeIntervalSince(self.lastWordsAt ?? detectedAt)
  630                  // Backup from the words: the greeting's ending words were heard and nothing new for 4 s.
  631                  if since >= 5, ended, wordsQuiet >= 4 {
  632                      how = String(format: "after the greeting's last words (%.1f s with no new words)", wordsQuiet)
  633                      break
  634                  }
  635                  if beep.hearing || beep.voicedSeconds > 0 {
  636                      let quiet = now.timeIntervalSince(beep.lastSoundAt ?? detectedAt)
  637                      if since >= 5, beep.voicedSeconds >= 3, wordsQuiet >= 2.5, quiet >= (ended ? tune.quietWithEnding : tune.quietNoEnding) {
  638                          how = String(format: "after the greeting's sound stopped for %.1f s (no beep heard, %@)", quiet, ended ? "ending words heard" : "no ending words")
  639                          break
  640                      }
  641                  } else {
  642                      let quiet = now.timeIntervalSince(self.lastWordsAt ?? detectedAt)
  643                      if since >= 6, quiet >= (ended ? 3.5 : 5.0) {
  644                          how = "after the transcript went quiet (no audio to listen to)"
  645                          break
  646                      }
  647                  }
  648                  if since > 35 { break }
  649                  try? await Task.sleep(for: .milliseconds(100))
  650              }
  651              guard let self else { return }
  652              self.dropNowRequested = false
  653              let transcript = (self.turns.last { $0.speaker == .prospect }?.text) ?? ""
  654              guard self.status == .live else {
  655                  self.saveVoicemailSample(droppedAt: nil, how: "call ended first", transcript: transcript)
  656                  return
  657              }
  658              // Last check: still on the line.
  659              if await Aircall.lineIsOnCall() == false {
  660                  ActivityLog.add("Voicemail drop: the call ended before the drop")
  661                  self.saveVoicemailSample(droppedAt: nil, how: "call ended first", transcript: transcript)
  662                  return
  663              }
  664              let droppedAt = VoicemailSamples.shared.now
  665              ActivityLog.add(String(format: "Voicemail drop: heard %.1f s of greeting audio", BeepDetector.shared.voicedSeconds))
  666              ActivityLog.add("Voicemail drop: dropping \(how)")
  667              guard self.status == .live else { return }
  668              let result = await AircallPhone.shared.dropVoicemail(dryRun: false)
  669              guard result.clicked else {
  670                  ActivityLog.problem("Voicemail drop: couldn't find the button. \(result.info)")
  671                  self.problem = "Couldn't click the voicemail drop button. Read your message instead."
  672                  return
  673              }
  674              ActivityLog.add("Voicemail drop: clicked (\(result.info))")
  675              let finalHow = how
  676              Task { [weak self] in // 3 more seconds of the line, then save the sample
  677                  try? await Task.sleep(for: .seconds(3))
  678                  self?.saveVoicemailSample(droppedAt: droppedAt, how: finalHow, transcript: transcript)
  679              }
  680              DialHistory.logVoicemail(key, body: "(recorded voicemail dropped)")
  681              self.showToast("Voicemail dropped")
  682              // The message plays (about 20 seconds) and the call ends. If it doesn't, hang up (this call only).
  683              let dropCallID = CallTrace.callID
  684              for i in 0..<60 {
  685                  try? await Task.sleep(for: .seconds(1))
  686                  if self.status != .live { return } // the call ended by itself after the message
  687                  if i >= 25, await Aircall.lineIsOnCall() == false { break } // never cut the message short
  688              }
  689              ActivityLog.add("Voicemail drop: message had time to play, hanging up")
  690              if self.status == .live, CallTrace.callID == dropCallID {
  691                  _ = await AircallPhone.shared.hangUp()
  692                  self.endCall()
  693              }
  694          }
  695      }
  696  
  697      /// The opener template filled in with their first name, your name and your company. No waiting.
  698      /// A ready-made voicemail, text and LinkedIn notes with their name, for when Claude
  699      /// can't write them in time. Still the right person, just not personalized.
  700      func instantVoicemail(for calling: String?) -> Suggestion {
  701          let first = Screener.firstName(calling) ?? "there"
  702          let rep = Prefs.repName
  703          let me = rep.isEmpty ? "[your name]" : rep
  704          var s = Suggestion()
  705          let key = recordKey()
  706          let texted = key.map { !DialHistory.person($0).texts.isEmpty } ?? false
  707          let leftBefore = key.map { !DialHistory.person($0).voicemails.isEmpty } ?? false
  708          let onLinkedIn = key.map { !DialHistory.person($0).linkedIns.isEmpty || !DialHistory.person($0).linkedInMessages.isEmpty } ?? false
  709          let linkedInLine = onLinkedIn ? " I also reached out on LinkedIn." : ""
  710          s.say = leftBefore
  711              ? "Hi \(first), \(me) from \(shortCompany) again. Still happy to share how teams like yours cut down on retyping info between systems.\(linkedInLine) \(texted ? "You have my number from my text." : "I'll text you my number.")"
  712              : "Hi \(first), this is \(me) with \(shortCompany). I help teams cut the time they spend retyping info between systems.\(linkedInLine) \(texted ? "I sent you a text earlier, so you have my number." : "I'll send you a quick text so you have my number.")"
  713          s.cue = "Ready-made voicemail (Claude didn't answer in time)."
  714          s.stage = "Voicemail"
  715          s.sayComplete = true
  716          // Plain and neutral on purpose: no pitch of their own, so they never clash with the campaign's tone.
  717          let texts = [
  718              "Hi \(first), \(me) with \(shortCompany). Just tried you and left a voicemail. I'll try you again tomorrow if I don't hear back.",
  719              "Hi \(first), \(me) again from \(shortCompany). Tried you once more today. Is now a busy season for you?",
  720              "\(first), \(me) at \(shortCompany). Still hoping to connect. Is there a better time of day to reach you?",
  721              "Hi \(first), \(me) from \(shortCompany). Should I keep trying you, or is now not a good time?",
  722              "\(first), last note from me (\(me), \(shortCompany)). I won't keep calling. Reach out anytime.",
  723          ]
  724          let sentBefore = recordKey().map { DialHistory.sentTexts($0).count } ?? 0
  725          s.textMessage = texts[sentBefore % texts.count]
  726          s.linkedin = "Hi \(first), I just tried calling you and left a voicemail. Would be glad to connect."
  727          let messages = [
  728              "Hi \(first), I just tried calling you and left a voicemail. Is there a good time to reach you this week?",
  729              "Hi \(first), following up on my call. Is there a better time of day to catch you?",
  730              "\(first), tried you again today. Happy to keep it short whenever works for you.",
  731              "Hi \(first), one more try. Worth a quick chat sometime, or not a fit right now?",
  732              "\(first), I'll stop reaching out after this. If timing changes, I'm happy to help.",
  733          ]
  734          let messagesBefore = recordKey().map { DialHistory.sentLinkedInMessages($0).count } ?? 0
  735          s.linkedinMessage = messages[messagesBefore % messages.count]
  736          applyScriptMessages(&s, for: calling)
  737          applyScriptVoicemail(&s, for: calling)
  738          return s
  739      }
  740  }
  741  
```


## `mac/Sources/ClarityLiveCoach/CoachModel+PhoneTree.swift`

```swift
    1  import AppKit
    2  import AVFoundation
    3  import Combine
    4  import CoreAudio
    5  import Foundation
    6  
    7  /// Phone menus and bad numbers.
    8  extension CoachModel {
    9      /// A phone menu answered: disqualify (Not Quality Prospect / Unqualified), hang up in the
   10      /// in-app phone, and move on. No voicemail, text or redial. If the hang-up button can't be
   11      /// found, the rep hangs up and the next call still starts by itself.
   12      func markPhoneTree() {
   13          badNumberThisCall = true
   14          phoneTreeThisCall = true
   15          attempt?.phoneTreeDetected()
   16          coachTask?.cancel()
   17          thinking = false
   18          voicemailActive = false
   19          sawVoicemail = false
   20          followUp = nil
   21          if let key = currentAttemptKey {
   22              RemovedList.add(key) // off the app's list; Salesforce isn't changed
   23              ActivityLog.add("Phone tree for \(calling ?? "?"): hanging up and skipping them")
   24          }
   25          seq += 1
   26          show(Suggestion(say: "Phone tree. Hanging up. The next call starts by itself.", cue: "Skipped: phone menus aren't worth working.",
   27                          stage: "Exit", sayComplete: true), id: seq, kind: .reply)
   28          guard AircallPhone.isOn else { return }
   29          Task { [weak self] in
   30              guard let self, self.status == .live else { return }
   31              guard await AircallPhone.shared.hangUp() else {
   32                  self.show(Suggestion(say: "Phone tree. Hang up. The next call starts by itself.", cue: "Skipped.",
   33                                       stage: "Exit", sayComplete: true), id: self.seq, kind: .reply)
   34                  return
   35              }
   36              // End on our side once Aircall says the line is free (up to 5 s); otherwise Aircall's own end does it.
   37              for _ in 0..<5 {
   38                  try? await Task.sleep(for: .seconds(1))
   39                  if await Aircall.lineIsOnCall() == false, self.status == .live { self.endCall(); return }
   40              }
   41          }
   42      }
   43  
   44      /// A phone menu answered. Show the quick ways through right away, then have Opus listen to the
   45      /// whole menu and pick the best route to the owner. No voicemail card while the menu plays.
   46      func enterPhoneTree() {
   47          phoneTreeActive = true
   48          voicemailActive = false
   49          sawVoicemail = false
   50          showPhoneTreeTips()
   51          askPhoneTree()
   52      }
   53  
   54      /// Opus 5.5 reads everything the menu has said so far and names the highest-leverage keys to
   55      /// press to reach the owner. Re-asked each time the menu finishes a sentence (after a short pause,
   56      /// so a new option isn't missed). If a live person is now talking, it says what to say to them.
   57      func askPhoneTree() {
   58          guard let apiKey = Keychain.read(.anthropic) else { return }
   59          phoneTreeTask?.cancel()
   60          let menu = prospectSoFar
   61          let who = calling
   62          let user = CoachPrompt.phoneTree(menu: menu, calling: calling, details: recordDetails,
   63                                           repSaid: turns.filter { $0.speaker == .rep }.map(\.text).joined(separator: " "))
   64          let system = self.system
   65          phoneTreeTask = Task { [weak self] in
   66              try? await Task.sleep(for: .milliseconds(1200))
   67              guard let self, !Task.isCancelled, self.phoneTreeActive, self.calling == who else { return }
   68              self.seq += 1
   69              let id = self.seq
   70              self.thinking = true
   71              var text = ""
   72              do {
   73                  try await CoachSpeed.balanced.client(apiKey: apiKey).stream(system: system, user: user) { text = $0 }
   74              } catch {
   75                  if !Task.isCancelled { ActivityLog.problem("Phone tree advice failed: \(error.localizedDescription)") }
   76                  if self.seq == id { self.thinking = false }
   77                  return
   78              }
   79              if self.seq == id { self.thinking = false }
   80              guard !Task.isCancelled, self.phoneTreeActive, self.calling == who else { return }
   81              let human = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("HUMAN")
   82              var s = Suggestion.parse(text)
   83              guard !s.say.isEmpty else { return }
   84              s.sayComplete = true
   85              if human {
   86                  // A person picked up (receptionist or the owner): back to normal coaching.
   87                  self.phoneTreeActive = false
   88                  s.stage = s.stage.isEmpty ? "Gatekeeper" : s.stage
   89                  ActivityLog.add("Phone tree: a person answered for \(who ?? "?")")
   90              } else {
   91                  s.stage = "Phone tree"
   92                  ActivityLog.add("Phone tree route for \(who ?? "?"): \(s.say)")
   93              }
   94              self.show(s, id: id, kind: .reply)
   95          }
   96      }
   97  
   98      func pressKeys(_ keys: String) {
   99          guard status == .live, !keys.isEmpty else { return }
  100          keysMessage = "Pressing \(keys)..."
  101          Task { [weak self] in
  102              let ok = await AircallPhone.shared.sendDigits(keys)
  103              guard let self else { return }
  104              ActivityLog.add("Phone tree: pressed \(keys) (\(ok ? "sent" : "didn't go through"))")
  105              self.keysMessage = ok ? "Pressed \(keys)." : "Couldn't press keys from the app. Use the Aircall keypad."
  106          }
  107      }
  108  
  109      /// A phone menu answered: how to get through to the person. Press 0 for an operator, or dial
  110      /// by name with the first letters of their last name as keypad digits.
  111      func showPhoneTreeTips() {
  112          phoneTreeThisCall = true
  113          attempt?.phoneTreeDetected()
  114          coachTask?.cancel()
  115          thinking = false
  116          let full = Screener.fullName(calling)
  117          let last = full?.split(separator: " ").last.map(String.init) ?? ""
  118          let keys: [Character: Character] = Dictionary(uniqueKeysWithValues: Array(zip("abcdefghijklmnopqrstuvwxyz",
  119                                                                                          "22233344455566677778889999")))
  120          let digits = String(last.lowercased().compactMap { keys[$0] }.prefix(4))
  121          let byName = digits.isEmpty ? "" : " Dial by name: \(digits) (\(last.prefix(4)))."
  122          ActivityLog.add("Phone tree for \(calling ?? "?"): showing how to get through")
  123          seq += 1
  124          var tips = Suggestion(say: "Phone tree. Press 0 for the operator.\(byName)",
  125                                cue: "Listening to the menu for a better route. When a person answers: \"Hi, could you put me through to \(full ?? "them")?\"",
  126                                stage: "Phone tree", sayComplete: true)
  127          tips.keys = "0"
  128          show(tips, id: seq, kind: .reply)
  129      }
  130  
  131      func markBadNumber() {
  132          badNumberThisCall = true
  133          attempt?.badNumberDetected()
  134          coachTask?.cancel()
  135          thinking = false
  136          voicemailActive = false
  137          sawVoicemail = false
  138          followUp = nil
  139          if let key = currentAttemptKey { markNotQualityProspect(key, reason: "carrier says the number can't take calls") }
  140          seq += 1
  141          show(Suggestion(say: "Bad number. Hanging up. The next call starts by itself.", cue: "The carrier says this number doesn't work. Taken off your list.",
  142                          stage: "Exit", sayComplete: true), id: seq, kind: .reply)
  143          ActivityLog.add("Bad number for \(calling ?? "?"): hanging up and removing from the list")
  144          guard AircallPhone.isOn else { return }
  145          Task { [weak self] in
  146              guard let self, self.status == .live, await AircallPhone.shared.hangUp() else { return }
  147              for _ in 0..<5 {
  148                  try? await Task.sleep(for: .seconds(1))
  149                  if await Aircall.lineIsOnCall() == false, self.status == .live { self.endCall(); return }
  150              }
  151          }
  152      }
  153  
  154      /// Bad number: off the call list for good (in the app), and marked in Salesforce as
  155      /// Not Quality Prospect (Contacts) or Unqualified (Leads). Nothing is deleted in Salesforce.
  156      func markNotQualityProspect(_ id: String, reason: String) {
  157          DialHistory.markBadNumber(id)
  158          RemovedList.add(id)
  159          callList.refreshUpNext()
  160          guard let object = Salesforce.objectFor(id: id) else { return }
  161          let value = object == "Lead" ? "Unqualified" : "Not Quality Prospect"
  162          ActivityLog.add("Off the list (\(reason)): \(calling ?? id), marking \(value)")
  163          guard Salesforce.isConnected else { return }
  164          Task { [weak self] in
  165              do {
  166                  try await Salesforce.setStatus(of: id, to: value, unqualifiedReason: "Non-Responsive",
  167                                                 note: reason == "phone tree" ? "Phone tree" : "Bad number (\(reason))")
  168                  ActivityLog.add("Status: saved \(value) (bad number)")
  169                  if self?.statusRecordID == id { self?.recordStatus = value }
  170              } catch {
  171                  ActivityLog.problem("Couldn't mark the bad number in Salesforce: \(error.localizedDescription)")
  172              }
  173          }
  174      }
  175  }
  176  
```


## `mac/Sources/ClarityLiveCoach/Coach.swift`

```swift
    1  import AppKit
    2  import CoachCore
    3  import AVFoundation
    4  import Combine
    5  import CoreAudio
    6  import Foundation
    7  
    8  /// The coach: one call at a time, the person on screen, and the line to say next.
    9  /// Split by job across the CoachModel+*.swift files. Every stored property lives here.
   10  @MainActor
   11  final class CoachModel: ObservableObject {
   12      enum Status { case ready, live, paused }
   13  
   14      /// Where the call is, in one word. Worked out from the flags below, so it's always in step
   15      /// with them; views and the log read this instead of combining flags themselves.
   16      enum Phase: String {
   17          case idle = "Idle"
   18          case gettingReady = "Getting ready"
   19          case waitingForText = "Waiting for the text"
   20          case countdown = "Counting down"
   21          case dialing = "Dialing"
   22          case live = "On a call"
   23          case paused = "Paused"
   24      }
   25  
   26      var phase: Phase {
   27          switch status {
   28          case .live: return .live
   29          case .paused: return .paused
   30          case .ready: break
   31          }
   32          if dialing || pendingDialSince != nil { return .dialing }
   33          if autoNextIn != nil { return .countdown }
   34          if gettingReady != nil { return .gettingReady }
   35          if waitingForText { return .waitingForText }
   36          return .idle
   37      }
   38      /// The last phase written to the activity log.
   39      var loggedPhase: Phase = .idle
   40      enum Kind { case opener, reply, screener, voicemail }
   41  
   42      @Published var status: Status = .ready
   43      @Published var suggestion = Suggestion()
   44      @Published var kind: Kind = .opener
   45      @Published var latestProspect = ""
   46      /// The live transcript lives in its own small model, so a new word only redraws the
   47      /// transcript, not the whole screen.
   48      let transcript = LiveTranscript()
   49      var turns: [Turn] {
   50          get { transcript.turns }
   51          set { transcript.turns = newValue }
   52      }
   53      var interim: [Speaker: String] {
   54          get { transcript.interim }
   55          set { transcript.interim = newValue }
   56      }
   57      @Published var latency: Double?
   58      @Published var problem: String?
   59      @Published var thinking = false
   60      /// Everything about the person on screen, in one place (see `Prospect`).
   61      @Published var prospect = Prospect()
   62      var calling: String? {
   63          get { prospect.calling }
   64          set { prospect.calling = newValue }
   65      }
   66      var recordDetails: String? {
   67          get { prospect.details }
   68          set { prospect.details = newValue }
   69      }
   70      var detailsTried: Bool {
   71          get { prospect.detailsTried }
   72          set { prospect.detailsTried = newValue }
   73      }
   74      var detailsPending: Bool {
   75          get { prospect.detailsPending }
   76          set { prospect.detailsPending = newValue }
   77      }
   78      var personalOpenerFor: String? {
   79          get { prospect.personalOpenerFor }
   80          set { prospect.personalOpenerFor = newValue }
   81      }
   82      var voicemailScript: Suggestion? {
   83          get { prospect.voicemail }
   84          set { prospect.voicemail = newValue }
   85      }
   86      var voicemailFor: String? {
   87          get { prospect.voicemailFor }
   88          set { prospect.voicemailFor = newValue }
   89      }
   90      var voicemailKey: String? {
   91          get { prospect.voicemailKey }
   92          set { prospect.voicemailKey = newValue }
   93      }
   94      var voicemailUsedDetails: Bool {
   95          get { prospect.voicemailUsedDetails }
   96          set { prospect.voicemailUsedDetails = newValue }
   97      }
   98  
   99      /// A new person is on screen: their name, and nothing yet read or written for them.
  100      /// (Their voicemail is handled by the caller: it's sometimes kept for a redial.)
  101      func meet(_ record: String?) {
  102          calling = record
  103          recordDetails = nil
  104          detailsTried = false
  105          personalOpenerFor = nil
  106      }
  107      var tabTicks = 0
  108      var voicemailTask: Task<Void, Never>?
  109      var voicemailActive = false
  110      var mailboxFullShown = false
  111  
  112      // MARK: Where the call is
  113  
  114      /// The four steps shown at the top: Opener -> Discovery -> Value -> Close.
  115      static let journey = ["Opener", "Discovery", "Value", "Close"]
  116      @Published var journeyStep = 0
  117      var nextStepName: String? { journeyStep + 1 < Self.journey.count ? Self.journey[journeyStep + 1] : nil }
  118  
  119      /// Lines shown on this call, so Back can show the previous one.
  120      var history: [(s: Suggestion, kind: Kind)] = []
  121      @Published var historyIndex: Int?   // nil = showing the newest line
  122      var canGoBack: Bool { (historyIndex ?? history.count - 1) > 0 }
  123  
  124      /// The rep's Salesforce list, for the Next button.
  125      let callList = CallList()
  126      var detailsTask: Task<Void, Never>?
  127      var listWatcher: AnyCancellable?
  128      var leadsWatcher: AnyCancellable?
  129      var leadDetailsWatcher: AnyCancellable?
  130  
  131      // MARK: Lead list (Salesforce) and dialing (Aircall)
  132  
  133      /// The call list from a Salesforce list view. When active, Chrome isn't needed at all.
  134      let leads = LeadQueue()
  135      var appliedLeadID: String?
  136      var foreignSkippedID: String?
  137      var mobileSkippedID: String?
  138      var skipsInARow = 0
  139      var openerTask: Task<Void, Never>?
  140      // The queued line: when it was queued and what the rep has said since (it's dropped if they moved on).
  141      var pendingQueuedAt = Date.distantPast
  142      var repWordsAtQueue = 0
  143      var repAskedSinceQueue = false
  144      // Early drafts for the prospect's current turn (to stop bursts of near-identical requests).
  145      var lastEarlyBasis: String?
  146      var earlyDraftsThisTurn = 0
  147      var repWordsAtLastAsk = 0
  148      var nextIsRepLed = false
  149      var repLedIDs: Set<Int> = []
  150      var lastRepFinal = ""
  151      var repEndpointed = false
  152      var summaryInFlight = false
  153      var lastRepQuestionAt = Date.distantPast
  154      var repTextSinceAsk = ""
  155      var screenerWait: Task<Void, Never>?
  156      var yesBranchRepWords = 0
  157      var yesBranchWanted: String?
  158      var yesBranchAskedAt = Date.distantPast
  159      var goalPending = false
  160      var goalPendingTurns = 0
  161      var priorLineOfferedTime = false
  162      var pendingAmbiguousOptOut: String?
  163      var pendingAmbiguousAt = Date.distantPast
  164      var pendingOptOutTask: Task<Void, Never>?
  165      var screenerRetries = 0
  166      var screenerCallID = ""
  167      var prospectNos = 0 { didSet { CoachPrompt.prospectNos = prospectNos } }
  168      var callClosed = false
  169      var callLinesShown = 0
  170      var callLinesUsed = 0
  171      var prospectTurnsAfterFirstNo = 0
  172      var closedOnSecondNo = false
  173      var followsThisStretch = 0
  174      var yesShowTask: Task<Void, Never>?
  175      var frozenShownID = -1
  176      var nextAskModel: String?
  177      var freshLineIDs: Set<Int> = []
  178      var spaceMonitor: Any?
  179      var testLineCounted = false
  180      var openerWaitTask: Task<Void, Never>?
  181      var followPausedUntilQuiet = false
  182      var blockedLoggedID = 0
  183  
  184      /// The prospect agreed to the meeting in their own words: now it counts.
  185      func confirmGoalIfAgreed(_ said: String, checkingEarlierTurn: Bool = false) {
  186          guard goalPending, !goalHit else { return }
  187          // The line they answered offered a time: the current one, or (for their earlier "Sure.") the one before it.
  188          let offeredTime = !suggestion.offered.isEmpty || GoalEvidence.mentionsTime(suggestion.say) || (checkingEarlierTurn && priorLineOfferedTime)
  189          guard GoalEvidence.confirms(said, afterTimeOffer: offeredTime) else {
  190              return // counted down once per full turn in prospectFinished (Fix 5)
  191          }
  192          goalPending = false
  193          goalHit = true
  194          meetingThisWeek = touchpoints.meetingsThisWeek() + 1 // logged when the call ends
  195          meetingMoments += 1
  196          NSSound(named: "Hero")?.play()
  197          CallTrace.event("goal.confirmed", ["prospect_said": said])
  198      }
  199      var recentRepChunks: [String] = [] // the rep's last two transcript chunks (a line read across two still counts)
  200      /// A line written ahead for "yes" to the rep's yes/no question. Never shown until they say yes.
  201      var yesBranch: (question: String, s: Suggestion, ready: Bool)?
  202      var yesBranchTask: Task<Void, Never>?
  203      var lastRepFinalAt = Date.distantPast
  204      var pendingDialSince: Date?
  205      @Published var dialing = false {
  206          didSet { if dialing && !oldValue { sprintSawDial() } }
  207      }
  208      @Published var dialError: String?
  209  
  210      // MARK: Status card (Contact: Relationship Status. Lead: Lead Status.)
  211  
  212      /// The Contact or Lead on screen.
  213      @Published var statusRecordID: String?
  214      /// What Salesforce says right now (nil = blank or not loaded yet).
  215      @Published var recordStatus: String?
  216      /// The record whose status is being saved right now (nil = not saving).
  217      @Published var savingStatusFor: String?
  218      /// "Saving..." only for the person on screen.
  219      var savingStatus: Bool { savingStatusFor != nil && savingStatusFor == statusRecordID }
  220      @Published var statusMessage: String?
  221  
  222      /// "Contact" or "Lead" for the record on screen.
  223      var statusObject: String? { statusRecordID.flatMap(Salesforce.objectFor) }
  224  
  225      // MARK: Moving on after a call: send the text, load the next person, count down, dial
  226  
  227      /// The "Double tap" switch next to Auto-dial: on = call each lead twice (redial), off = once.
  228      var doubleTap: Bool {
  229          get { Prefs.doubleTap }
  230          set { Prefs.doubleTap = newValue; objectWillChange.send() }
  231      }
  232      /// Dials per lead per visit: 2 with Double tap, otherwise 1.
  233      var maxAttempts: Int { doubleTap ? 2 : 1 }
  234  
  235      /// The "Auto-dial" switch next to Aircall phone.
  236      var autoDial: Bool {
  237          get { Prefs.autoDial && !stoppedByRep }
  238          set { Prefs.autoDial = newValue; objectWillChange.send() }
  239      }
  240      /// The rep pressed STOP CALLING: auto dial pauses until START CALLING (the Auto Dial option stays on).
  241      @Published var stoppedByRep = false
  242      /// START CALLING was pressed with Auto Dial on: the app is working down the list by itself.
  243      @Published var autoSession = false
  244  
  245      /// The big green button: start working down the list (by itself when Auto Dial is on).
  246      func startCalling() {
  247          stoppedByRep = false
  248          autoSession = Prefs.autoDial
  249          ActivityLog.add("START CALLING (auto dial \(Prefs.autoDial ? "on" : "off"))")
  250      }
  251  
  252      /// The red button: stop auto dialing now. A call already ringing keeps going; nothing new starts.
  253      func stopCalling() {
  254          stoppedByRep = true
  255          autoSession = false
  256          cancelAutoNext()
  257          ActivityLog.add("STOP CALLING: auto dial stopped by the rep")
  258      }
  259  
  260      // MARK: Double dial
  261  
  262      /// Calls per lead today, and whether the last call reached a person.
  263      var attempts: [String: Int] = [:]
  264      @Published var currentAttemptKey: String?
  265      @Published var lastCallAnswered = true
  266      /// This call's record: dial, who answered, how it ended. Decided by rules, never the model.
  267      var attempt: CallAttempt?
  268      /// When the call really ended (top of endCall), for the 45 s conversation timer.
  269      var callEndedAt: Date?
  270      var attemptsReconciled = false
  271      var currentAttempts: Int { currentAttemptKey.flatMap { attempts[$0] } ?? 0 }
  272  
  273      /// After a first try nobody answered (or voicemail), offer to call right back.
  274      var shouldOfferRedial: Bool {
  275          status == .ready && currentAttemptKey != nil && !lastCallAnswered && currentAttempts < maxAttempts
  276              && !(currentAttemptKey.map(DialHistory.isMaxed) ?? false) // last try: no redial
  277              && !(currentAttemptKey.map(RemovedList.contains) ?? false) // marked Not Quality Prospect / Negative: no redial
  278      }
  279  
  280      var lastWaitingFor = ""
  281  
  282      var noMobileSkips = 0
  283      /// People (15 characters) whose outcome was saved after their last call.
  284      @Published var outcomeSaved: Set<String> = []
  285      /// Aircall wouldn't start a call for this person: one retry, then on to the next.
  286      var dialRetryKey: String?
  287      /// The recorded voicemail was already dropped (or is being) on this call.
  288      var voicemailDropStarted = false
  289      var dropWhyLogged = false
  290      var dropNowRequested = false
  291      var phoneButtonCheck: Task<Void, Never>?
  292      var phoneCallSeen = 0
  293      var lastTickDay = 0
  294      /// When the prospect's last words arrived (to time how fast the coach answered).
  295      var lastHeardThemAt: Date?
  296      var phoneSawHangUp = false
  297      var phoneButtonGone = 0
  298      /// The LinkedIn note is due for this person: the next call waits until it's sent or skipped.
  299      @Published var waitingForLinkedIn = false
  300      /// What the LinkedIn bot is doing right now, for the line under the top bar.
  301      @Published var linkedInStatus: String?
  302      /// Automatic mode: notes waiting to go out, oldest first.
  303      var linkedInQueue: [FollowUp] = []
  304      /// People the bot already took on this session (once each).
  305      var linkedInTried: Set<String> = []
  306      var linkedInWaitingNote: Set<String> = []
  307      var linkedInWhyLogged: Set<String> = []
  308      var linkedInShowing: Set<String> = []
  309      var linkedInGapWaiting = false
  310      /// A short note that fades by itself ("Text sent to Neal").
  311      @Published var toast: String?
  312      var toastTask: Task<Void, Never>?
  313      var bgTextTask: Task<Void, Never>?
  314      /// Calls in a row with no break longer than 3 minutes.
  315      @Published var streak = 0
  316      var lastDialAt = Date.distantPast
  317      /// A 50 minute calling block, then a 10 minute break. nil = no block running.
  318      /// The Call Sprint running now (saved, so a restart keeps it). nil = waiting for the first dial.
  319      @Published var blockStartedAt: Date? = UserDefaults.standard.object(forKey: "sprintStartedAt") as? Date {
  320          didSet { UserDefaults.standard.set(blockStartedAt, forKey: "sprintStartedAt") }
  321      }
  322      /// The sprint's time ran out: show Sprint Complete until the rep starts a new one.
  323      @Published var sprintDone = UserDefaults.standard.bool(forKey: "sprintDone") {
  324          didSet { UserDefaults.standard.set(sprintDone, forKey: "sprintDone") }
  325      }
  326      @Published var breakUntil: Date?
  327      var autoDialBeforeBreak = true
  328      /// Voicemail and follow-ups written ahead of time for the next person, by record Id (15 characters).
  329      var prewarmed: [String: (calling: String, voicemail: Suggestion, at: Date)] = [:]
  330      var prewarmingKey: String?
  331      var prewarmTask: Task<Void, Never>?
  332      /// The person whose ahead-of-time voicemail is in use (their dial doesn't wait for Claude).
  333      var prewarmHitFor: String?
  334      /// People in a row who weren't ready in time and were moved to the back (stops after 5).
  335      var stallSkips = 0
  336      /// "Sending the text in 4": seconds left before the due text goes out by itself. nil = no countdown.
  337      @Published var textSendIn: Int?
  338      var textTask: Task<Void, Never>?
  339      /// Whose LinkedIn profile was last opened by itself, so it opens once per person.
  340      var linkedInOpenedFor: String?
  341  
  342      /// After a voicemail: the text and LinkedIn note to send. Stays after the call until checked off.
  343      @Published var followUp: FollowUp? { didSet { followUpChanged() } }
  344  
  345      /// After a call that's done (no redial): sending the text is the cue to move on.
  346      @Published var waitingForText = false
  347      var textWasDone = false
  348  
  349      /// Proven openers, rotated call by call, with your own scoreboard.
  350      let openers = OpenerBook()
  351      var callOpener: Opener?   // the opener used on this call
  352      var goalHit = false
  353      /// Set the moment a meeting is booked on this call: "Meeting 3 this week". Cleared on the next call.
  354      @Published var meetingThisWeek: Int?
  355      /// Goes up once per meeting booked, so the card glows exactly once.
  356      @Published var meetingMoments = 0
  357      var sawVoicemail = false
  358      var stagesSeen: Set<String> = []
  359      var screenerActive = false       // a screener is talking; wait for the real person
  360      var openerBeforeScreener: Suggestion?
  361      var firstProspectAt: Date?
  362      var lastWordsAt: Date?
  363  
  364      /// Scores every answered call and suggests script improvements over time.
  365      let lab = CallLab()
  366      /// Dials, pickups, texts, LinkedIn notes and more, counted on this Mac.
  367      let touchpoints = Touchpoints()
  368      /// Real free time from the booking calendar (Calendly or Google), for booking.
  369      let availability = Availability()
  370      /// Meeting times already offered on this call, and the next two to offer.
  371      var offeredTimes: Set<Date> = []
  372      var codeByDate: [Date: String] = [:]
  373      @Published var nextOffer: [Date] = []
  374  
  375      /// Proven openers rotate, unless this segment opens with its script's own first line.
  376      var openerStyle: Opener? { campaign.ownOpener ? nil : openers.current }
  377      /// The opener's tag on the card: "Peer name drop · 31%" (how often people kept talking after it,
  378      /// once it has 3 or more answered calls).
  379      var openerName: String? {
  380          guard let o = openerStyle else { return nil }
  381          let s = openers.scores[o.id] ?? OpenerScore()
  382          guard s.calls >= OpenerBook.warmUp else { return o.name }
  383          return "\(o.name) · \(Int((Double(s.kept) / Double(s.calls) * 100).rounded()))%"
  384      }
  385  
  386      @Published private(set) var campaign = Campaign.clarityDiscovery
  387      var system = CoachPrompt.system(for: .clarityDiscovery)
  388  
  389  
  390      func use(_ next: Campaign) {
  391          touchpoints.currentCampaign = next.name
  392          CoachPrompt.scriptText = next.promptText
  393          guard next != campaign else { return }
  394          campaign = next
  395          touchpoints.currentCampaign = next.name
  396          listDone = false
  397          system = CoachPrompt.system(for: next)
  398          if status == .ready { prepareOpener() }
  399      }
  400  
  401      let capture = CaptureEngine()
  402      let streams = StreamBox()
  403      var timer: Timer?
  404      var startedByHand = false
  405      var quietTicks = 0
  406      var reconnects = 0
  407      var useKeyterms = true // turned off if Deepgram ever rejects them
  408  
  409      var uncoached = ""          // prospect words not yet answered
  410      var seq = 0                 // newest request id; older ones are stale
  411      var coachTask: Task<Void, Never>?
  412      var shownID = 0
  413      var shownAt = Date.distantPast
  414      @Published var pending: (id: Int, suggestion: Suggestion)?
  415      /// The rep's words last arrived (live, even mid-sentence). The display never changes while they speak.
  416      var lastRepSpeechAt = Date.distantPast
  417      var repSpeaking: Bool { Date().timeIntervalSince(lastRepSpeechAt) < 1.5 } // a breath between sentences still counts
  418      /// The prospect moved on while the rep was talking: the line on screen is outdated (a new one is queued).
  419      @Published var lineSuperseded = false
  420      /// The coach's screen state (one state machine, see CoachCore).
  421      @Published var coachState: CoachState = .idle
  422      var lastProspectSpeechAt = Date.distantPast
  423      var prospectSpeaking: Bool { Date().timeIntervalSince(lastProspectSpeechAt) < 0.9 }
  424      /// What the rep has said since the line appeared (for paraphrase-friendly delivery checks).
  425      var repSaidSinceShown = ""
  426      var lineDelivered = false
  427      var answeredAfterDelivery = false
  428      /// Hold: the rep pinned the current line; nothing replaces it until they release.
  429      /// Questions asked, answered, interrupted, abandoned (CoachCore), from finished turns.
  430      var questionTracker = QuestionTracker()
  431      var objectionTracker = ObjectionTracker()
  432      @Published var holdLine = false {
  433          didSet { if holdLine != oldValue { CallTrace.event("manual", ["action": holdLine ? "Hold" : "Release", "line": suggestion.say]) } }
  434      }
  435      /// Approved script answers, re-read when the script changes.
  436      var scriptAnswersCache: (text: String, answers: ScriptAnswers)?
  437      var scriptAnswers: ScriptAnswers {
  438          let text = campaign.pastedScript
  439          if let c = scriptAnswersCache, c.text == text { return c.answers }
  440          let a = ScriptAnswers(script: text)
  441          scriptAnswersCache = (text, a)
  442          return a
  443      }
  444  
  445      /// They asked not to be called again: terminal for this call. No more drafting or sales lines.
  446      var doNotCall = false
  447      var loggedSystemHash = ""
  448      /// Both sides' speech as audio time ranges: turn taking vs interruption vs overlap vs backchannel.
  449      var timeline = SpeechTimeline()
  450      var supersededLogged = 0 // suggestion id whose "outdated" was already traced
  451  
  452      func signals() -> CoachSignals {
  453          let raw = timeline.now(Date().timeIntervalSinceReferenceDate)
  454          // Rep done? The transcriber's end-of-speech call and a sentence that isn't left hanging come
  455          // first; the time windows are only the fallback.
  456          let repTalking = RepTurn.stillTalking(wordsInTheAir: Date().timeIntervalSince(lastRepSpeechAt) < 0.35 && !repEndpointed,
  457                                                endpointed: repEndpointed, lastFinal: lastRepFinal,
  458                                                secondsSinceFinal: Date().timeIntervalSince(lastRepFinalAt), inFallbackWindow: raw.rep)
  459          let repInterim = !(interim[.rep] ?? "").trimmingCharacters(in: .whitespaces).isEmpty // words on the wire (H2)
  460          let talk = (rep: repTalking || raw.overlap || repInterim, prospect: raw.prospect && !(repTalking && RepTurn.hangs(lastRepFinal)), overlap: raw.overlap)
  461          return CoachSignals(hasLine: !suggestion.say.isEmpty, prospectSpeaking: talk.prospect, repSpeaking: talk.rep,
  462                       secondsSinceShown: Date().timeIntervalSince(shownAt), repStarted: !repSaidSinceShown.isEmpty || !(interim[.rep] ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
  463                       delivered: lineDelivered, prospectAnsweredSince: answeredAfterDelivery,
  464                       queued: pending != nil, queuedIsForNewTopic: lineSuperseded,
  465                       lineWords: suggestion.say.split(separator: " ").count, overlapping: talk.overlap,
  466                       repOnLine: Delivery.onLine(line: suggestion.say, spoken: repSaidSinceShown), doNotCall: doNotCall)
  467      }
  468      var holdTask: Task<Void, Never>?
  469      var timedID = 0
  470  
  471      // Starting early: when the prospect's sentence sounds finished, Claude starts writing before
  472      // the transcriber confirms they stopped. The answer is held until they really stop.
  473      var specBasis: String?                 // the words the early answer was started on
  474      var specHeld: (s: Suggestion, id: Int)?
  475      var specTimer: Task<Void, Never>?
  476      var confirmedAt: Date?
  477  
  478      var repWordsSinceShown = 0
  479      var repWordsInCall = 0
  480  
  481      var active = false
  482  
  483      /// Only the visible coach screen reacts to calls (not while the audio check runs).
  484      func activate(_ on: Bool) {
  485          active = on
  486          BugReporter.context = { [weak self] in self?.debugSummary() ?? "" }
  487          if on { onAppear() } else if status != .ready { nextCall() }
  488      }
  489  
  490      func onAppear() {
  491          // Redraw the coach when the call list changes (it lives in its own object).
  492          if listWatcher == nil {
  493              listWatcher = callList.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
  494              leadsWatcher = leads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
  495              // A new lead loaded between calls: write its opener and voicemail.
  496              leadDetailsWatcher = leads.$details.sink { [weak self] details in
  497                  guard let details else { return }
  498                  Task { @MainActor in
  499                      guard let self, self.status == .ready, details.id != self.appliedLeadID else { return }
  500                      // Not a US or Canada number: skip right away, before anyone can press Call.
  501                      if !details.doNotCall, let n = details.foreignNumber, !self.dialing {
  502                          ActivityLog.add("\(details.name) isn't a US or Canada number (\(n)): skipping and removing from the list")
  503                          RemovedList.add(details.id)
  504                          self.problem = "Not a US or Canada number. Skipped, on to the next person."
  505                          self.nextLead(dial: Prefs.autoDial)
  506                          return
  507                      }
  508                      self.applyLead()
  509                  }
  510              }
  511              Task { await leads.start() }
  512          }
  513          if suggestion.say.isEmpty, !thinking { prepareOpener() }
  514          guard timer == nil else { return }
  515          timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
  516              Task { @MainActor in self?.tick() }
  517          }
  518      }
  519  
  520      // MARK: Call lifecycle
  521  
  522      /// Points the coach at the record open in Chrome right now: name, opener, voicemail,
  523      /// follow-ups and status all for that one person. Called every second between calls,
  524      /// and always right before dialing, so nothing from the last person carries over.
  525      var lastSyncedKey: String?
  526  
  527      var autoHangingUp = false
  528      var autoHungUpThisCall = false
  529      /// The app hung up a 1st-try recording: redial after 1 second instead of 3.
  530      var redialRightAway = false
  531  
  532      // MARK: Auto next
  533  
  534      /// Seconds left before the app moves to the next lead by itself. Nil = not counting.
  535      @Published var autoNextIn: Int?
  536      var autoNextTask: Task<Void, Never>?
  537  
  538      /// Who's next, for the countdown banner.
  539      var nextLeadName: String? {
  540          if leads.isActive { return leads.nextRow?.name }
  541          if case .ready(let name, _, _) = callList.state { return name }
  542          return nil
  543      }
  544  
  545      var endedAt = Date.distantPast
  546  
  547      /// After a call ends while Chrome still holds the mic, don't treat that as a new call.
  548      var waitingForNewCall = false
  549      var callStartedAt = Date.distantPast
  550      var heardCallAudio = false
  551      var retargets = 0
  552  
  553      // Aircall says when the call is over. Asked every 2 seconds during a call; two "no call"
  554      // answers in a row end it (so one slow answer can't end a live call).
  555      var aircallTicks = 0
  556      var aircallSaysOver = 0
  557      var aircallSawCall = false
  558      var aircallCheck: Task<Void, Never>?
  559  
  560      var hangUpGen = 0
  561  
  562      // MARK: Audio and transcription
  563  
  564      var directAudio = false
  565      var directCheck: Task<Void, Never>?
  566  
  567      var pendingStop: Task<Void, Never>?
  568      var lastVoicemailError: String?
  569      var lastVoicemailTry = Date.distantPast
  570      var instantOpenerID = -1
  571      /// Why a call didn't start. Shown right above the Call button and never wiped by a new line.
  572      @Published var callMessage: String?
  573      /// Everyone due today on this list has been called: time to switch to the next list.
  574      @Published var listDone = false
  575      /// Calling someone the plan skips today takes a 2nd click on Call within 15 seconds.
  576      var callAnywayID: String?
  577      var callAnywayUntil = Date.distantPast
  578  
  579      /// Who the countdown is for.
  580      @Published var autoNextName: String?
  581      /// "Getting Burcin's script ready..." while the app waits to dial.
  582      @Published var gettingReady: String?
  583      /// What the Call button is waiting for, in a sentence (shown above the buttons).
  584      @Published var gettingReadyDetail: String?
  585      var readyTask: Task<Void, Never>?
  586      /// The record Next just opened, until its page is showing.
  587      var openingID: String?
  588      var openingSince = Date.distantPast
  589  
  590      /// Everything the prospect side has said this call (finished words only).
  591      var prospectSoFar: String {
  592          turns.filter { $0.speaker == .prospect }.map(\.text).joined(separator: " ")
  593      }
  594  
  595      /// After the rep asks a question: 6 s of silence shows "Still with me?".
  596      var stillWithMeTask: Task<Void, Never>?
  597  
  598      /// The carrier says the number doesn't work: show it, and skip voicemail and follow-ups.
  599      var badNumberThisCall = false
  600      var phoneTreeThisCall = false
  601  
  602      /// In a phone menu right now (until a person answers or a mailbox beep is coming).
  603      var phoneTreeActive = false
  604      var phoneTreeTask: Task<Void, Never>?
  605  
  606      /// The rep clicked "Press 3": sends those keys into the call (the in-app Aircall phone only).
  607      @Published var keysMessage: String?
  608      var followUpThisCall = false
  609      var followUpWatchdog: Task<Void, Never>?
  610  
  611      /// The title line from the Salesforce page, if it shows one.
  612      var recordTitle: String? {
  613          guard let lines = recordDetails?.components(separatedBy: "\n") else { return nil }
  614          for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "Title" {
  615              if i + 1 < lines.count { return lines[i + 1].trimmingCharacters(in: .whitespaces) }
  616          }
  617          return nil
  618      }
  619  
  620      /// The company line from the Salesforce page, if it shows one (helps LinkedIn find the right person).
  621      var recordCompany: String? {
  622          guard let lines = recordDetails?.components(separatedBy: "\n") else { return nil }
  623          for (i, line) in lines.enumerated() where ["Company", "Account Name"].contains(line.trimmingCharacters(in: .whitespaces)) {
  624              if i + 1 < lines.count { return lines[i + 1].trimmingCharacters(in: .whitespaces) }
  625          }
  626          return nil
  627      }
  628  
  629      // MARK: Claude
  630  
  631      /// Everything the rep wrote in the campaign: each section, then the pasted script.
  632      var campaignText: String {
  633          (Campaign.sections.map { campaign[keyPath: $0.key] } + [campaign.pastedScript]).joined(separator: "\n\n")
  634      }
  635  
  636      /// "Clarity" from the campaign's company description.
  637      var shortCompany: String {
  638          let c = campaign.company
  639          if c.localizedCaseInsensitiveContains("Clarity") { return "Clarity" }
  640          let first = c.components(separatedBy: CharacterSet(charactersIn: ",.;:")).first ?? ""
  641          let words = first.split(separator: " ").prefix(3).joined(separator: " ")
  642          return words.isEmpty ? "Clarity" : words
  643      }
  644  
  645  }
  646  
```


## `mac/Sources/ClarityLiveCoach/CoachTypes.swift`

```swift
    1  import CoachCore
    2  import Foundation
    3  
    4  // MARK: - What Claude sends back
    5  
    6  struct Suggestion: Equatable {
    7      var say = ""
    8      var cue = ""
    9      var stage = ""
   10      var skip = false
   11      /// True once the SAY line is fully written (a line break came after it, or the answer ended).
   12      var sayComplete = false
   13      /// Codes of the meeting times this line offers or confirms, e.g. ["T3", "T5"].
   14      var offered: [String] = []
   15      /// The move Claude picked before writing the line (answer, clarify, discover...).
   16      var move = ""
   17      /// THINK mode only: one short thought for the card (empty when the mode is off).
   18      var think = ""
   19      /// Voicemail follow-ups: a text to send and a LinkedIn connection note.
   20      var textMessage = ""
   21      var linkedin = ""
   22      var linkedinMessage = ""
   23      /// Phone tree: the keys to press now (0-9, * and #), for the one-click button.
   24      var keys = ""
   25      /// A nudge from the app ("Still with me?"), not a script line: shown softer.
   26      var nudge = false
   27  
   28      /// The script row this line came from, when the cue starts with one: "[S5 manual 2] ..." -> "S5 manual 2".
   29      var rowTag: String? {
   30          guard cue.hasPrefix("["), let close = cue.firstIndex(of: "]") else { return nil }
   31          let tag = cue[cue.index(after: cue.startIndex)..<close].trimmingCharacters(in: .whitespaces)
   32          return tag.isEmpty || tag.count > 24 ? nil : tag
   33      }
   34  
   35      /// The cue without the row tag in front.
   36      var cueText: String {
   37          guard rowTag != nil, let close = cue.firstIndex(of: "]") else { return cue }
   38          return cue[cue.index(after: close)...].trimmingCharacters(in: .whitespaces)
   39      }
   40  
   41      /// Claude answers in a tiny line format so words can show while they stream:
   42      ///   SAY: ...
   43      ///   CUE: ...
   44      ///   STAGE: ...
   45      ///   OFFERED: T3, T5   (only when the line offers meeting times)
   46      /// or SKIP when the rep needs no help.
   47      static func parse(_ text: String) -> Suggestion {
   48          var s = Suggestion()
   49          for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
   50              let trimmed = line.trimmingCharacters(in: .whitespaces)
   51              if let m = Move.parse(trimmed) {
   52                  s.move = m.rawValue
   53                  if m == .silent { s.skip = true } // the rep doesn't need a new line
   54                  continue
   55              }
   56              if trimmed.hasPrefix("THINK:") {
   57                  s.think = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
   58                  continue
   59              }
   60              if trimmed.hasPrefix("SAY:") {
   61                  s.say = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
   62                  continue
   63              }
   64              if !s.say.isEmpty { s.sayComplete = true } // any line after SAY means SAY is done
   65              if trimmed.hasPrefix("CUE:") { s.cue = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
   66              else if trimmed.hasPrefix("STAGE:") { s.stage = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
   67              else if trimmed.hasPrefix("SKIP") { s.skip = true }
   68              else if trimmed.hasPrefix("TEXT:") { s.textMessage = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
   69              else if trimmed.hasPrefix("KEYS:") {
   70                  s.keys = String(trimmed.dropFirst(5).filter { "0123456789*#".contains($0) }.prefix(12))
   71              }
   72              else if trimmed.hasPrefix("LINKEDIN MESSAGE:") { s.linkedinMessage = String(trimmed.dropFirst(17)).trimmingCharacters(in: .whitespaces) }
   73              else if trimmed.hasPrefix("LINKEDIN:") { s.linkedin = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
   74              else if trimmed.hasPrefix("OFFERED:") {
   75                  s.offered = trimmed.dropFirst(8).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
   76              }
   77          }
   78          return s
   79      }
   80  }
   81  
   82  // MARK: - Voicemail follow-ups
   83  
   84  struct FollowUp: Equatable {
   85      /// Which record this is for, so a 2nd-try voicemail keeps what the 1st try already sent.
   86      var key: String?
   87      var prospect: String?
   88      var text = ""
   89      /// The rep typed in the text box: never overwrite their words with a fresh draft.
   90      var textEdited = false
   91      var linkedin = ""
   92      var textDone = false
   93      var linkedinDone = false
   94      /// Their phone, from the Salesforce page; editable on the card.
   95      var phone = ""
   96      /// Their LinkedIn profile, from the Salesforce record's LinkedIn field.
   97      var linkedinURL: URL?
   98      /// A note for the text row ("Sending...", an error). nil once sent.
   99      var textStatus: String?
  100      /// The text is on its way: the Send button waits.
  101      var sending = false
  102      /// A LinkedIn direct message, for people who are already connected.
  103      var linkedinMessage = ""
  104      var linkedinMessageDone = false
  105      /// What the 21-day plan says to send today.
  106      var textDue = false
  107      var linkedInDue = false
  108      var linkedInMessageFirst = false // the last call day: a message, not a connection note
  109      /// Salesforce has no Mobile for them (only an office Phone): no text, ever.
  110      var noMobile = false
  111  
  112      /// Everything due today is done.
  113      /// Connect day: both the note and the message. Last call day: the message.
  114      var allDone: Bool {
  115          (textDone || !textDue)
  116              && (!linkedInDue || (linkedInMessageFirst ? linkedinMessageDone : linkedinDone && linkedinMessageDone))
  117      }
  118  }
  119  
  120  // MARK: - The person on screen
  121  
  122  /// Everything the coach knows about the person on screen. Async work (page text, voicemail,
  123  /// opener) checks it's still for them before writing here.
  124  struct Prospect: Equatable {
  125      /// From the Salesforce tab title, e.g. Lead "Jane Doe".
  126      var calling: String?
  127      /// Text from their Salesforce page, when Chrome allows it.
  128      var details: String?
  129      /// Their page was read (or tried).
  130      var detailsTried = false
  131      /// Their page is still loading: read it once it shows.
  132      var detailsPending = false
  133      /// Who Claude's personal opener on screen is for.
  134      var personalOpenerFor: String?
  135      /// Their voicemail, written ahead of time, and who it was written for.
  136      var voicemail: Suggestion?
  137      var voicemailFor: String?
  138      /// The record Id the voicemail is for (matches the follow-up card's key).
  139      var voicemailKey: String?
  140      /// The voicemail was written from their Salesforce page.
  141      var voicemailUsedDetails = false
  142  }
  143  
  144  // MARK: - Call state
  145  
  146  enum Speaker { case rep, prospect }
  147  
  148  struct Turn: Identifiable, Equatable {
  149      let id = UUID()
  150      let speaker: Speaker
  151      var text: String
  152  }
  153  
  154  /// Short noises that never need a new line on their own.
  155  private let filler: Set<String> = [
  156      "yeah", "yep", "yes", "ok", "okay", "uh", "um", "uh-huh", "mhm", "mm-hmm", "hmm",
  157      "right", "sure", "got", "it", "cool", "nice", "great", "hello", "hi",
  158  ]
  159  
  160  /// Lowercase words only, so "Sure, go ahead." matches "sure go ahead".
  161  func normalized(_ text: String) -> String {
  162      text.lowercased()
  163          .components(separatedBy: CharacterSet.alphanumerics.inverted)
  164          .filter { !$0.isEmpty }
  165          .joined(separator: " ")
  166  }
  167  
  168  func isMeaningful(_ text: String) -> Bool {
  169      text.lowercased()
  170          .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
  171          .contains { !$0.isEmpty && !filler.contains($0) }
  172  }
  173  
  174  /// Holds the two transcription streams so audio threads can reach them safely.
  175  final class StreamBox: @unchecked Sendable {
  176      private let lock = NSLock()
  177      private var rep: DeepgramStream?
  178      private var prospect: DeepgramStream?
  179  
  180      func set(rep: DeepgramStream?, prospect: DeepgramStream?) {
  181          lock.withLockValue { self.rep = rep; self.prospect = prospect }
  182      }
  183  
  184      func replace(_ speaker: Speaker, with stream: DeepgramStream?) {
  185          let old = lock.withLockValue { () -> DeepgramStream? in
  186              defer { if speaker == .rep { rep = stream } else { prospect = stream } }
  187              return speaker == .rep ? rep : prospect
  188          }
  189          old?.close()
  190      }
  191  
  192      func send(_ data: Data, isRep: Bool) {
  193          let stream = lock.withLockValue { isRep ? rep : prospect }
  194          stream?.send(data)
  195          if !isRep { BeepDetector.shared.feed(data); VoicemailSamples.shared.feed(data) } // the beep, and greeting samples
  196          AudioDebug.shared.feed(data, isRep: isRep)
  197      }
  198  
  199      func closeAll() {
  200          let (r, p) = lock.withLockValue { (rep, prospect) }
  201          r?.close()
  202          p?.close()
  203          set(rep: nil, prospect: nil)
  204      }
  205  }
  206  
  207  // MARK: - The coach
  208  
  209  /// What's been said on this call, plus the words still coming in. Changes many times a second.
  210  @MainActor
  211  final class LiveTranscript: ObservableObject {
  212      @Published var turns: [Turn] = []
  213      @Published var interim: [Speaker: String] = [:]
  214  }
  215  
```


## `mac/Sources/ClarityLiveCoach/LiveCoach.swift`

```swift
    1  import CoachCore
    2  import Foundation
    3  
    4  /// The live line: Haiku, fast and short, checked in code before it shows.
    5  enum LiveCoach {
    6      /// This call's live-line model: calls alternate Haiku and Sonnet, to compare them on real calls.
    7      static var callModel = "claude-haiku-5-5"
    8      static let testModels = ["claude-haiku-5-5", "claude-sonnet-5-5"]
    9  
   10      /// The next call's model (alternates, and remembers across app restarts).
   11      static func pickModelForNextCall() -> String {
   12          let n = UserDefaults.standard.integer(forKey: "abCallCount")
   13          UserDefaults.standard.set(n + 1, forKey: "abCallCount")
   14          return testModels[n % testModels.count]
   15      }
   16  
   17      static func client(_ key: String, model: String? = nil) -> ClaudeClient {
   18          let model = model ?? callModel
   19          var c = ClaudeClient(apiKey: key)
   20          c.model = model
   21          c.effort = "low"
   22          c.maxTokens = 120          // SAY + CUE + STAGE: a 1 to 2 sentence line
   23          c.idleTimeout = 8
   24          c.totalTimeout = 15
   25          if model.contains("haiku") {
   26              c.thinking = ["type": "disabled"] // this model takes no temperature setting
   27          } else {
   28              c.thinking = ["type": "between_tools"] // Sonnet with thinking off
   29          }
   30          return c
   31      }
   32  
   33      // MARK: Opt out, handled in code (no AI)
   34  
   35      static func isOptOut(_ text: String, isFinal: Bool = true) -> Bool { OptOut.matches(text, isFinal: isFinal) }
   36  
   37      static let optOutLine = "Understood. I'll take you off our list right now. Have a good day."
   38  
   39      /// Last resort when a line fails the check twice: smallest safe fix.
   40      static func sanitize(_ say: String) -> String {
   41          var s = say.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: ",")
   42          s = LineRepair.oneQuestion(s)
   43          return LineRepair.trimToFit(s, max: LineBudget.checkMax) // whole sentences, never a fragment (M7)
   44      }
   45  }
   46  
   47  /// Objections this rep keeps hitting, and the answers that kept the call going. Fed to the live coach
   48  /// on every line, and written into the script's BLOCKERS section every 20 calls.
   49  enum BlockerBook {
   50      struct Entry: Codable { var objection: String; var response: String; var worked: Bool; var date: Date }
   51  
   52      private static func key(_ campaign: UUID) -> String { "blockers-" + campaign.uuidString }
   53  
   54      static func all(_ campaign: UUID) -> [Entry] {
   55          (UserDefaults.standard.data(forKey: key(campaign))).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
   56      }
   57  
   58      static func add(_ new: [Entry], campaign: UUID) {
   59          guard !new.isEmpty else { return }
   60          let list = Array((all(campaign) + new).suffix(400))
   61          UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(campaign))
   62      }
   63  
   64      /// The top blockers, most common first, each with the answer that worked most often.
   65      static func top(_ campaign: UUID, limit: Int = 8) -> [(objection: String, count: Int, worked: Int, best: String?)] {
   66          let groups = Dictionary(grouping: all(campaign)) { $0.objection.lowercased().trimmingCharacters(in: .whitespaces) }
   67          return groups.map { (_, items) in
   68              let wins = items.filter(\.worked)
   69              let best = Dictionary(grouping: wins, by: \.response).max { $0.value.count < $1.value.count }?.key
   70              return (items[0].objection, items.count, wins.count, best)
   71          }
   72          .sorted { $0.count > $1.count }
   73          .prefix(limit).map { $0 }
   74      }
   75  
   76      /// For the live coach: what's worked on this call list's blockers so far.
   77      static func hints(_ campaign: UUID) -> String {
   78          let list = top(campaign).filter { $0.count >= 2 }
   79          guard !list.isEmpty else { return "" }
   80          return "Blockers this rep keeps hitting on this call list, and what kept the call going (use when it fits, in your own words):\n"
   81              + list.map { b in "- \"\(b.objection)\" (\(b.count) times\(b.best.map { "; worked: \"\($0)\"" } ?? "; nothing has worked yet, try a fresh angle"))" }
   82                  .joined(separator: "\n")
   83      }
   84  
   85      /// The BLOCKERS section for the script.
   86      static func section(_ campaign: UUID) -> String? {
   87          let list = top(campaign, limit: 12).filter { $0.count >= 2 }
   88          guard !list.isEmpty else { return nil }
   89          var lines = ["BLOCKERS (learned from your calls, updated every 20 calls)", "ID | Sounds like | Say | Then"]
   90          for (i, b) in list.enumerated() {
   91              lines.append("BLK \(i + 1) | \(b.objection) (\(b.count) times, \(b.worked) kept going) | \(b.best ?? "(no winning answer yet)") | back to the last stage question")
   92          }
   93          return lines.joined(separator: "\n")
   94      }
   95  }
   96  
   97  extension Notification.Name {
   98      /// userInfo: "id" (UUID), "section" (String). The app writes it into that call list's script.
   99      static let blockersUpdated = Notification.Name("blockersUpdated")
  100  }
  101  
```


## `mac/Sources/ClarityLiveCoach/Claude.swift`

```swift
    1  import CoachCore
    2  import Foundation
    3  
    4  /// Streams one coaching answer from the Claude API. Raw HTTPS: there is no official Swift SDK.
    5  struct ClaudeClient {
    6      let apiKey: String
    7      var model = "claude-sonnet-5-5" // Opus is off for now
    8      var effort = "low" // fastest setting that keeps Opus-level quality
    9      /// Room for the answer (and thinking). Long scripts need much more than a live line.
   10      var maxTokens = 1500
   11      /// Give up if nothing arrives for this long (a stuck answer never hangs the app).
   12      var idleTimeout: TimeInterval = 20
   13      /// Give up if the whole answer takes longer than this.
   14      var totalTimeout: TimeInterval = 90
   15      /// Optional thinking setting. nil = the model's default (Opus 5.5 always thinks).
   16      var thinking: [String: String]?
   17      /// Optional sampling temperature (only sent when set).
   18      var temperature: Double?
   19  
   20      struct APIError: LocalizedError {
   21          let message: String
   22          var errorDescription: String? { message }
   23      }
   24  
   25      /// Calls onText with all the text so far, each time more arrives. Cancel the surrounding Task to stop early.
   26      /// onThinking gets the thinking summary so far, when `thinking` asks for display "summarized".
   27      func stream(system: String, user: String, onText: @escaping (String) -> Void,
   28                  onThinking: ((String) -> Void)? = nil, onUsage: (([String: Int]) -> Void)? = nil,
   29                  onModel: ((String) -> Void)? = nil) async throws {
   30          var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
   31          request.httpMethod = "POST"
   32          request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
   33          request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
   34          request.setValue("application/json", forHTTPHeaderField: "content-type")
   35  
   36          var body: [String: Any] = [
   37              "model": model,
   38              "max_tokens": maxTokens,
   39              "stream": true,
   40              "output_config": ["effort": effort],
   41              // The rules and campaign never change during a call, so they are cached.
   42              "system": [["type": "text", "text": system + "\n\n" + ReadingLevel.rule, "cache_control": ["type": "ephemeral"]]],
   43              "messages": [["role": "user", "content": user]],
   44          ]
   45          if let thinking { body["thinking"] = thinking }
   46          // temperature is left out on purpose: the newest models reject it (error 400).
   47          if model.hasPrefix("claude-opus") || model.hasPrefix("claude-fable")
   48              || (model == "claude-sonnet-5-5" && thinking?["type"] != "between_tools") {
   49              // If a safety check declines, the API retries on a fallback model in the same call.
   50              request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
   51              body["fallbacks"] = "default"
   52          }
   53          request.httpBody = try JSONSerialization.data(withJSONObject: body)
   54  
   55          let config = URLSessionConfiguration.default
   56          config.timeoutIntervalForRequest = idleTimeout
   57          config.timeoutIntervalForResource = totalTimeout
   58          let session = URLSession(configuration: config)
   59          defer { session.finishTasksAndInvalidate() }
   60          let (bytes, response) = try await session.bytes(for: request)
   61          guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from Claude") }
   62          guard http.statusCode == 200 else {
   63              var text = ""
   64              for try await line in bytes.lines { text += line }
   65              throw APIError(message: "Claude error \(http.statusCode): \(text.prefix(300))")
   66          }
   67  
   68          var full = ""
   69          var thought = ""
   70          var usage: [String: Int] = [:]
   71          defer { if !usage.isEmpty { onUsage?(usage) } }
   72          for try await line in bytes.lines {
   73              guard line.hasPrefix("data: "),
   74                    let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
   75                    let type = json["type"] as? String else { continue }
   76              if type == "content_block_delta",
   77                 let delta = json["delta"] as? [String: Any],
   78                 delta["type"] as? String == "text_delta",
   79                 let text = delta["text"] as? String {
   80                  full += text
   81                  onText(full)
   82              } else if type == "content_block_delta", let onThinking,
   83                        let delta = json["delta"] as? [String: Any],
   84                        delta["type"] as? String == "thinking_delta",
   85                        let text = delta["thinking"] as? String {
   86                  thought += text
   87                  onThinking(thought)
   88              } else if type == "message_start", let m = json["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
   89                  // The model that actually answered (differs from the one asked for on a fallback).
   90                  if let served = m["model"] as? String { onModel?(served) }
   91                  // Input side: plain input, cache reads (cheap, fast) and cache writes.
   92                  for k in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] { if let v = u[k] as? Int { usage[k] = v } }
   93              } else if type == "message_delta", let u = json["usage"] as? [String: Any], let out = u["output_tokens"] as? Int {
   94                  usage["output_tokens"] = out
   95              } else if type == "error" {
   96                  let error = json["error"] as? [String: Any]
   97                  throw APIError(message: (error?["message"] as? String) ?? "Claude stream error")
   98              }
   99          }
  100      }
  101  }
  102  
  103  extension ClaudeClient {
  104      /// The JSON object in Claude's answer (from the first "{" to the last "}"), or nil.
  105      static func jsonObject(in text: String) -> [String: Any]? {
  106          guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
  107          return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
  108      }
  109  
  110      /// Streams the whole answer and returns its JSON object. Throws if it isn't JSON.
  111      func json(system: String, user: String) async throws -> [String: Any] {
  112          var text = ""
  113          try await stream(system: system, user: user) { text = $0 }
  114          guard let json = Self.jsonObject(in: text) else {
  115              throw APIError(message: "Claude's answer wasn't in the expected format. Try again.")
  116          }
  117          return json
  118      }
  119  }
  120  
  121  extension ClaudeClient {
  122      /// "claude-haiku-5-5" -> "Haiku 5.5", for the log.
  123      static func displayName(_ model: String) -> String {
  124          let parts = model.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
  125          guard let name = parts.first else { return model }
  126          let version = parts.dropFirst().prefix(2).joined(separator: ".")
  127          return name.prefix(1).uppercased() + name.dropFirst() + (version.isEmpty ? "" : " " + version)
  128      }
  129  }
  130  
  131  /// How the live coach trades polish for speed. Pick in the gear menu.
  132  enum CoachSpeed: String, CaseIterable, Identifiable {
  133      case balanced, fastest // "best" (Opus) is off for now; a saved "best" falls back to balanced
  134  
  135      var id: String { rawValue }
  136  
  137      var label: String {
  138          switch self {
  139          case .balanced: return "Fast (best for most people)"
  140          case .fastest: return "Fastest"
  141          }
  142      }
  143  
  144      static var current: CoachSpeed {
  145          .fastest // fixed while the model test runs: openers stay quick (Haiku), and no setting skews the test
  146      }
  147  
  148      func client(apiKey: String) -> ClaudeClient {
  149          var c = ClaudeClient(apiKey: apiKey)
  150          c.effort = "low"
  151          c.idleTimeout = 10 // a live line that stalls is useless; the rep keeps the last one
  152          c.totalTimeout = 30
  153          switch self {
  154          case .balanced:
  155              c.model = "claude-sonnet-5-5"
  156              c.thinking = ["type": "between_tools"] // Sonnet 5.5's way to turn thinking off
  157          case .fastest:
  158              c.model = "claude-haiku-5-5"
  159              c.thinking = ["type": "disabled"]
  160          }
  161          return c
  162      }
  163  }
  164  
```


## `mac/Sources/ClarityLiveCoach/Guardrail.swift`

```swift
    1  import CoachCore
    2  import Foundation
    3  
    4  /// The house rules for every line the rep reads, checked in code (the model sometimes breaks them).
    5  /// Used on new scripts now; the live coach will use the same check.
    6  enum Guardrail {
    7      static let banned = ["awesome", "super excited", "beautiful day", "my friend", "brother", "to be honest",
    8                           "selected", "assigned", "referred", "certified", "replace", "never messes up",
    9                           "roadmap", "transformation", "maturity", "enablement", "digital",
   10                           // never-say: compliance, data terms, liability, other AI tools
   11                           "fully compliant", "100% compliant", "regulators accept", "approved by regulators", "hipaa compliant",
   12                           "we never store", "we don't store", "never trained on", "train on your data", "trained on your data",
   13                           "days of retention", "data retention", "retain your data", "liable", "liability",
   14                           "better than chatgpt", "better than copilot", "better than gemini", "chatgpt can't", "copilot can't"]
   15      private static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
   16                                 "tomorrow", "next week"]
   17  
   18      /// What's wrong with a line, or [] if it's fine.
   19      /// - long: voicemails, texts and LinkedIn notes may run past 25 words.
   20      /// - endsCall: the row ends the call, so it needn't end with a question.
   21      static func problems(_ line: String, long: Bool = false, endsCall: Bool = false, allowTimes: Bool = false) -> [String] {
   22          let say = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
   23          guard !say.isEmpty, !say.lowercased().hasPrefix("show nothing") else { return [] }
   24          var out: [String] = []
   25          let words = say.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
   26          if !long, words > LineBudget.checkMax { out.append("\(words) words (max \(LineBudget.checkMax))") }
   27          let questions = say.filter { $0 == "?" }.count
   28          if !long, questions > 1 { out.append("more than one question") }
   29          if !long, !endsCall, !say.hasSuffix("?") { out.append("doesn't end with a question") }
   30          // All-caps abbreviations, except AI and [slots].
   31          let noSlots = say.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
   32          let caps = noSlots.matches(#"\b[A-Z]{2,}\b"#).filter { $0 != "AI" }
   33          if !caps.isEmpty { out.append("abbreviation: " + caps.joined(separator: ", ")) }
   34          let lower = say.lowercased()
   35          let hits = banned.filter { lower.contains($0) }
   36          if !hits.isEmpty { out.append("banned: " + hits.joined(separator: ", ")) }
   37          if say.contains("$") || say.contains("%") || lower.range(of: #"\d+\s*(dollar|percent)"#, options: .regularExpression) != nil {
   38              out.append("money or percent")
   39          }
   40          if say.contains("\u{2014}") { out.append("em dash") }
   41          let grade = ReadingLevel.grade(noSlots)
   42          if grade > ReadingLevel.checkMax {
   43              out.append(String(format: "reading level grade %.1f (max %.0f): use shorter words and sentences", grade, ReadingLevel.target))
   44          }
   45          let timeLike = lower.range(of: #"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)"#, options: .regularExpression) != nil
   46          if !allowTimes, timeLike || days.contains(where: { noSlots.lowercased().contains($0) }) { out.append("a made-up day or time (use [Slot A])") }
   47          if lower.contains("show the") || lower.contains("show s") { out.append("an instruction, not a real line") }
   48          return out
   49      }
   50  
   51      struct Issue { let id: String; let say: String; let problems: [String] }
   52  
   53      /// Checks every Say line in a backbone script (rows with " | " under a header with a Say column).
   54      static func lint(script: String) -> [Issue] {
   55          var issues: [Issue] = []
   56          var sayCol: Int?
   57          var thenCol: Int?
   58          var long = false
   59          for raw in script.components(separatedBy: "\n") {
   60              let line = raw.trimmingCharacters(in: .whitespaces)
   61              let upper = line.uppercased()
   62              if upper.contains("VOICEMAIL") || upper.hasPrefix("TEXTS") || upper.hasPrefix("LINKEDIN") { if !line.contains("|") { long = true } }
   63              else if !line.contains("|"), line == upper, line.count > 2, line.count < 40 { long = false } // a new section title
   64              guard line.contains("|") else { continue }
   65              let cols = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
   66              if let i = cols.firstIndex(where: { $0 == "Say" || $0 == "Send" }) {
   67                  sayCol = i; thenCol = cols.firstIndex(of: "Then"); continue // a header row
   68              }
   69              guard let s = sayCol, cols.count > s else { continue }
   70              let then = thenCol.flatMap { cols.count > $0 ? cols[$0].lowercased() : nil } ?? ""
   71              let ends = ["end", "show nothing", "directory", "wait"].contains { then.contains($0) }
   72              let p = problems(cols[s], long: long, endsCall: ends)
   73              if !p.isEmpty { issues.append(Issue(id: cols[0], say: cols[s], problems: p)) }
   74          }
   75          return issues
   76      }
   77  }
   78  
   79  private extension String {
   80      func matches(_ pattern: String) -> [String] {
   81          guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
   82          let ns = self as NSString
   83          return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
   84      }
   85  }
   86  
```


## `mac/Sources/ClarityLiveCoach/ScriptPage.swift`

```swift
    1  import CryptoKit
    2  import Foundation
    3  
    4  /// The "My script" card: the campaign's script as one page a rep can read out loud.
    5  /// Only spoken words, in call order (opener first). No tool rules, row IDs, texts or LinkedIn notes.
    6  /// Claude writes the page once per version of the script and it's saved on this Mac. Until then
    7  /// (or with no key), a quick local read of the script's "Say" lines stands in.
    8  @MainActor
    9  final class ScriptPage: ObservableObject {
   10      static let shared = ScriptPage()
   11  
   12      struct Section: Identifiable {
   13          let id: Int
   14          let title: String
   15          let lines: [String]
   16      }
   17  
   18      /// Bumped whenever a page is ready, so the card redraws.
   19      @Published private(set) var version = 0
   20      private var cache: [String: String]
   21      private var writing: Set<String> = []
   22      private var failed: [String: Date] = [:]
   23      private static let storeKey = "scriptPages1"
   24  
   25      private init() {
   26          cache = (UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String]) ?? [:]
   27      }
   28  
   29      private static func key(_ script: String) -> String {
   30          SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
   31      }
   32  
   33      /// The one page script, as sections. Starts Claude writing a better one if there isn't one yet.
   34      func sections(for script: String) -> [Section] {
   35          let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
   36          guard script.count > 20 else { return [] }
   37          let key = Self.key(script)
   38          if let page = cache[key] { return Self.split(page) }
   39          startWriting(script, key: key)
   40          return Self.quickRead(script)
   41      }
   42  
   43      /// The rep edited a section on the My Script card. Saves the page with the new lines and returns the
   44      /// script with the change in it: lines found word for word are replaced in place; the rest go into a
   45      /// "Rep's own wording" block at the end, so the live coach uses them too.
   46      func edit(script: String, title: String, oldLines: [String], newLines: [String]) -> String {
   47          let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
   48          let oldKey = Self.key(script)
   49          let current = cache[oldKey].map(Self.split) ?? Self.quickRead(script)
   50          var updated = script
   51          var unplaced: [String] = []
   52          for (i, line) in newLines.enumerated() {
   53              let old = i < oldLines.count ? oldLines[i] : nil
   54              guard line != old else { continue }
   55              if let old, !old.isEmpty, updated.contains(old) { updated = updated.replacingOccurrences(of: old, with: line) }
   56              else { unplaced.append(line) }
   57          }
   58          let marker = "REP'S OWN WORDING (use these lines in these words)"
   59          if !unplaced.isEmpty {
   60              var block = unplaced.map { "\(title): \($0)" }.joined(separator: "\n")
   61              if let r = updated.range(of: marker) {
   62                  block = String(updated[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
   63                      .components(separatedBy: "\n").filter { !$0.hasPrefix("\(title):") }.joined(separator: "\n")
   64                      + "\n" + block
   65                  updated = String(updated[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
   66              }
   67              updated += "\n\n" + marker + "\n" + block.trimmingCharacters(in: .whitespacesAndNewlines)
   68          }
   69          // The page keeps the rep's edit, under the new script's key, so it isn't rewritten over it.
   70          let page = current.map { s in "\(s.title.uppercased())\n" + (s.title == title ? newLines : s.lines).joined(separator: "\n") }
   71              .joined(separator: "\n\n")
   72          cache[Self.key(updated)] = page
   73          cache[oldKey] = page
   74          UserDefaults.standard.set(cache, forKey: Self.storeKey)
   75          version += 1
   76          ActivityLog.add("My script: \(title) edited by the rep")
   77          return updated
   78      }
   79  
   80      /// True while Claude is still writing the page for this script.
   81      func isWriting(_ script: String) -> Bool {
   82          writing.contains(Self.key(script.trimmingCharacters(in: .whitespacesAndNewlines)))
   83      }
   84  
   85      private func startWriting(_ script: String, key: String) {
   86          guard !writing.contains(key), failed[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true,
   87                let apiKey = Keychain.read(.anthropic) else { return }
   88          writing.insert(key)
   89          Task { [weak self] in
   90              let page = await Self.write(script, apiKey: apiKey)
   91              guard let self else { return }
   92              self.writing.remove(key)
   93              if let page, !Self.split(page).isEmpty {
   94                  self.cache[key] = page
   95                  UserDefaults.standard.set(self.cache, forKey: Self.storeKey)
   96                  ActivityLog.add("My script: one page version written (\(page.split(separator: " ").count) words)")
   97              } else {
   98                  self.failed[key] = Date()
   99              }
  100              self.version += 1
  101          }
  102      }
  103  
  104      // MARK: Claude writes the page
  105  
  106      private static func write(_ script: String, apiKey: String) async -> String? {
  107          var client = CoachSpeed.balanced.client(apiKey: apiKey) // fast: Sonnet, no thinking
  108          client.maxTokens = 1500
  109          client.idleTimeout = 30
  110          client.totalTimeout = 90
  111          let system = """
  112          You turn a long cold call script (written for a software tool) into the one page script a sales rep
  113          reads out loud on a call. Return plain text only.
  114  
  115          Rules:
  116          - Only words the rep says to a person. No rules for the tool, no row IDs (S2, O4), no state names,
  117            no "sounds like" lists, no notes about what to track, no texts, no LinkedIn notes, no emails.
  118          - Use the script's own lines, word for word where you can. Never invent facts, numbers or offers.
  119          - Keep slots like [Name], [SDR], [Firm], [Day], [Time] exactly as written.
  120          - Order: the way a call goes. Start with the opener.
  121          - At most 280 words in total. Pick the lines used most; drop the rest.
  122          - Plain, natural language. No markdown, no bullets, no quotes around lines.
  123  
  124          Format, exactly: a section title in CAPITALS on its own line, then its lines, one per line.
  125          Use these sections, in this order, skipping any the script doesn't have:
  126          OPENER (1 line)
  127          WHY I'M CALLING (1 or 2 lines)
  128          QUESTIONS TO ASK (up to 4 lines)
  129          THE ASK (1 or 2 lines)
  130          IF THEY SAY (up to 5 lines, each as: Not interested: the reply)
  131          CLOSE (1 or 2 lines)
  132          GATEKEEPER (1 or 2 lines)
  133          VOICEMAIL (1 line)
  134          """
  135          var text = ""
  136          do {
  137              try await client.stream(system: system, user: "The script:\n\n\(script)") { text = $0 }
  138          } catch {
  139              ActivityLog.problem("My script: couldn't write the one page version: \(error.localizedDescription)")
  140              return nil
  141          }
  142          let page = text.trimmingCharacters(in: .whitespacesAndNewlines)
  143          return page.isEmpty ? nil : page
  144      }
  145  
  146      // MARK: Reading a page into sections
  147  
  148      /// "OPENER" on its own line starts a section; the lines under it belong to it.
  149      static func split(_ page: String) -> [Section] {
  150          var out: [Section] = []
  151          var title = ""
  152          var lines: [String] = []
  153          func close() {
  154              if !title.isEmpty, !lines.isEmpty { out.append(Section(id: out.count, title: title, lines: lines)) }
  155              lines = []
  156          }
  157          for raw in page.components(separatedBy: .newlines) {
  158              let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t*#-•"))
  159              guard !line.isEmpty else { continue }
  160              let letters = line.filter(\.isLetter)
  161              if letters.count >= 3, letters == letters.uppercased(), line.count <= 40 {
  162                  close()
  163                  title = line.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
  164              } else if !title.isEmpty {
  165                  lines.append(fill(line))
  166              }
  167          }
  168          close()
  169          return out
  170      }
  171  
  172      /// [SDR] becomes the rep's first name; other slots stay, so the rep knows what goes there.
  173      private static func fill(_ line: String) -> String {
  174          let name = Prefs.repName
  175          return name.isEmpty ? line : line.replacingOccurrences(of: "[SDR]", with: name)
  176      }
  177  
  178      // MARK: Quick local read (no Claude)
  179  
  180      /// Pulls the quoted "Say" lines out of a backbone-style script (tab tables under S1..., OBJECTIONS,
  181      /// VOICEMAIL headings). Scripts in other layouts give nothing; the card then says it's being written.
  182      static func quickRead(_ script: String) -> [Section] {
  183          // What each heading becomes, how many lines to keep, and where it goes on the page.
  184          func plan(_ heading: String) -> (title: String, keep: Int, order: Int)? {
  185              let h = heading.uppercased()
  186              if h.contains("OPENER") { return ("OPENER", 1, 0) }
  187              if h.contains("REASON") { return ("WHY I'M CALLING", 2, 1) }
  188              if h.contains("QUESTION") || h.contains("DISCOVERY") { return ("QUESTIONS TO ASK", 4, 2) }
  189              if h.contains("ASK") { return ("THE ASK", 2, 3) }
  190              if h.hasPrefix("OBJECTION") { return ("IF THEY SAY", 5, 4) }
  191              if h.contains("CLOSE") { return ("CLOSE", 2, 5) }
  192              if h.contains("GATEKEEPER") { return ("GATEKEEPER", 2, 6) }
  193              if h.hasPrefix("VOICEMAIL") { return ("VOICEMAIL", 1, 7) }
  194              return nil
  195          }
  196          func quoted(_ s: String) -> String? {
  197              let t = s.trimmingCharacters(in: .whitespaces)
  198              guard let first = t.first, "“\"".contains(first) else { return nil }
  199              let inner = t.dropFirst()
  200              let end = inner.firstIndex(where: { "”\"".contains($0) }) ?? inner.endIndex
  201              let text = String(inner[..<end]).trimmingCharacters(in: .whitespaces)
  202              return text.count >= 8 ? text : nil
  203          }
  204          var found: [Int: (title: String, keep: Int, lines: [String])] = [:]
  205          var current: (title: String, keep: Int, order: Int)?
  206          for raw in script.components(separatedBy: .newlines) {
  207              let line = raw.trimmingCharacters(in: .whitespaces)
  208              guard !line.isEmpty else { continue }
  209              if !line.contains("\t") {
  210                  // A heading: "S2: OPENER", "OBJECTIONS", "VOICEMAIL". Other plain lines are tool notes.
  211                  let letters = line.filter(\.isLetter)
  212                  if letters.count >= 4, letters == letters.uppercased(), line.count <= 50 { current = plan(line) }
  213                  continue
  214              }
  215              guard let c = current else { continue }
  216              let cols = line.components(separatedBy: "\t")
  217              // The spoken line: the last column that is one whole quote (earlier ones are "sounds like").
  218              // (In the objections table the 2nd column is what the prospect says, never the reply.)
  219              guard let say = cols.dropFirst(c.title == "IF THEY SAY" ? 2 : 1).reversed().compactMap({ col -> String? in
  220                  let t = col.trimmingCharacters(in: .whitespaces)
  221                  guard let last = t.last, "”\"".contains(last) || t.hasSuffix("”.") else { return nil }
  222                  return t.filter({ "“".contains($0) }).count <= 1 ? quoted(t) : nil
  223              }).first else { continue }
  224              var entry = found[c.order] ?? (c.title, c.keep, [])
  225              guard entry.lines.count < c.keep else { continue }
  226              if c.title == "IF THEY SAY", cols.count > 2, let hear = quoted(cols[1].components(separatedBy: ",")[0]) {
  227                  entry.lines.append("\(hear.prefix(1).uppercased() + hear.dropFirst()): \(fill(say))")
  228              } else {
  229                  entry.lines.append(fill(say))
  230              }
  231              found[c.order] = entry
  232          }
  233          return found.keys.sorted().enumerated().compactMap { i, k in
  234              guard let e = found[k], !e.lines.isEmpty else { return nil }
  235              return Section(id: i, title: e.title, lines: e.lines)
  236          }
  237      }
  238  }
  239  
```


## `mac/Sources/ClarityLiveCoach/ScriptTemplates.swift`

```swift
    1  import CryptoKit
    2  import Foundation
    3  
    4  /// The text and LinkedIn templates written in a campaign script, found by Claude reading the
    5  /// whole script (so any heading, layout or wording works). Read once per version of the script,
    6  /// then saved on this Mac. Copied word for word: placeholders like [Name] stay as written.
    7  @MainActor
    8  final class ScriptTemplates {
    9      static let shared = ScriptTemplates()
   10  
   11      struct Found: Codable, Equatable {
   12          /// Texts in the order they're sent: the missed call text first, then follow-ups.
   13          var texts: [String] = []
   14          var linkedinNote: String?
   15          var linkedinMessage: String?
   16          /// The rep's first line when the person picks up, word for word ("Is this ___?").
   17          var opener: String?
   18          /// Voicemail scripts in the order they're left (most scripts have one).
   19          var voicemails: [String] = []
   20      }
   21  
   22      private var cache: [String: Found]
   23      private var reading: Set<String> = []
   24      /// Scripts Claude couldn't read, and when: tried again after 10 minutes, not on every card.
   25      private var failed: [String: Date] = [:]
   26      private var waiting: [String: [() -> Void]] = [:]
   27      private static let storeKey = "scriptTemplates4" // 4: also finds voicemail scripts
   28  
   29      private init() {
   30          cache = UserDefaults.standard.data(forKey: Self.storeKey)
   31              .flatMap { try? JSONDecoder().decode([String: Found].self, from: $0) } ?? [:]
   32      }
   33  
   34      /// The templates for this script, if already read. If not, starts reading it and calls
   35      /// `onReady` once it's done (only if it found something).
   36      func templates(for script: String, onReady: (() -> Void)? = nil) -> Found? {
   37          let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
   38          guard script.count > 20 else { return nil }
   39          let key = Self.key(script)
   40          if let found = cache[key] { return found }
   41          if let onReady { waiting[key, default: []].append(onReady) }
   42          guard !reading.contains(key), failed[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true,
   43                let apiKey = Keychain.read(.anthropic) else { return nil }
   44          reading.insert(key)
   45          Task { [weak self] in
   46              let found = await Self.read(script, apiKey: apiKey)
   47              guard let self else { return }
   48              self.reading.remove(key)
   49              guard let found else { self.waiting[key] = nil; self.failed[key] = Date(); return }
   50              self.cache[key] = found
   51              if let data = try? JSONEncoder().encode(self.cache) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
   52              ActivityLog.add("Script templates: \(found.voicemails.count) voicemail(s), \(found.texts.count) text(s), LinkedIn note \(found.linkedinNote == nil ? "no" : "yes"), LinkedIn message \(found.linkedinMessage == nil ? "no" : "yes")")
   53              let calls = self.waiting[key] ?? []
   54              self.waiting[key] = nil
   55              calls.forEach { $0() }
   56          }
   57          return nil
   58      }
   59  
   60      /// Drops a heading or note in front of a quoted template, like
   61      /// `Connection request (under 200 characters) “Hi [Name], ...”` → `Hi [Name], ...`.
   62      /// Only when the words before the quote aren't the message itself (no greeting in them).
   63      static func cleanTemplate(_ raw: String) -> String {
   64          var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
   65          if let q = t.firstIndex(where: { "“\"".contains($0) }), q != t.startIndex {
   66              let before = t[..<q].lowercased()
   67              let greeting = ["hi ", "hey ", "hello ", "good morning", "good afternoon"].contains { before.contains($0) }
   68              if !greeting, before.count < 160 { t = String(t[q...]) }
   69          }
   70          // The quote marks around it, and a closing quote with nothing after it.
   71          t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"“”*_"))
   72          if let close = t.firstIndex(of: "”"), t[t.index(after: close)...].trimmingCharacters(in: .whitespaces).count < 3 {
   73              t = String(t[..<close])
   74          }
   75          return t.trimmingCharacters(in: .whitespacesAndNewlines)
   76      }
   77  
   78      private static func key(_ script: String) -> String {
   79          SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
   80      }
   81  
   82      private static func read(_ script: String, apiKey: String) async -> Found? {
   83          let client = CoachSpeed.balanced.client(apiKey: apiKey)
   84          let system = "You pull message templates out of sales scripts. You copy, you never write. Answer with JSON only."
   85          let user = """
   86          Below is a cold calling campaign and its script. Find the messages the rep sends by text (SMS) or on LinkedIn.
   87          Headings can be anything ("Text after a missed call", "If no reply in 2 days", "LinkedIn connection
   88          request", "DM", and so on), or there may be no heading at all. Read for meaning.
   89  
   90          Return exactly this JSON and nothing else:
   91          {"texts": ["...", "..."], "linkedinNote": "..." or null, "linkedinMessage": "..." or null, "opener": "..." or null,
   92           "voicemails": ["..."]}
   93  
   94          - texts: every text message template, in the order they're sent. The first one is the text after a missed
   95            call or voicemail; then follow-ups ("if no reply", "day 3", and so on). If the script gives two versions
   96            of the same message, keep only the first. Empty list if there are none.
   97          - linkedinNote: the LinkedIn connection request / connection note template, or null.
   98          - linkedinMessage: the LinkedIn direct message template (for people already connected), or null.
   99            If one template is labeled as both ("LinkedIn message/connection request"), put it in both.
  100          - opener: the rep's very first line when the person picks up the phone (the start of the call script), word
  101            for word, blanks and all ("Is this ___?"). Only the rep's first line, not the rest of the call. null if
  102            the script has no call script. If the script has a gatekeeper line and a separate opener for the
  103            person themselves (like "S2 open"), use the person's opener.
  104          - voicemails: every voicemail script (what the rep says after the beep), in the order they're left. If the
  105            script gives two versions of the same voicemail, keep only the first. Empty list if there are none.
  106          - Copy each one exactly: same words, same placeholders ([Name], {first name}, [Your Name]). Drop only
  107            the quote marks around it. Never include the heading, label or notes before or after it, like
  108            "Connection request (under 200 characters, so it fits any account)". Start at the message's first word.
  109          - For texts and LinkedIn, don't use voicemail scripts, call lines or email templates. Don't write anything that isn't in the script.
  110  
  111          Campaign and script:
  112          \(script)
  113          """
  114          var text = ""
  115          do {
  116              try await client.stream(system: system, user: user) { text = $0 }
  117          } catch {
  118              ActivityLog.problem("Script templates: couldn't read the script: \(error.localizedDescription)")
  119              return nil
  120          }
  121          guard let json = ClaudeClient.jsonObject(in: text) else {
  122              ActivityLog.problem("Script templates: Claude's answer wasn't readable")
  123              return nil
  124          }
  125          func clean(_ v: Any?) -> String? {
  126              guard let raw = v as? String else { return nil }
  127              let s = cleanTemplate(raw)
  128              guard s.count >= 10 else { return nil }
  129              return s
  130          }
  131          return Found(texts: ((json["texts"] as? [Any]) ?? []).compactMap(clean),
  132                       linkedinNote: clean(json["linkedinNote"]),
  133                       linkedinMessage: clean(json["linkedinMessage"]),
  134                       opener: (json["opener"] as? String).map(cleanTemplate).flatMap { $0.count >= 3 ? $0 : nil },
  135                       voicemails: ((json["voicemails"] as? [Any]) ?? []).compactMap(clean))
  136      }
  137  }
  138  
```


## `mac/Sources/ClarityLiveCoach/ScriptOutlineCard.swift`

```swift
    1  import SwiftUI
    2  
    3  /// A fold-out card that just shows the campaign script. The part you're on is bold and highlighted.
    4  struct ScriptOutlineCard: View {
    5      @ObservedObject var coach: CoachModel
    6      /// The one page version of the script (redraws when Claude finishes writing it).
    7      @ObservedObject private var pages = ScriptPage.shared
    8      @AppStorage(PrefKey.scriptOutlineOpen) private var open = false
    9      /// The "View Full Script" sheet: every part, no fold.
   10      var fullOnly = false
   11      /// Saves an edited script (the card can't reach the call list store itself).
   12      var onScriptChange: ((String) -> Void)? = nil
   13      /// The part being edited on the card, and its text.
   14      @State private var editingID: String?
   15      @State private var draft = ""
   16  
   17      struct Part: Identifiable {
   18          let id: String
   19          let title: String
   20          let text: String
   21          /// The lines as written in the one-page script (before names are filled in), for editing.
   22          var raw: [String] = []
   23      }
   24  
   25      var parts: [Part] {
   26          let c = coach.campaign
   27          var list: [Part] = [
   28              Part(id: "opening", title: "Opening", text: c.opening),
   29              Part(id: "discovery", title: "Discovery", text: c.discovery),
   30              Part(id: "value", title: "Value", text: c.offer),
   31              Part(id: "closing", title: "Closing", text: c.closing),
   32              Part(id: "objection", title: "Objections", text: c.objections),
   33              Part(id: "exit", title: "When to stop", text: c.exit),
   34          ]
   35          // A whole script was pasted or generated: show its one page version (spoken lines only,
   36          // opener first), never the raw file with the tool's rules in it.
   37          if !c.pastedScript.trimmed.isEmpty {
   38              _ = pages.version
   39              let sections = pages.sections(for: c.pastedScript)
   40              if !sections.isEmpty {
   41                  // The person's real name and company go in the slots ([Name], [Firm]); no one loaded: "there".
   42                  return sections.map { section in
   43                      let lines = section.lines.map { line -> String in
   44                          let filled = coach.fillTags(line, for: coach.calling)
   45                          return filled.hasPrefix("there, ") ? "Hi " + filled : filled
   46                      }
   47                      return Part(id: Self.stageID(for: section.title), title: section.title, text: lines.joined(separator: "\n"),
   48                                  raw: section.lines)
   49                  }
   50              }
   51              list = list.filter { !$0.text.trimmed.isEmpty }
   52              if list.isEmpty {
   53                  let note = pages.isWriting(c.pastedScript)
   54                      ? "Making your one page script. It takes a few seconds."
   55                      : "Your one page script isn't ready yet. Check your keys in Set up, then open this again."
   56                  return [Part(id: "script", title: "Your script", text: note)]
   57              }
   58              return list
   59          }
   60          return list.filter { !$0.text.trimmed.isEmpty }
   61      }
   62  
   63      /// Which call stage a section of the one page script belongs to (for the highlight).
   64      private static func stageID(for title: String) -> String {
   65          let t = title.uppercased()
   66          if t.contains("OPENER") || t.contains("GATEKEEPER") || t.contains("VOICEMAIL") { return t.contains("OPENER") ? "opening" : "other-" + t }
   67          if t.contains("QUESTION") { return "discovery" }
   68          if t.contains("WHY") { return "value" }
   69          if t.contains("ASK") || t.contains("CLOSE") { return t.contains("ASK") ? "closing" : "other-" + t }
   70          if t.contains("IF THEY SAY") { return "objection" }
   71          return "other-" + t
   72      }
   73  
   74      /// Which part the call is on right now.
   75      var currentID: String {
   76          if coach.status == .ready { return "opening" }
   77          let stage = coach.suggestion.stage.lowercased()
   78          let theySpoke = coach.turns.contains { $0.speaker == .prospect }
   79          if stage.contains("objection") { return "objection" }
   80          if stage.contains("goal") || stage.contains("clos") || stage.contains("ask") || stage.contains("book") { return "closing" }
   81          if stage.contains("discover") || stage.contains("question") { return "discovery" }
   82          if stage.contains("value") || stage.contains("reason") || stage.contains("why") || stage.contains("problem") { return "value" }
   83          if stage.contains("exit") { return "exit" }
   84          // Still on the opener, but they answered it: the next thing to say is why you're calling.
   85          if (stage.contains("opener") || stage.isEmpty), theySpoke, !coach.sawVoicemail, !coach.screenerActive { return "value" }
   86          return "opening"
   87      }
   88  
   89      /// The Edit menu in the header (switch, edit or write scripts). Supplied by the coach.
   90      var editMenu: AnyView? = nil
   91      /// Long scripts show the first few parts until Show more.
   92      @State private var showAll = false
   93      private static let firstParts = 4
   94  
   95      var body: some View {
   96          // The opener already shows big on the coach card, so the fold-out skips it (the full view keeps it).
   97          let all = fullOnly ? parts : parts.filter { $0.id != "opening" }
   98          let shown = (fullOnly || showAll) ? all : Array(all.prefix(Self.firstParts))
   99          VStack(alignment: .leading, spacing: 12) {
  100              if !fullOnly {
  101                  HStack(spacing: 8) {
  102                      // Chevron + title: one click target that folds the card.
  103                      Button { open.toggle() } label: {
  104                          HStack(spacing: 8) {
  105                              Image(systemName: open ? "chevron.down" : "chevron.right").font(CardStyle.chevron).foregroundStyle(Brand.subtext)
  106                              Image(systemName: "doc.text").font(CardStyle.icon).foregroundStyle(Brand.blue)
  107                              Text("My Script").font(CardStyle.title)
  108                          }
  109                          .foregroundStyle(Brand.text)
  110                          .contentShape(Rectangle())
  111                      }
  112                      .buttonStyle(.plain)
  113                      Spacer(minLength: 0)
  114                      // Edit: its own click target, never folds the card.
  115                      if let editMenu { editMenu }
  116                  }
  117              }
  118              if open || fullOnly {
  119                  ForEach(shown) { part in
  120                      if part.id == "opening" {
  121                          // The opener: said word for word, so it stands out.
  122                          VStack(alignment: .leading, spacing: 6) {
  123                              HStack(spacing: 8) {
  124                                  Text(part.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Brand.subtext)
  125                                  Text("EXACT").font(.caption2.weight(.bold)).foregroundStyle(Color.green)
  126                                      .padding(.horizontal, 6).padding(.vertical, 2)
  127                                      .overlay(Capsule().stroke(Color.green.opacity(0.6), lineWidth: 1))
  128                              }
  129                              editable(part) {
  130                                  Text(part.text.trimmed).font(.body.weight(.bold)).foregroundStyle(Brand.text)
  131                                      .fixedSize(horizontal: false, vertical: true)
  132                              }
  133                          }
  134                          .padding(12)
  135                          .frame(maxWidth: .infinity, alignment: .leading)
  136                          .background(Brand.quiet, in: RoundedRectangle(cornerRadius: 10))
  137                          .overlay(RoundedRectangle(cornerRadius: 10).stroke(part.id == currentID ? Brand.blue : Color.clear, lineWidth: 1))
  138                      } else {
  139                          let here = part.id == currentID
  140                          HStack(alignment: .top, spacing: 12) {
  141                              Image(systemName: Self.icon(for: part.id)).font(.title3)
  142                                  .foregroundStyle(here ? Brand.blue : Brand.subtext).frame(width: 24)
  143                              VStack(alignment: .leading, spacing: 3) {
  144                                  Text(part.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(here ? Brand.text : Brand.subtext)
  145                                  editable(part) {
  146                                      Text(part.text.trimmed).font(.callout.weight(here ? .semibold : .regular))
  147                                          .foregroundStyle(here ? Brand.text : Brand.subtext)
  148                                          .fixedSize(horizontal: false, vertical: true)
  149                                  }
  150                              }
  151                          }
  152                          .padding(.horizontal, 4)
  153                          .frame(maxWidth: .infinity, alignment: .leading)
  154                      }
  155                  }
  156                  if !fullOnly, all.count > Self.firstParts {
  157                      Button { showAll.toggle() } label: {
  158                          HStack(spacing: 6) {
  159                              Text(showAll ? "Show less" : "Show more")
  160                              Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.caption)
  161                          }
  162                          .font(.callout).foregroundStyle(Brand.text)
  163                          .frame(maxWidth: .infinity).padding(.vertical, 8)
  164                          .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.controlEdge, lineWidth: 1))
  165                          .contentShape(Rectangle())
  166                      }
  167                      .buttonStyle(.plain)
  168                  }
  169                  if all.isEmpty {
  170                      Text("No script yet. Click Edit, then Write a new script with Claude.").font(.caption).foregroundStyle(Brand.muted)
  171                  }
  172              }
  173          }
  174          .padding(CardStyle.padding)
  175          .frame(maxWidth: .infinity, alignment: .leading)
  176          .brandCard(radius: CardStyle.radius)
  177      }
  178  
  179      /// A part's text; click it to edit in place (only for a written script, between calls).
  180      @ViewBuilder private func editable<V: View>(_ part: Part, @ViewBuilder text: () -> V) -> some View {
  181          if editingID == part.id + part.title {
  182              VStack(alignment: .leading, spacing: 6) {
  183                  TextEditor(text: $draft)
  184                      .font(.callout)
  185                      .scrollContentBackground(.hidden)
  186                      .padding(6)
  187                      .frame(minHeight: 70)
  188                      .background(Brand.navy.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
  189                      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.blue, lineWidth: 1))
  190                  HStack(spacing: 10) {
  191                      Button("Save") { save(part) }.buttonStyle(BrandPrimaryButton())
  192                      Button("Cancel") { editingID = nil }.buttonStyle(.brandLink)
  193                      Text("One line per row. The coach uses your wording.").font(.caption).foregroundStyle(Brand.muted)
  194                  }
  195              }
  196          } else if canEdit(part) {
  197              text()
  198                  .contentShape(Rectangle())
  199                  .onTapGesture { draft = part.raw.joined(separator: "\n"); editingID = part.id + part.title }
  200                  .help("Click to edit these lines")
  201          } else {
  202              text()
  203          }
  204      }
  205  
  206      private func canEdit(_ part: Part) -> Bool {
  207          onScriptChange != nil && !part.raw.isEmpty && coach.status == .ready
  208      }
  209  
  210      private func save(_ part: Part) {
  211          let lines = draft.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  212          editingID = nil
  213          guard !lines.isEmpty, lines != part.raw else { return }
  214          let updated = pages.edit(script: coach.campaign.pastedScript, title: part.title, oldLines: part.raw, newLines: lines)
  215          onScriptChange?(updated)
  216      }
  217  
  218      /// An icon for each kind of script part.
  219      private static func icon(for id: String) -> String {
  220          switch id {
  221          case "value": return "scope"
  222          case "discovery": return "questionmark.circle"
  223          case "closing": return "calendar"
  224          case "objection": return "bubble.left.and.exclamationmark.bubble.right"
  225          case "exit": return "hand.raised"
  226          default: return "text.alignleft"
  227          }
  228      }
  229  }
  230  
  231  /// The five steps of every call, for the guided script: Intro, Qualify, Pitch, Close, Confirm.
  232  enum ScriptStep: Int, CaseIterable, Identifiable {
  233      case intro, qualify, pitch, close, confirm
  234      var id: Int { rawValue }
  235      var title: String { ["Intro", "Qualify", "Pitch", "Close", "Confirm"][rawValue] }
  236  
  237      /// Which step a script part belongs to.
  238      static func of(partID id: String, title: String) -> ScriptStep {
  239          switch id {
  240          case "opening": return .intro
  241          case "discovery": return .qualify
  242          case "value": return .pitch
  243          case "closing", "objection": return .close
  244          case "exit": return .confirm
  245          default:
  246              let t = title.uppercased()
  247              if t.contains("CONFIRM") || t.contains("AFTER") || t.contains("BOOKED") || t.contains("WRAP") { return .confirm }
  248              if t.contains("CLOSE") { return .close }
  249              return .intro // gatekeeper, voicemail and other openers
  250          }
  251      }
  252  }
  253  
  254  /// Inside the live coach card: where the call is (Intro to Confirm), Previous / Next to read any step
  255  /// of the script, and View Full Script. Reading only: editing is the Edit Script button at the top.
  256  struct ScriptStepper: View {
  257      @ObservedObject var coach: CoachModel
  258      @ObservedObject private var pages = ScriptPage.shared
  259      /// A step the rep is reading (nil = follow the call).
  260      @Binding var browsing: ScriptStep?
  261      @Binding var showFull: Bool
  262  
  263      var body: some View {
  264          let outline = ScriptOutlineCard(coach: coach)
  265          let parts = outline.parts
  266          let live = ScriptStep.of(partID: outline.currentID, title: "")
  267          let shown = browsing ?? live
  268          VStack(alignment: .leading, spacing: 8) {
  269              HStack(spacing: 4) {
  270                  ForEach(ScriptStep.allCases) { step in
  271                      let on = step == shown
  272                      Button { browsing = step == live ? nil : step } label: {
  273                          Text(step.title)
  274                              .font(.caption.weight(on ? .bold : .medium))
  275                              .foregroundStyle(on ? Brand.text : Brand.muted)
  276                              .padding(.horizontal, 8).padding(.vertical, 3)
  277                              .background(on ? Brand.blue.opacity(0.35) : Color.clear, in: Capsule())
  278                              .overlay(Capsule().stroke(step == live ? Brand.blue : Color.clear, lineWidth: 1))
  279                      }
  280                      .buttonStyle(.plain)
  281                      .help(step == live ? "The step the call is on" : "Read the \(step.title) part of your script")
  282                      if step != .confirm {
  283                          Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Brand.muted)
  284                      }
  285                  }
  286                  Spacer(minLength: 0)
  287              }
  288              if let b = browsing {
  289                  let text = parts.filter { ScriptStep.of(partID: $0.id, title: $0.title) == b }
  290                      .map { $0.text.trimmed }.filter { !$0.isEmpty }.joined(separator: "\n\n")
  291                  Text(text.isEmpty ? "Your script has nothing for \(b.title)." : text)
  292                      .font(.callout).foregroundStyle(Brand.subtext)
  293                      .fixedSize(horizontal: false, vertical: true)
  294                      .padding(8)
  295                      .frame(maxWidth: .infinity, alignment: .leading)
  296                      .background(Brand.navy.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  297              }
  298              HStack(spacing: 10) {
  299                  Button { move(-1, from: shown, live: live) } label: { Label("Previous", systemImage: "chevron.left") }
  300                      .buttonStyle(.brandLink).font(.caption)
  301                      .disabled(shown == .intro)
  302                  Button { move(1, from: shown, live: live) } label: { Label("Next", systemImage: "chevron.right") }
  303                      .buttonStyle(.brandLink).font(.caption)
  304                      .disabled(shown == .confirm)
  305                  if browsing != nil {
  306                      Button("Back to the call") { browsing = nil }.buttonStyle(.brandLink).font(.caption.weight(.semibold))
  307                  }
  308                  Spacer(minLength: 0)
  309                  Button("View Full Script") { showFull = true }.buttonStyle(.brandLink).font(.caption)
  310              }
  311          }
  312          .onChange(of: coach.status) { browsing = nil }
  313      }
  314  
  315      private func move(_ by: Int, from: ScriptStep, live: ScriptStep) {
  316          guard let next = ScriptStep(rawValue: from.rawValue + by) else { return }
  317          browsing = next == live ? nil : next
  318      }
  319  }
  320  
```


## `mac/Sources/ClarityLiveCoach/Screener.swift`

```swift
    1  import Foundation
    2  
    3  /// Spots automated call screeners (iPhone, Google Call Screen, carrier screening) and
    4  /// "who's calling?" gatekeepers from the prospect's words, instantly and without Claude.
    5  enum Screener {
    6      private static let phrases = [
    7          "screening service", "call screen", "screening this call", "being screened", "screening calls",
    8          "person you're trying to reach",
    9          "say your name", "state your name", "record your name", "speak your name",
   10          "your name and why", "your name and the reason", "reason for your call", "reason for calling",
   11          "why you're calling", "why you are calling", "what you're calling about", "what this call is about",
   12          "google assistant", "stay on the line", "before i connect you", "see if this person is available",
   13          "may i ask who's calling", "may i ask who is calling", "who's calling please", "who is calling please",
   14          "may i tell them who's calling", "and your name",
   15      ]
   16  
   17      static func detects(_ text: String) -> Bool {
   18          let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
   19          return phrases.contains { t.contains($0) }
   20      }
   21  
   22      /// "This is Mason calling for Jane."
   23      static func line(calling: String?) -> String {
   24          let rep = Prefs.repName
   25          return "This is \(rep.isEmpty ? "[your name]" : rep) calling for \(firstName(calling) ?? "[their name]")."
   26      }
   27  
   28      /// The full name from a record like: Lead "Jane Doe" -> Jane Doe. Any record type.
   29      static func fullName(_ calling: String?) -> String? {
   30          guard let calling, let open = calling.firstIndex(of: "\"") else { return nil }
   31          let rest = calling[calling.index(after: open)...]
   32          let inside = rest.lastIndex(of: "\"").map { rest[..<$0] } ?? rest
   33          let name = inside.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
   34          return name.isEmpty ? nil : name
   35      }
   36  
   37      /// First name from a record like: Lead "Jane Doe". People only, not companies.
   38      static func firstName(_ calling: String?) -> String? {
   39          guard let calling,
   40                ["Lead", "Contact", "Person Account"].contains(where: { calling.hasPrefix($0) }),
   41                let open = calling.firstIndex(of: "\""),
   42                let name = calling[calling.index(after: open)...].split(separator: " ").first else { return nil }
   43          let first = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
   44          // "Unknown" is a placeholder, not a name: callers fall back to "there".
   45          return first.isEmpty || Salesforce.isPlaceholderName(first) ? nil : first
   46      }
   47  }
   48  
   49  /// Spots voicemail greetings and full mailboxes from the prospect's words, instantly.
   50  /// Strong phrases count any time. Early phrases ("you've reached", "not available") only count
   51  /// at the start of a call before the rep has spoken, when it can't be a gatekeeper answering a question.
   52  enum Voicemail {
   53      private static let strong = [
   54          "leave a message", "leave your message", "leave me a message", "leave a voicemail", "leave a brief message",
   55          "leave your name", "message after", "after the tone", "after the beep", "at the tone", "at the beep",
   56          "voicemail", "voice mail", "mailbox", "record your message", "please leave", "can't take your call",
   57          "cannot take your call", "can not take your call", "not available to take your call", "can't come to the phone",
   58          "cannot come to the phone", "get back to you as soon as", "return your call", "forwarded to an automated",
   59          "automated voice", "voice messaging", "is not available. please", "sorry i missed your call",
   60          "sorry i can't answer", "sorry i cannot answer", "missed your call",
   61          // Straight to voicemail and carrier recordings
   62          "record your message", "please record", "when you have finished recording", "when you're finished recording",
   63          "when you are finished recording", "finished recording", "press pound", "hang up or press", "for more options",
   64          "at the sound of the tone", "after the signal", "voice mailbox", "has a mailbox", "has been forwarded",
   65          "your call has been forwarded", "forwarded to voicemail", "is not accepting calls", "is not available to take",
   66          "this is the voicemail", "reached the voicemail", "reached the mailbox", "leave your number",
   67          "leave a detailed message", "leave your contact", "leave a short message", "leave a quick message",
   68          "i'll call you back", "i will call you back", "i'll get back to you", "i will get back to you",
   69          "call you back as soon", "get back to you shortly", "sorry i missed you", "sorry we missed your call",
   70          "can't take your call", "unable to take your call", "google subscriber", "the subscriber you",
   71          "the party you are trying", "the customer you are calling", "please try your call again",
   72          "please try again later", "send a numeric page", "to page this person",
   73      ]
   74      private static let early = [
   75          "you've reached", "you have reached", "not available", "unavailable", "unable to answer", "unable to take",
   76          "can't get to the phone", "can't answer", "away from my desk", "away from the phone", "out of the office",
   77          "subscriber", "wireless customer", "the person you are trying", "the person you're trying",
   78          "the number you have dialed", "is not reachable",
   79          "i'm not available right now", "i am not available right now", "not available right now",
   80      ]
   81      private static let fullPhrases = [
   82          "mailbox is full", "mailbox full", "cannot accept any messages", "not accepting messages",
   83          "has not been set up", "hasn't been set up", "not set up yet",
   84      ]
   85  
   86      /// - Parameter earlyInCall: true in the first seconds after pickup, before the rep has said anything.
   87      static func detects(_ text: String, earlyInCall: Bool) -> Bool {
   88          contains(text, strong) || mailboxFull(text) || (earlyInCall && contains(text, early))
   89      }
   90  
   91      static func mailboxFull(_ text: String) -> Bool { contains(text, fullPhrases) }
   92  
   93      /// Words only a recording says, never a person who picked up. Used to hang up a 1st-try
   94      /// voicemail by itself. Kept short on purpose: anything a live person might say is left out.
   95      private static let certainPhrases = [
   96          "after the tone", "after the beep", "at the tone", "at the beep", "at the sound of the tone",
   97          "after the signal", "record your message", "please record", "when you have finished recording",
   98          "when you're finished recording", "when you are finished recording", "voice mailbox", "forwarded to voicemail", "forwarded to an automated",
   99          "your call has been forwarded", "reached the voicemail", "this is the voicemail", "reached the mailbox",
  100          "google subscriber", "the subscriber you", "the party you are trying", "the customer you are calling",
  101          "send a numeric page", "to page this person",
  102      ]
  103  
  104      /// The beep is coming: only a mailbox says these (a phone menu doesn't).
  105      private static let recordingPhrases = [
  106          "after the tone", "after the beep", "at the tone", "at the beep", "at the sound of the tone",
  107          "after the signal", "record your message", "please record", "finished recording",
  108      ]
  109      static func recordingPrompt(_ text: String) -> Bool { contains(text, recordingPhrases) }
  110  
  111      /// True only when it's surely a recording (see `certainPhrases`), or the mailbox is full.
  112      static func certain(_ text: String) -> Bool {
  113          contains(text, certainPhrases) || mailboxFull(text) || numberCantTakeCall(text)
  114      }
  115  
  116      /// The carrier's "The telephone number 205 441 3049 can't take your call now." Fuzzy: a number
  117      /// (digits are dropped, so spoken or written both work), then within a few words "can't take your call".
  118      static func numberCantTakeCall(_ text: String) -> Bool {
  119          let t = text.lowercased()
  120              .replacingOccurrences(of: "\u{2019}", with: "'")
  121              .replacingOccurrences(of: "'", with: "")
  122              .replacingOccurrences(of: #"[^a-z ]+"#, with: " ", options: .regularExpression)
  123              .replacingOccurrences(of: #"\b(zero|oh|one|two|three|four|five|six|seven|eight|nine)\b"#, with: " ", options: .regularExpression)
  124          let pattern = #"\b(telephone|phone|number|caller|subscriber)\b(\s+\w+){0,6}?\s+"#
  125              + #"(cant|can not|cannot|unable to|isnt able to|is not able to|not able to)\s+(take|answer|accept)\s+(your|the|this)?\s*call"#
  126          return t.range(of: pattern, options: .regularExpression) != nil
  127      }
  128  
  129      /// Sure enough it's a recording to hang up now, without waiting for "after the beep" at the end
  130      /// of the greeting. Returns why (for the log), or nil. The rep hasn't spoken yet (caller checks).
  131      /// - Any time: words only a machine says (`certain`).
  132      /// - Early in the call, nobody screening: a voicemail phrase ("you've reached Jane's voicemail",
  133      ///   "can't take your call", "leave a message"), or 18+ words with no pause for a reply,
  134      ///   or "you've reached" / "not available" plus 12+ words.
  135      static func hangUpReason(_ recent: String, firstWords: String, earlyInCall: Bool) -> String? {
  136          if certain(recent) { return "beep words" }
  137          guard earlyInCall, !Screener.detects(firstWords), !Screener.detects(recent) else { return nil }
  138          if contains(recent, strong) { return "voicemail words" }
  139          if longGreeting(firstWords, earlyInCall: true) { return "long greeting" }
  140          if contains(recent, early), firstWords.split(separator: " ").count >= 12 { return "greeting words" }
  141          return nil
  142      }
  143  
  144      /// After a call screener (Google, iPhone): the screener says the person won't take it.
  145      /// Fuzzy, since the words vary and transcripts drop or mangle some:
  146      /// "I'm sorry, this person is not available", "the person you're calling isn't available right now",
  147      /// "sorry, they can't take your call", "this person's unavailable", "they declined".
  148      /// A person (or "they") followed within a few words by a "can't take it" phrase.
  149      static func unavailableAfterScreen(_ text: String) -> Bool {
  150          let t = text.lowercased()
  151              .replacingOccurrences(of: "\u{2019}", with: "'")
  152              .replacingOccurrences(of: "'", with: "")
  153              .replacingOccurrences(of: #"[^a-z ]+"#, with: " ", options: .regularExpression)
  154          let pattern = #"\b(person|persons|party|they|theyre|user|customer|caller)\b(\s+\w+){0,6}?\s+"#
  155              + #"(not available|unavailable|isnt available|not able to (take|answer|come)|cant (take|answer|come|get)|"#
  156              + #"cannot (take|answer|come|get)|unable to (take|answer|come)|not taking calls|declined|busy right now)"#
  157          return t.range(of: pattern, options: .regularExpression) != nil
  158      }
  159  
  160      /// Real people answer short ("Hello?", "This is Jane"). A recording talks on and on.
  161      /// 18+ words before the rep says anything, early in the call = a voicemail greeting.
  162      static func longGreeting(_ text: String, earlyInCall: Bool) -> Bool {
  163          earlyInCall && text.split(separator: " ").count >= 18
  164      }
  165  
  166      private static func contains(_ text: String, _ list: [String]) -> Bool {
  167          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  168          return list.contains { t.contains($0) }
  169      }
  170  }
  171  
  172  
  173  /// Spots carrier messages for numbers that don't work, so the app skips them instead of
  174  /// leaving a voicemail or offering a redial.
  175  enum BadNumber {
  176      private static let phrases = [
  177          "not in service", "no longer in service", "is not in service", "been disconnected",
  178          "is disconnected", "not a working number", "is not working", "cannot be completed as dialed",
  179          "can not be completed as dialed", "could not be completed", "call cannot be completed",
  180          "check the number and dial again", "check the number and try again", "please check the number",
  181          "not a valid number", "invalid number", "number is invalid", "number you have dialed is not",
  182          "number you dialed is not", "has been changed", "temporarily out of service", "is not available for calls",
  183          "does not accept calls", "is restricted", "not accepting calls at this time",
  184          // "Can't receive calls" and other carrier refusals
  185          "cannot receive calls", "can't receive calls", "can not receive calls", "unable to receive calls",
  186          "not able to receive calls", "is not able to receive", "cannot accept calls", "can't accept calls",
  187          "is not accepting calls", "not accepting incoming calls", "calling restrictions", "has restricted",
  188          "has been restricted", "no longer available", "cannot be reached", "can't be reached",
  189          "is not reachable at this", "call cannot be completed at this time", "your call cannot be completed",
  190          "your call could not be completed", "not been completed", "has been suspended", "is suspended",
  191          "number has been disconnected", "is no longer a working", "not a valid phone number",
  192          "does not exist", "doesn't exist", "do not exist", "try your call again",
  193          "please hang up and try again", "hang up and dial again", "is not assigned",
  194          "not been assigned", "unassigned number",
  195      ]
  196  
  197      static func detects(_ text: String) -> Bool {
  198          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  199          return phrases.contains { t.contains($0) }
  200      }
  201  }
  202  
  203  
  204  /// Spots an automated phone menu ("press 1 for sales", "dial by name"). The rep doesn't work
  205  /// those: the app hangs up and takes the person off the list.
  206  enum PhoneTree {
  207      /// One of these is enough: only a phone menu says them.
  208      private static let strong = [
  209          "menu options have changed", "listen carefully as our", "dial by name", "company directory",
  210          "your party's extension", "party's extension", "if you know the extension", "if you know your party",
  211          "para español", "para espanol", "main menu", "make a selection", "please select from the following",
  212          "say or press", "press or say", "to repeat these options", "for all other inquiries", "for all other calls",
  213      ]
  214      /// Two of these together, one of them "press ...": "press 1 for sales, press 2 for billing".
  215      private static let weak = [
  216          "press 1", "press one", "press 2", "press two", "press 3", "press three", "press 4", "press four",
  217          "press 9", "press nine", "press 0", "press zero", "for sales", "for billing", "for customer service",
  218          "for support", "for accounts", "to speak with an operator", "to speak to an operator", "operator",
  219          "extension", "our hours are", "business hours",
  220      ]
  221  
  222      static func detects(_ text: String) -> Bool {
  223          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  224          if strong.contains(where: { t.contains($0) }) { return true }
  225          // Two menu phrases, and at least one is "press ..." (a live receptionist never says that).
  226          let hits = weak.filter { t.contains($0) }
  227          return hits.count >= 2 && hits.contains { $0.hasPrefix("press") }
  228      }
  229  }
  230  
```


## `mac/Sources/ClarityLiveCoach/CoachView.swift`

```swift
    1  import AppKit
    2  import CoachCore
    3  import AVFoundation
    4  import SwiftUI
    5  
    6  /// Decides which screen to show: audio check (first run), keys (once), then the coach.
    7  struct RootView: View {
    8      /// keys = upload the team keys file. manualKeys = type keys by hand (hidden, team lead only).
    9      enum Screen { case check, keys, manualKeys, coach }
   10  
   11      @EnvironmentObject var proof: ProofModel
   12      @EnvironmentObject var coach: CoachModel
   13      @AppStorage(PrefKey.audioCheckPassed) private var audioCheckPassed = false
   14      /// Left the keys screen without a keys file (it stays in Set up).
   15      @AppStorage("keysSkipped") private var keysSkipped = false
   16      /// Skipped on a first run: don't show the audio check again at every launch (Set up still lists it).
   17      @AppStorage(PrefKey.audioCheckSkipped) private var audioCheckSkipped = false
   18      private let appPhone = true // always: the Aircall phone is inside the coach
   19      @ObservedObject private var phone = AircallPhone.shared
   20      @State private var screen: Screen?
   21  
   22      var body: some View {
   23          Group {
   24              switch screen ?? firstScreen {
   25              case .check:
   26                  // The Aircall phone sits on the right here too, so the test call comes from it.
   27                  HStack(alignment: .top, spacing: 0) {
   28                      AudioCheckView(onFinish: {
   29                          audioCheckPassed = true
   30                          screen = .coach
   31                      }, onCancel: audioCheckPassed && hasKeys ? { screen = .coach } : nil,
   32                         // Never trap a new rep here: they can finish it later from Set up.
   33                         onSkip: { audioCheckSkipped = true; proof.testAgain(); screen = .coach })
   34                      .frame(minWidth: 380, maxWidth: .infinity)
   35                      .onAppear { proof.onAppear() }
   36                      if appPhone { AircallPhoneSide() }
   37                  }
   38              case .keys:
   39                  // Reps never type keys: they upload the keys file their team lead sends.
   40                  VStack(spacing: 0) {
   41                      Spacer(minLength: 0)
   42                      TeamKeysView(mode: .importKeys, firstRun: true, onClose: {
   43                          keysSkipped = true
   44                          screen = (!audioCheckPassed && !audioCheckSkipped) ? .check : .coach // keys first, then the audio check
   45                      })
   46                      Spacer(minLength: 0)
   47                  }
   48              case .manualKeys:
   49                  KeysView(onSave: { screen = .coach }, onCancel: { screen = .coach })
   50              case .coach:
   51                  CoachView(
   52                      onAudioCheck: { proof.testAgain(); screen = .check },
   53                      onKeys: { screen = .manualKeys }
   54                  )
   55              }
   56          }
   57          // The window opens at the coach's size (taller than wide, with the Aircall phone on the right
   58          // when it's showing) and can be dragged or zoomed bigger. It never gets smaller than this width.
   59          .frame(minWidth: minWindowWidth, idealWidth: minWindowWidth, maxWidth: .infinity,
   60                 minHeight: 440, idealHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 72, maxHeight: .infinity)
   61          // Show or hide the phone: the window grows or shrinks by the phone's width.
   62          .onChange(of: showPhone) { _, shown in
   63              let change = AircallPhoneSide.width - 1
   64              DispatchQueue.main.async {
   65                  guard let window = NSApp.windows.first(where: { $0.title == "Clarity Live Coach" && $0.isVisible }) else { return }
   66                  var frame = window.frame
   67                  frame.size.width = max(381, frame.size.width + (shown ? change : -change))
   68                  if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX {
   69                      frame.origin.x = max(screen.minX, screen.maxX - frame.width) // keep it on the screen
   70                  }
   71                  window.setFrame(frame, display: true, animate: true)
   72              }
   73          }
   74          .brandWindow()
   75      }
   76  
   77      /// The least width the coach needs: the column, plus the Aircall phone when it's showing.
   78      private var minWindowWidth: CGFloat { 380 + (showPhone ? AircallPhoneSide.width : 1) }
   79  
   80      private var showPhone: Bool {
   81          let current = screen ?? firstScreen
   82          return appPhone && phone.shown && (current == .coach || current == .check)
   83      }
   84  
   85      private var hasKeys: Bool { Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil }
   86      private var firstScreen: Screen {
   87          if !hasKeys && !keysSkipped { return .keys }
   88          if !audioCheckPassed && !audioCheckSkipped { return .check }
   89          return .coach
   90      }
   91  }
   92  
   93  // MARK: - Keys
   94  
   95  struct KeysView: View {
   96      var onSave: () -> Void
   97      /// Set when the keys are already saved: a way back without changing them.
   98      var onCancel: (() -> Void)? = nil
   99      @State private var deepgram = Keychain.read(.deepgram) ?? ""
  100      @State private var anthropic = Keychain.read(.anthropic) ?? ""
  101      @State private var error: String?
  102  
  103      var body: some View {
  104          VStack(spacing: 18) {
  105              Image(systemName: "key.horizontal")
  106                  .font(.system(size: 40))
  107                  .foregroundStyle(Brand.blue)
  108              VStack(spacing: 6) {
  109                  Text("Connect the coach").font(.title2.weight(.semibold))
  110                  Text("Paste two keys, one time. They're stored safely in your Mac's Keychain.")
  111                      .foregroundStyle(.secondary)
  112                      .multilineTextAlignment(.center)
  113              }
  114              keyField(
  115                  title: "Deepgram key",
  116                  hint: "Turns the call into live text.",
  117                  link: "https://console.deepgram.com",
  118                  text: $deepgram
  119              )
  120              keyField(
  121                  title: "Anthropic key",
  122                  hint: "Lets Claude write your next line. Starts with sk-ant-",
  123                  link: "https://console.anthropic.com/settings/keys",
  124                  text: $anthropic
  125              )
  126              if let guide = SetupView.guides["keys"] {
  127                  DisclosureGroup("Step by step: how to get both keys") {
  128                      ScrollView {
  129                          VStack(alignment: .leading, spacing: 6) {
  130                              ForEach(Array(guide.steps.enumerated()), id: \.offset) { _, line in
  131                                  Text(line).font(.callout)
  132                                      .fontWeight(line.hasSuffix(":") ? .semibold : .regular)
  133                                      .fixedSize(horizontal: false, vertical: true)
  134                              }
  135                          }
  136                          .frame(maxWidth: .infinity, alignment: .leading)
  137                      }
  138                      .frame(maxHeight: 260)
  139                  }
  140                  .font(.callout)
  141              }
  142              if let error {
  143                  Text(error).font(.callout).foregroundStyle(.red)
  144              }
  145              if let onCancel {
  146                  Button("Cancel") { onCancel() }
  147              }
  148              Button("Save and continue") { save() }
  149                  .buttonStyle(.borderedProminent)
  150                  .controlSize(.large)
  151                  .disabled(deepgram.trimmed.isEmpty || anthropic.trimmed.isEmpty)
  152          }
  153          .padding(24)
  154      }
  155  
  156      private func keyField(title: String, hint: String, link: String, text: Binding<String>) -> some View {
  157          VStack(alignment: .leading, spacing: 6) {
  158              HStack {
  159                  Text(title).font(.headline)
  160                  Spacer()
  161                  Link("Get a key", destination: URL(string: link)!).font(.callout)
  162              }
  163              SecureField("Paste here", text: text)
  164                  .textFieldStyle(.roundedBorder)
  165              Text(hint).font(.caption).foregroundStyle(.secondary)
  166          }
  167      }
  168  
  169      private func save() {
  170          guard anthropic.trimmed.hasPrefix("sk-ant-") else {
  171              error = "That Anthropic key doesn't look right. It should start with sk-ant-"
  172              return
  173          }
  174          guard Keychain.save(deepgram.trimmed, for: .deepgram), Keychain.save(anthropic.trimmed, for: .anthropic) else {
  175              error = "Couldn't save to the Keychain. Try again."
  176              return
  177          }
  178          onSave()
  179      }
  180  }
  181  
  182  extension String {
  183      var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
  184  }
  185  
  186  // MARK: - Coach
  187  
  188  /// The live coach. Built to be glanced at: the line to say is the hero,
  189  /// status and stage are readable without reading a sentence, and navigation never moves.
  190  struct CoachView: View {
  191      var onAudioCheck: () -> Void
  192      var onKeys: () -> Void
  193      @EnvironmentObject var coach: CoachModel
  194      @EnvironmentObject var campaigns: CampaignStore
  195      @Environment(\.openWindow) private var openWindow
  196      @State private var showTranscript = false
  197      /// THINK mode: the rep asked to see the full SAY line for this suggestion (resets on the next one).
  198      @State private var showFullLine = false
  199      /// Redraws when Salesforce or Aircall connects or disconnects.
  200      @ObservedObject private var connections = Connections.shared
  201      @State private var showHelp = false
  202      @State private var showAircall = false
  203      @State private var showSetup = false
  204      @State private var showSettings = false
  205      @State private var showDropSetup = false
  206      @AppStorage(PrefKey.dropNudgeDismissed) private var dropNudgeDismissed = false
  207      @State private var showWhy = false
  208      @State private var showScriptMaker = false
  209      /// The live coach card is folded (like My script, This block and My activity).
  210      @AppStorage("liveCardOpen") private var liveCardOpen = true
  211      /// A script step the rep is reading with Previous / Next (nil = follow the call).
  212      @State private var browsingStep: ScriptStep?
  213      @State private var showFullScript = false
  214      @State private var editingOpener = false
  215      @State private var openerDraft = ""
  216      /// The first-run tour: 0 = welcome card, 1...n = steps, nil = hidden.
  217      @State private var tourStep: Int?
  218      @AppStorage(PrefKey.tourSeen) private var tourSeen = false
  219      @StateObject private var updater = Updater()
  220      @AppStorage(PrefKey.repName) private var repName = ""
  221      private let showTouchpoints = true // always on
  222      @AppStorage(PrefKey.nextDials) private var nextDials = true
  223      @State private var listViewCache: [Salesforce.ListView] = []
  224      /// Off (default): the essential view: the person, the line, the follow-up and the buttons.
  225      /// On: everything (script, numbers, rings, transcript, stage bar).
  226      @AppStorage("showMore") private var showMore = false
  227      /// The longest a running countdown started at, for the bar's length.
  228      @State private var countdownMax = 1
  229      private var showAll: Bool { showMore || tourStep != nil } // the tour points at everything
  230      /// "Starting TAX FIRMS in 4": the next list starts by itself when this one is done.
  231      @State private var nextListIn: Int?
  232      @State private var nextListTask: Task<Void, Never>?
  233      /// Lists started by themselves in a row with no call made (stops a loop when every list is done).
  234      @State private var listHops = 0
  235      private let appPhone = true // always: the Aircall phone is inside the coach
  236  
  237      // One visual system: blue = actions, green = listening, amber = real warnings.
  238      private let margin: CGFloat = 16
  239      private let gap: CGFloat = 12
  240      private let listening = Color.green
  241      private let warning = Color.orange
  242  
  243      var body: some View {
  244          HStack(alignment: .top, spacing: 0) {
  245              // As wide and tall as the window: the middle scrolls, nothing gets cut off.
  246              coachColumn.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
  247                  .overlayPreferenceValue(TourSpotKey.self) { spots in
  248                      TourOverlay(step: $tourStep, spots: spots) { tourSeen = true }
  249                  }
  250              // The Aircall phone sits to the right. Hidden = 1 point wide, but still running.
  251              if appPhone { AircallPhoneSide() }
  252          }
  253          .frame(maxHeight: .infinity)
  254      }
  255  
  256      private var coachColumn: some View {
  257          VStack(alignment: .leading, spacing: gap) {
  258              topBar
  259              nowBar
  260              readyCheck
  261              dropNudge
  262              // The middle scrolls if it's ever taller than the screen; the top bar and the buttons stay put.
  263              ScrollViewReader { scroller in
  264              ScrollView(.vertical, showsIndicators: false) {
  265              VStack(alignment: .leading, spacing: gap) {
  266              // The Chrome list is the default. This header only shows if a Salesforce list was picked in Settings and tools.
  267              if Salesforce.isConnected && coach.leads.selected != nil { leadHeader }
  268              if coach.status != .ready {
  269                  StageBar(steps: CoachModel.journey, current: coach.journeyStep, active: true)
  270              }
  271              // Show less (between calls): no line card or script, just the call block and your numbers.
  272              // During a call the line always shows: it's what to say.
  273              if prospect != nil { prospectCard }
  274              if showAll || coach.status != .ready { scriptCard.tourScrollSpot(.line) }
  275              if showAll { ScriptOutlineCard(coach: coach, onScriptChange: { text in
  276                  var c = campaigns.selected
  277                  c.pastedScript = text
  278                  campaigns.save(c) // the coach picks up the new script (onChange of the selected call list)
  279              }, editMenu: AnyView(scriptEditMenu)).tourScrollSpot(.script) }
  280              if liveCardOpen && coach.status != .ready { belowCard }
  281              // Essential view: only between calls (during a call it's just the line).
  282              if coach.statusRecordID != nil, coach.status == .ready {
  283                  RelationshipCard(coach: coach)
  284                      .id(coach.statusRecordID) // a fresh card per person: nothing picked carries over
  285                      .tourScrollSpot(.status)
  286              }
  287              if inTour && coach.followUp == nil {
  288                  // The tour points here before any voicemail: show a sample card so the spot isn't empty.
  289                  FollowUpCard(followUp: .constant(Optional(TourSample.followUp)), steps: TourSample.steps, canSend: true,
  290                               onSend: {}, onLinkedIn: {}, onLinkedInMessage: {}, onSetupAircall: {})
  291                      .allowsHitTesting(false)
  292                      .tourScrollSpot(.followUp)
  293              } else if coach.followUp != nil {
  294                  FollowUpCard(
  295                      followUp: $coach.followUp,
  296                      isLastPerson: coach.followUp?.key != nil && coach.followUp?.key != coach.statusRecordID,
  297                      steps: coach.todaySteps(for: coach.followUp?.key),
  298                      canSend: Aircall.isSetUp,
  299                      onSend: { coach.sendFollowUpText() },
  300                      onLinkedIn: { coach.openLinkedIn() },
  301                      onLinkedInMessage: { coach.openLinkedIn(message: true) },
  302                      onSetupAircall: { showAircall = true },
  303                      onProfile: { coach.openLinkedInProfile() }
  304                  )
  305                  .tourScrollSpot(.followUp)
  306              }
  307              if coach.status == .ready || coach.blockStartedAt != nil {
  308                  DailyGoalCard(touchpoints: coach.touchpoints, coach: coach, activeCampaigns: campaigns.activeCampaigns)
  309                      .tourScrollSpot(.goal)
  310              }
  311              if showTouchpoints && coach.status == .ready {
  312                  TouchpointsCard(touchpoints: coach.touchpoints, toCall: coach.leads.isActive ? coach.leads.summary : coach.callList.summary).tourScrollSpot(.numbers)
  313              }
  314              warnings
  315              }
  316              }
  317              .scrollBounceBehavior(.basedOnSize)
  318              // The tour: bring the part it's pointing at into view.
  319              .onChange(of: tourStep) { _, step in
  320                  guard let step, step >= 1, step <= Tour.steps.count else { return }
  321                  withAnimation { scroller.scrollTo(Tour.steps[step - 1].spot.rawValue, anchor: .center) }
  322              }
  323              }
  324              Spacer(minLength: 0)
  325              // The sticky calling bar: caller number + Options (between calls only), then the big buttons.
  326              VStack(alignment: .leading, spacing: 16) {
  327                  if appPhone, coach.status == .ready { AircallPhonePanel(onSettings: { showSettings = true }).tourSpot(.phone) }
  328                  bottomBanner
  329                  navigation.tourSpot(.call)
  330              }
  331              .padding(18)
  332              .background(Brand.card, in: RoundedRectangle(cornerRadius: 18))
  333              .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.edge, lineWidth: 1))
  334          }
  335          .padding(.horizontal, margin)
  336          .padding(.vertical, gap)
  337          // The space bar gets a fresh line during a call (see CoachModel.installSpaceKey).
  338          .onAppear {
  339              if !tourSeen, coach.status == .ready { tourStep = 0 } // first open: the welcome card
  340              campaigns.ensureSelectedActive()
  341              coach.use(campaigns.selected)
  342              coach.activate(true)
  343              syncScriptToList()
  344              openListAtLaunch()
  345          }
  346          .task {
  347              // Look for a new version now and every 15 seconds (the public commit feed, no hourly limit).
  348              while !Task.isCancelled {
  349                  await updater.check()
  350                  try? await Task.sleep(for: .seconds(15))
  351              }
  352          }
  353          .onDisappear { coach.activate(false) }
  354          .onReceive(NotificationCenter.default.publisher(for: .eastCoastFirstChanged)) { _ in coach.applyEastCoastFirst() }
  355          // Also check whenever the rep switches back to the app.
  356          .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
  357              Task { await updater.check() }
  358          }
  359          .onChange(of: campaigns.selected) { old, new in
  360              coach.use(new)
  361              // A different campaign, or its list changed in the editor: open that list in Chrome.
  362              if old.id != new.id || old.listViewID != new.listViewID { openList(of: new) }
  363              if old.id != new.id { coach.listDone = false }
  364          }
  365          // The list open in Chrome decides the script: land on a campaign's list and its script follows.
  366          .onChange(of: coach.callList.listKey) { _, _ in syncScriptToList() }
  367          .onChange(of: coach.status) { _, status in
  368              syncScriptToList()
  369              if status != .ready { tourStep = nil } // never during a call
  370              if status == .live { listHops = 0 }
  371          }
  372          // This list is done: start the next list that's on, by itself.
  373          .onChange(of: listRanOut) { _, done in
  374              if done { startNextListCountdown() } else { stopNextListCountdown() }
  375          }
  376          .onChange(of: campaigns.campaigns) { _, _ in campaigns.ensureSelectedActive(); syncScriptToList() }
  377          .sheet(isPresented: $showHelp) { HelpView() }
  378          .sheet(isPresented: $showFullScript) {
  379              VStack(alignment: .leading, spacing: 10) {
  380                  HStack {
  381                      Text("Full script: \(campaigns.selected.name)").font(.title3.weight(.semibold))
  382                      Spacer()
  383                      Button("Done") { showFullScript = false }.keyboardShortcut(.defaultAction)
  384                  }
  385                  ScrollView { ScriptOutlineCard(coach: coach, fullOnly: true) }
  386              }
  387              .padding(20)
  388              .frame(width: 520, height: 600)
  389              .brandWindow()
  390          }
  391          .sheet(isPresented: $showScriptMaker) {
  392              ScriptMakerView(onEdit: { edit($0) }).environmentObject(campaigns)
  393          }
  394          .sheet(isPresented: $showSetup) {
  395              SetupView(onAudioCheck: onAudioCheck, onKeys: onKeys).environmentObject(coach)
  396          }
  397          .sheet(isPresented: $showSettings) { SettingsPane(updater: updater, onAudioCheck: onAudioCheck, onKeys: onKeys).environmentObject(coach) }
  398          .sheet(isPresented: $showAircall) { AircallSetupView() }
  399          .sheet(isPresented: $showDropSetup) { VoicemailDropSetupView() }
  400          .animation(.easeInOut(duration: 0.2), value: coach.status)
  401      }
  402  
  403      // MARK: What's happening now
  404  
  405      /// One plain line that always says what's happening and what to do next.
  406      private var nowLine: (text: String, color: Color) {
  407          switch coach.phase {
  408          case .live:
  409              switch coach.kind {
  410              case .voicemail: return (coach.voicemailDropStarted ? "Connected · Voicemail. Your message drops after the beep." : "Connected · Voicemail. Read after the beep.", warning)
  411              case .screener: return ("Connected · A robot answered. Say the line below.", warning)
  412              default: return ("Connected", listening)
  413              }
  414          case .paused: return ("Paused. The app is not listening.", warning)
  415          case .dialing: return (coach.dialing ? "Ringing" : "Connecting", Brand.blue)
  416          case .countdown: return ("Next call soon. Space to pause.", Brand.blue)
  417          case .gettingReady: return ("Connecting · getting the next person ready", Brand.blue)
  418          case .waitingForText: return ("Send the text to move on.", Brand.blue)
  419          case .idle: break
  420          }
  421          if listRanOut { return ("Nobody left to call on this list right now.", Brand.blue) }
  422          if !coach.leads.isActive && coach.callList.records.isEmpty {
  423              let setup = SetupView.doneCount(coach: coach)
  424              return setup.done < setup.total
  425                  ? ("Start here: click the gear, then Set up.", warning)
  426                  : ("Open your list in Salesforce, in Chrome.", warning)
  427          }
  428          if coach.shouldOfferRedial { return ("Ended · No answer. Call them again or go to the next person.", Brand.blue) }
  429          return ("", listening) // ready: no words needed, the green button says it
  430      }
  431  
  432      /// "Ready to dial": a light for each thing calling needs. Only shows while something isn't ready;
  433      /// clicking an orange light opens the place to fix it.
  434      private var preflight: [(name: String, ok: Bool, fix: () -> Void)] {
  435          let aircallURL = AircallPhone.shared.webView.url?.absoluteString.lowercased() ?? ""
  436          let signedIn = !["login", "signin", "sign-in", "sign_in"].contains { aircallURL.contains($0) }
  437          return [
  438              (Aircall.canPlaceCalls && signedIn ? "Aircall" : "Aircall: sign in", Aircall.canPlaceCalls && signedIn,
  439               { showAircall = true }),
  440              ("Mic", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, {
  441                  if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
  442                      NSWorkspace.shared.open(url)
  443                  }
  444              }),
  445              ("Salesforce", Salesforce.isConnected, { showSetup = true }),
  446              ("Chrome", coach.leads.isActive || !coach.callList.chromeBlocked, { showSetup = true }),
  447              ("List", coach.leads.isActive || !coach.callList.records.isEmpty, { openList(of: campaigns.selected) }),
  448          ]
  449      }
  450  
  451      /// Shown once, after the rep has heard a voicemail, until they set up the voicemail drop or say not now.
  452      @ViewBuilder private var dropNudge: some View {
  453          if coach.status == .ready, !Prefs.voicemailDropOn, !dropNudgeDismissed, !inTour, Aircall.canPlaceCalls,
  454             UserDefaults.standard.integer(forKey: PrefKey.voicemailsSeen) >= 1 {
  455              HStack(spacing: 8) {
  456                  Image(systemName: "waveform.badge.mic").foregroundStyle(Brand.blue)
  457                  Text("Skip talking to voicemails: record one message and the app drops it for you.")
  458                      .font(.caption).fixedSize(horizontal: false, vertical: true)
  459                  Spacer(minLength: 4)
  460                  Button("Set up") { showDropSetup = true }.controlSize(.small)
  461                  Button("Not now") { dropNudgeDismissed = true }.buttonStyle(.brandLink).font(.caption)
  462              }
  463              .padding(8)
  464              .background(Brand.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  465          }
  466      }
  467  
  468      @ViewBuilder private var readyCheck: some View {
  469          let items = preflight
  470          if coach.status == .ready, items.contains(where: { !$0.ok }) {
  471              HStack(spacing: 10) {
  472                  Text("Ready to dial:").font(.caption2.weight(.semibold))
  473                  ForEach(items.indices, id: \.self) { i in
  474                      Button { items[i].fix() } label: {
  475                          HStack(spacing: 3) {
  476                              Circle().fill(items[i].ok ? Color.green : Color.orange).frame(width: 7, height: 7)
  477                              Text(items[i].name).font(.caption2)
  478                          }
  479                      }
  480                      .buttonStyle(.plain)
  481                      .disabled(items[i].ok)
  482                      .help(items[i].ok ? "\(items[i].name) is ready" : "Click to fix: \(items[i].name)")
  483                  }
  484                  Spacer(minLength: 0)
  485              }
  486              .padding(8)
  487              .brandCard(radius: 8)
  488          }
  489      }
  490  
  491      private var nowBar: some View {
  492          let now = nowLine
  493          return VStack(alignment: .leading, spacing: 2) {
  494              HStack(spacing: 6) {
  495                  if !now.text.isEmpty {
  496                      Circle().fill(now.color).frame(width: 7, height: 7)
  497                      Text(now.text).font(.caption.weight(.semibold))
  498                          .fixedSize(horizontal: false, vertical: true)
  499                  }
  500                  Spacer(minLength: 0)
  501                  Button(showMore ? "Show less" : "Show more") { showMore.toggle() }
  502                      .buttonStyle(.brandLink).font(.caption)
  503                      .help(showMore ? "Back to just the person, the line and the buttons"
  504                                     : "Also show the opening line and your script")
  505              }
  506              HStack(spacing: 10) {
  507                  if coach.streak >= 3 { Text("🔥 \(coach.streak) in a row").font(.caption2.weight(.semibold)) }
  508                  if coach.streak > 0 {
  509                      Button("Reset streak") { coach.streak = 0; coach.lastDialAt = .distantPast }
  510                          .buttonStyle(.brandLink).font(.caption2)
  511                          .help("Start the in-a-row count over")
  512                  }
  513                  Spacer(minLength: 0)
  514              }
  515              .padding(.leading, 13)
  516              if coach.status == .live, coach.voicemailDropStarted {
  517                  Button("Drop now") { coach.dropNow() }
  518                      .buttonStyle(.bordered).controlSize(.small).padding(.leading, 13)
  519                      .help("Drop your recorded voicemail right now (the beep already played)")
  520              }
  521              if coach.waitingForLinkedIn {
  522                  HStack(spacing: 8) {
  523                      Text(coach.linkedInStatus ?? "Send the LinkedIn note, then the next call starts.").font(.caption2.weight(.semibold))
  524                      Button("Skip LinkedIn") {
  525                          ActivityLog.add("LinkedIn skipped by the rep")
  526                          coach.followUp?.linkedinDone = true
  527                      }.buttonStyle(.brandLink).font(.caption2)
  528                  }.padding(.leading, 13)
  529              }
  530              if !coach.waitingForLinkedIn, let s = coach.linkedInStatus {
  531                  Text(s).font(.caption2).foregroundStyle(.secondary).padding(.leading, 13)
  532              }
  533              if let toast = coach.toast {
  534                  Text(toast).font(.caption2.weight(.semibold)).foregroundStyle(Color.green).padding(.leading, 13)
  535              }
  536          }
  537      }
  538  
  539      // MARK: Top: campaign, status, settings
  540  
  541      private var topBar: some View {
  542          VStack(alignment: .leading, spacing: 8) {
  543              // One row for the three menus when they fit. If the window is narrow they wrap to two rows,
  544              // so nothing is ever pushed off the edge.
  545              if Keychain.needsUnlock { keysBanner }
  546              // Three controls: who to call, what to say, settings. Nothing else up here.
  547              if coach.status != .ready {
  548                  // Calling mode: just what's being called and with which script. No settings mid-call.
  549                  HStack(spacing: 6) {
  550                      Image(systemName: "list.bullet.rectangle").foregroundStyle(Brand.subtext)
  551                      Text(campaigns.selected.listName.isEmpty ? "Salesforce list" : campaigns.selected.listName)
  552                          .font(.caption.weight(.semibold)).lineLimit(1)
  553                      Text("·").foregroundStyle(Brand.muted)
  554                      Image(systemName: "text.quote").foregroundStyle(Brand.subtext)
  555                      Text(campaigns.selected.name).font(.caption.weight(.semibold)).lineLimit(1)
  556                      Spacer(minLength: 0)
  557                  }
  558              } else {
  559              VStack(alignment: .leading, spacing: 12) {
  560                  HStack(alignment: .center, spacing: 8) {
  561                      headerField("CALL LIST · SALESFORCE LIST VIEW") { salesforceListMenu }.tourSpot(.list)
  562                      Spacer(minLength: 0)
  563                      settingsMenu.tourSpot(.gear)
  564                  }
  565              }
  566              .padding(16)
  567              .background(Brand.card, in: RoundedRectangle(cornerRadius: 16))
  568              }
  569              // A new version: the Update button shows here between calls (and while it installs).
  570              updateBar
  571          }
  572          // No status, Voicemail or End call buttons here (the app handles those by itself).
  573          // Command-E still ends a call; Settings has both buttons.
  574          .background(
  575              Button("") { coach.hangUpAndEnd() }
  576                  .keyboardShortcut("e", modifiers: .command)
  577                  .opacity(0).frame(width: 0, height: 0)
  578                  .allowsHitTesting(false)
  579          )
  580      }
  581  
  582      /// Who to call: the Salesforce list, right at the top. Picking one saves it on the call list in use
  583      /// and opens it in Chrome. Shows the list open in Chrome when none is saved.
  584      private var salesforceListMenu: some View {
  585          let selected = campaigns.selected
  586          let openKey = coach.callList.listKey?.view ?? ""
  587          let openName = listViewCache.first { !openKey.isEmpty && ($0.id.prefix(15) == openKey.prefix(15) || $0.developerName == openKey) }?.label
  588          let name = selected.listName.isEmpty ? (openName ?? "Pick a Salesforce list") : selected.listName
  589          return Menu {
  590              if !Salesforce.isConnected || listViewCache.isEmpty {
  591                  // No lists yet: the one thing to do is log in (Set up has the Salesforce sign-in).
  592                  Button("Log in to Salesforce to see your lists") { showSetup = true }
  593                  if Salesforce.isConnected {
  594                      Button("Try loading my lists again") {
  595                          Task { listViewCache = (try? await Salesforce.listViews()) ?? [] }
  596                      }
  597                  }
  598              }
  599              ForEach(listViewCache) { v in
  600                  Button {
  601                      var c = campaigns.selected
  602                      c.listViewID = v.id; c.listObject = v.object; c.listName = v.label
  603                      campaigns.save(c) // onChange opens it in Chrome
  604                      coach.listDone = false
  605                  } label: {
  606                      if v.id.prefix(15) == selected.listViewID.prefix(15) { Label(v.title, systemImage: "checkmark") } else { Text(v.title) }
  607                  }
  608              }
  609          } label: {
  610              dropdownLabel(Self.short(name, max: 34))
  611          }
  612          .menuStyle(.borderlessButton)
  613          .menuIndicator(.hidden)
  614          .fixedSize()
  615          .disabled(coach.status != .ready)
  616          .help(coach.status == .ready ? "Who to call: the Salesforce list. Pick one and it opens in Chrome." : "Finish the call to switch lists")
  617          .task {
  618              if listViewCache.isEmpty, Salesforce.isConnected { listViewCache = (try? await Salesforce.listViews()) ?? [] }
  619          }
  620      }
  621  
  622      /// After an update, macOS wants the rep's OK before this copy reads the saved keys. The app opens
  623      /// anyway; this asks, with the window on screen, then restarts the app so everything loads.
  624      private var keysBanner: some View {
  625          HStack(spacing: 10) {
  626              Image(systemName: "key.fill").foregroundStyle(warning)
  627              Text("Your Mac needs your OK to use your saved keys (this happens after an update). Click Allow, type your Mac password, then Always Allow.")
  628                  .font(.callout).fixedSize(horizontal: false, vertical: true)
  629              Spacer(minLength: 8)
  630              Button("Allow") {
  631                  if Keychain.unlock() {
  632                      let path = Bundle.main.bundlePath
  633                      let p = Process()
  634                      p.executableURL = URL(fileURLWithPath: "/bin/sh")
  635                      p.arguments = ["-c", "sleep 1; open \"\(path)\""]
  636                      try? p.run()
  637                      NSApp.terminate(nil)
  638                  }
  639              }
  640              .buttonStyle(BrandPrimaryButton())
  641          }
  642          .padding(12)
  643          .background(warning.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
  644      }
  645  
  646      /// A small gray label over a control: "CALL LIST", "SCRIPT".
  647      private func headerField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
  648          VStack(alignment: .leading, spacing: 3) {
  649              Text(title).font(.caption.weight(.medium)).tracking(0.6).foregroundStyle(Brand.subtext)
  650              content()
  651          }
  652      }
  653  
  654      /// What a dropdown looks like: the value in white, one down arrow, a visible box.
  655      private func dropdownLabel(_ text: String, chevron: Bool = true, icon: String? = nil) -> some View {
  656          HStack(spacing: 8) {
  657              if let icon { Image(systemName: icon).font(.callout).foregroundStyle(Brand.subtext) }
  658              Text(text).font(.title3.weight(.medium)).foregroundStyle(Brand.text).lineLimit(1).truncationMode(.tail)
  659              if chevron {
  660                  Image(systemName: "chevron.down").font(.callout.weight(.semibold)).foregroundStyle(Brand.blue)
  661              }
  662          }
  663          .contentShape(Rectangle())
  664      }
  665  
  666      /// A long call list name shortened with "..." so the menu is never wider than the bar.
  667      private static func short(_ name: String, max: Int = 26) -> String {
  668          name.count > max ? String(name.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : name
  669      }
  670  
  671      /// The walkthrough is on its "Stay up to date" step: show a sample bar if there's no real update.
  672      private var tourShowsUpdate: Bool {
  673          guard let step = tourStep, step >= 1, step <= Tour.steps.count else { return false }
  674          return Tour.steps[step - 1].title.hasPrefix("Updates")
  675      }
  676  
  677      @ViewBuilder private var updateBar: some View {
  678          if updater.updating {
  679              HStack(spacing: 8) {
  680                  ProgressView().controlSize(.small)
  681                  Text("Updating. The app restarts by itself in about 2 minutes. Keep working.")
  682                      .font(.caption).fixedSize(horizontal: false, vertical: true)
  683                  Spacer(minLength: 0)
  684              }
  685              .padding(8)
  686              .background(Brand.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
  687          } else if updater.updateAvailable || tourShowsUpdate {
  688              HStack(spacing: 8) {
  689                  Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.blue)
  690                  Text("A new version is ready.").font(.caption.weight(.semibold))
  691                  Spacer(minLength: 8)
  692                  Button("Update now") { updater.update() }
  693                      .buttonStyle(.borderedProminent)
  694                      .controlSize(.small)
  695                      .fixedSize()
  696                      .disabled(!updater.updateAvailable || coach.status != .ready)
  697                      .help(coach.status == .ready ? "Installs the new version. Takes about 2 minutes. No Terminal." : "Finish the call first: the app restarts to update.")
  698              }
  699              .padding(8)
  700              .background(Brand.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
  701              .tourSpot(.update)
  702          }
  703      }
  704  
  705      /// Only call people in one time zone. "All time zones" turns it off.
  706      private var timeZoneMenu: some View {
  707          let picked = TimeZoneFilter.selected
  708          return Menu {
  709              Button {
  710                  coach.setTimeZoneFilter(nil)
  711              } label: {
  712                  if picked == nil { Label("All time zones", systemImage: "checkmark") } else { Text("All time zones") }
  713              }
  714              Divider()
  715              ForEach(CallZone.allCases) { zone in
  716                  Button {
  717                      coach.setTimeZoneFilter(zone)
  718                  } label: {
  719                      let title = "\(zone.label) · \(zone.timeNow) there now"
  720                      if picked == zone { Label(title, systemImage: "checkmark") } else { Text(title) }
  721                  }
  722              }
  723          } label: {
  724              Label(picked.map { "\($0.label) time" } ?? "All time zones",
  725                    systemImage: "globe.americas.fill")
  726                  .labelStyle(.titleAndIcon)
  727                  .font(.caption.weight(.semibold)).lineLimit(1)
  728          }
  729          .menuStyle(.borderlessButton)
  730          .fixedSize()
  731          .help(picked == nil
  732                ? "Where to call: pick one time zone, or all of them (East first is in Edit call list)"
  733                : "Only calling people in \(picked?.label ?? "") time. People with no state or US number in Salesforce stay on the list.")
  734      }
  735  
  736      /// "Setup (5 of 7 done)" until everything is set up.
  737      private var setupLabel: String {
  738          let c = SetupView.doneCount(coach: coach)
  739          return c.done == c.total ? "Set up..." : "Set up (\(c.done) of \(c.total) done)..."
  740      }
  741  
  742      /// Three items only. Everything else lives in the Setup and Settings panes.
  743      private var settingsMenu: some View {
  744          Menu {
  745              if updater.updateAvailable {
  746                  Button("Install the new version (about 2 min)") { updater.update() }
  747                      .disabled(coach.status != .ready)
  748                  Divider()
  749              }
  750              Button("Settings...") { showSettings = true }
  751              Button("Show me around") { tourStep = 0 }
  752                  .disabled(coach.status != .ready)
  753          } label: {
  754              Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(Brand.text)
  755                  .frame(width: 44, height: 44)
  756                  .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.controlEdge, lineWidth: 1))
  757                  .overlay(alignment: .topTrailing) {
  758                      if updater.updateAvailable || tourShowsUpdate {
  759                          Circle().fill(Brand.go).frame(width: 9, height: 9).offset(x: -5, y: 5)
  760                      }
  761                  }
  762                  .help(updater.updateAvailable ? "Settings · a new version is ready" : "Settings")
  763          }
  764          .menuStyle(.borderlessButton)
  765          .menuIndicator(.hidden)
  766          .fixedSize()
  767      }
  768  
  769      /// Saves the edited opener into the script: replaces the old opener where it's written, else adds it
  770      /// as the rep's own wording. The coach then shows it on the next call.
  771      private func saveOpener() {
  772          editingOpener = false
  773          let new = openerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
  774          let old = coach.scriptOpenerLine() ?? ""
  775          guard !new.isEmpty, new != old else { return }
  776          var c = campaigns.selected
  777          c.pastedScript = ScriptPage.shared.edit(script: c.pastedScript, title: "OPENER", oldLines: [old], newLines: [new])
  778          campaigns.save(c)
  779          coach.suggestion = Suggestion(say: coach.fillTags(new, for: coach.calling), cue: "Your opener", stage: "Opener", sayComplete: true)
  780          ActivityLog.add("Opener edited by the rep")
  781      }
  782  
  783      /// The small Edit action in the My Script header: change this script (or type it by hand),
  784      /// switch scripts, or write a new one. A menu, so clicking it never folds the card.
  785      private var scriptEditMenu: some View {
  786          Menu {
  787              Button("Edit this script...") { edit(campaigns.selected) }
  788              Button("Write a new script with Claude...") { showScriptMaker = true }
  789              Divider()
  790              Text("Switch script (using \(campaigns.selected.name))")
  791              ForEach(campaigns.campaigns) { c in
  792                  Button {
  793                      switchTo(c)
  794                  } label: {
  795                      if c.id == campaigns.selected.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
  796                  }
  797              }
  798          } label: {
  799              HStack(spacing: 6) {
  800                  Image(systemName: "pencil")
  801                  Text("Edit")
  802              }
  803              .font(.callout).foregroundStyle(Brand.subtext)
  804              .padding(.horizontal, 8).padding(.vertical, 4)
  805              .contentShape(Rectangle())
  806          }
  807          .menuStyle(.borderlessButton)
  808          .menuIndicator(.hidden)
  809          .fixedSize()
  810          .disabled(coach.status != .ready)
  811          .help("Using: \(campaigns.selected.name). Edit it, type it by hand, switch scripts, or write a new one")
  812          .tourSpot(.segment)
  813      }
  814  
  815      /// What to say: pick a script, edit it, or have Claude write a new one. Who to call is the
  816      /// Salesforce list above, and switching scripts never changes it. Locked during a call.
  817      private var campaignMenu: some View {
  818          Menu {
  819              if coach.status != .ready {
  820                  Text("You're on a call. Finish it to switch scripts.")
  821                  Divider()
  822              }
  823              Text("What to say: the script the coach follows on every call. Switching it doesn't change who you call.")
  824              Divider()
  825              Group {
  826              ForEach(campaigns.campaigns) { campaign in
  827                  Button {
  828                      switchTo(campaign)
  829                  } label: {
  830                      if campaign.id == campaigns.selected.id {
  831                          Label(campaign.name, systemImage: "checkmark")
  832                      } else {
  833                          Text(campaign.name)
  834                      }
  835                  }
  836              }
  837              Divider()
  838              Button("Write a new script with Claude (one click)...") { showScriptMaker = true }
  839              }
  840              .disabled(coach.status != .ready) // switching scripts mid-call would change what the coach says
  841          } label: {
  842              dropdownLabel(Self.short(campaigns.selected.name, max: 30), chevron: false, icon: "doc.text")
  843          }
  844          .menuStyle(.borderlessButton)
  845          .menuIndicator(.hidden)
  846          .fixedSize()
  847          .help(coach.status == .ready ? "What to say: pick a script, edit it, or have Claude write a new one" : "Finish the call to switch scripts")
  848      }
  849  
  850      /// Picks the active campaign whose Salesforce list is the one open in Chrome (between calls only).
  851      /// Chrome's address can hold the list's Id or its API name, so both are matched.
  852      private func syncScriptToList() {
  853          return // the script is picked on its own now; the Salesforce list never switches it
  854          guard coach.status == .ready, let key = coach.callList.listKey?.view, !key.isEmpty else { return }
  855          Task {
  856              if listViewCache.isEmpty { listViewCache = (try? await Salesforce.listViews()) ?? [] }
  857              let openID = listViewCache.first { $0.id.prefix(15) == key.prefix(15) || $0.developerName == key }?.id ?? key
  858              guard coach.status == .ready,
  859                    let match = campaigns.campaigns.first(where: { !$0.listViewID.isEmpty && $0.listViewID.prefix(15) == openID.prefix(15) }),
  860                    match.id != campaigns.selectedID else { return }
  861              ActivityLog.add("Campaign: the open list matches \(match.name), switching script")
  862              campaigns.selectOnly(match.id)
  863          }
  864      }
  865  
  866      /// Switches campaign (its script) and opens its Salesforce list in Chrome, so the app works that list.
  867      private func switchTo(_ campaign: Campaign) {
  868          // The script changes; who to call (the Salesforce list in use) stays.
  869          let current = campaigns.selected
  870          if campaign.id != current.id, !current.listViewID.isEmpty, campaign.listViewID != current.listViewID {
  871              var c = campaign
  872              c.listViewID = current.listViewID; c.listObject = current.listObject; c.listName = current.listName
  873              campaigns.save(c)
  874          }
  875          campaigns.selectOnly(campaign.id)
  876          coach.listDone = false
  877      }
  878  
  879      private func openList(of campaign: Campaign) {
  880          guard !campaign.listViewID.isEmpty, !campaign.listObject.isEmpty else { return }
  881          // Already on that list in Chrome (the script just followed it): don't reload it.
  882          if let open = coach.callList.listKey?.view,
  883             open.prefix(15) == campaign.listViewID.prefix(15)
  884              || listViewCache.contains(where: { $0.developerName == open && $0.id.prefix(15) == campaign.listViewID.prefix(15) }) { return }
  885          let origin = SalesforceChrome.url().flatMap { URL(string: $0) }.flatMap { u in u.host.map { "https://\($0)" } }
  886              ?? Keychain.read(.sfInstance) ?? ""
  887          guard !origin.isEmpty else { return }
  888          _ = SalesforceChrome.open("\(origin)/lightning/o/\(campaign.listObject)/list?filterName=\(campaign.listViewID)")
  889          ActivityLog.add("Campaign: \(campaign.name), list \(campaign.listName)")
  890      }
  891  
  892      /// App just opened and Chrome has no Salesforce tab: open this call list's Salesforce list there,
  893      /// so the rep can start calling without finding it by hand.
  894      private func openListAtLaunch() {
  895          let c = campaigns.selected
  896          guard !c.listViewID.isEmpty, !c.listObject.isEmpty, let origin = Keychain.read(.sfInstance), !origin.isEmpty,
  897                let url = URL(string: "\(origin)/lightning/o/\(c.listObject)/list?filterName=\(c.listViewID)"),
  898                let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
  899          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
  900              guard SalesforceChrome.url(live: true) == nil else { return } // a Salesforce tab is already open
  901              NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
  902              ActivityLog.add("Opened \(c.listName.isEmpty ? "the call list" : c.listName) in Chrome (no Salesforce tab was open)")
  903          }
  904      }
  905  
  906      private func stopNextListCountdown() {
  907          nextListTask?.cancel()
  908          nextListTask = nil
  909          nextListIn = nil
  910      }
  911  
  912      /// Counts down 5 seconds, switches to the next list that's on, waits for its people to load,
  913      /// then starts calling. Only with "Call the next person for me" on, and at most once around the lists.
  914      private func startNextListCountdown() {
  915          stopNextListCountdown()
  916          guard coach.autoDial, !coach.leads.isActive, tourStep == nil, let next = nextCampaign,
  917                listHops < campaigns.activeCampaigns.count else { return }
  918          nextListTask = Task { @MainActor in
  919              for left in stride(from: 5, through: 1, by: -1) {
  920                  nextListIn = left
  921                  try? await Task.sleep(for: .seconds(1))
  922                  if Task.isCancelled { return }
  923                  if coach.status != .ready { nextListIn = nil; return }
  924              }
  925              nextListIn = nil
  926              listHops += 1
  927              ActivityLog.add("List done: starting the next list by itself: \(next.name)")
  928              switchTo(next)
  929              for _ in 0..<40 { // up to 20 seconds for the new list's people to load
  930                  try? await Task.sleep(for: .milliseconds(500))
  931                  if Task.isCancelled || coach.status != .ready { return }
  932                  if campaigns.selected.id == next.id, coach.nextLeadName != nil {
  933                      coach.startNextSequence()
  934                      return
  935                  }
  936              }
  937          }
  938      }
  939  
  940      /// The campaign after this one that has a list (the next list to work today).
  941      private var nextCampaign: Campaign? {
  942          let all = campaigns.campaigns
  943          guard let i = all.firstIndex(where: { $0.id == campaigns.selected.id }) else { return nil }
  944          let after = all[(i + 1)...] + all[..<i]
  945          return after.first { $0.active && !$0.listViewID.isEmpty }
  946      }
  947  
  948      private func edit(_ campaign: Campaign) {
  949          campaigns.editing = campaign
  950          openWindow(id: "campaign-editor")
  951          NSApplication.shared.activate(ignoringOtherApps: true)
  952      }
  953  
  954      // MARK: Who's up (Salesforce list)
  955  
  956      private var leadHeader: some View {
  957          VStack(alignment: .leading, spacing: 4) {
  958              HStack(spacing: 6) {
  959                  Menu {
  960                      ForEach(coach.leads.views) { view in
  961                          Button(view.title) { Task { await coach.leads.open(view) } }
  962                      }
  963                      Divider()
  964                      Button("Get new people from Salesforce") { Task { await coach.leads.reload() } }
  965                      Button("Use my Chrome list") { coach.leads.close() }
  966                  } label: {
  967                      Text(coach.leads.selected?.label ?? "Pick a list").font(.caption.weight(.semibold))
  968                  }
  969                  .menuStyle(.borderlessButton)
  970                  .fixedSize()
  971                  .disabled(coach.status != .ready)
  972                  if coach.leads.loading { ProgressView().controlSize(.mini) }
  973                  Spacer()
  974                  if coach.leads.isActive {
  975                      Text("\(min(coach.leads.index + 1, coach.leads.rows.count)) of \(coach.leads.rows.count) · \(coach.leads.leftToCall) to call today")
  976                          .font(.caption).foregroundStyle(.secondary)
  977                  }
  978              }
  979              if let d = coach.leads.details {
  980                  HStack(alignment: .firstTextBaseline, spacing: 6) {
  981                      Text(d.name).font(.headline).lineLimit(1)
  982                      Text([d.title, d.company, TimeZoneFilter.zone(of: d.id).map { "\($0.label) time" }]
  983                          .compactMap { $0 }.joined(separator: " · "))
  984                          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
  985                      Spacer(minLength: 0)
  986                      if let url = Salesforce.recordURL(d.id) {
  987                          Link(destination: url) { Image(systemName: "arrow.up.right.square") }
  988                              .help("Open in Salesforce")
  989                      }
  990                  }
  991                  if d.doNotCall {
  992                      warningText("Do Not Call is checked in Salesforce. Skip this one.")
  993                  } else if let last = d.recent.first {
  994                      Text("Last: \(last)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
  995                  }
  996              } else if let error = coach.leads.error {
  997                  warningText(error)
  998              } else if coach.leads.selected == nil && !coach.leads.loading {
  999                  Text("Step 1: click \"Pick a list\" above and choose who to call.").font(.caption).foregroundStyle(.secondary)
 1000              }
 1001          }
 1002      }
 1003  
 1004      // MARK: The hero: what to say
 1005  
 1006      private var scriptCard: some View {
 1007          VStack(alignment: .leading, spacing: 8) {
 1008              HStack(spacing: 6) {
 1009                  Button { liveCardOpen.toggle() } label: {
 1010                      HStack(spacing: 6) {
 1011                          Image(systemName: liveCardOpen ? "chevron.down" : "chevron.right").font(CardStyle.chevron).foregroundStyle(Brand.subtext)
 1012                          Image(systemName: "waveform").font(CardStyle.icon).foregroundStyle(Brand.blue)
 1013                          // Always "Live Coach"; a voicemail or robot adds what to do.
 1014                          Text(coach.kind == .voicemail || coach.kind == .screener ? "Live Coach · " + cardLabel.capitalized : "Live Coach")
 1015                              .font(CardStyle.title)
 1016                              .foregroundStyle(coach.kind == .voicemail || coach.kind == .screener ? warning : Brand.text)
 1017                      }
 1018                      .contentShape(Rectangle())
 1019                  }
 1020                  .buttonStyle(.plain)
 1021                  .help(liveCardOpen ? "Fold the coach card" : "Open the coach card")
 1022                  Spacer()
 1023                  if coach.thinking && coach.status == .live {
 1024                      ProgressView().controlSize(.mini)
 1025                  }
 1026                  if coach.historyIndex != nil {
 1027                      Button("Latest") { coach.showLatest() }
 1028                          .buttonStyle(.brandLink).font(.caption2)
 1029                  } else if coach.status == .live {
 1030                      Button(coach.holdLine ? "Release" : "Hold") { coach.holdLine.toggle() }
 1031                          .buttonStyle(.brandLink).font(.caption2)
 1032                          .help("Hold keeps this line on screen until you release it.")
 1033                      if coach.pending != nil {
 1034                          Text(coach.lineSuperseded ? "They moved on. New line ready" : "Next line ready")
 1035                              .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
 1036                          Button("Next") { coach.promoteNow() }
 1037                              .buttonStyle(.brandLink).font(.caption2)
 1038                              .help("Show the new line now. It shows by itself when you stop talking.")
 1039                      }
 1040                      Button("For a fresh line (press space bar)") { coach.newLine() }
 1041                          .buttonStyle(.brandLink).font(.caption2)
 1042                          .help("Don't like this line? Get a new one right now.")
 1043                  }
 1044              }
 1045              if liveCardOpen, editingOpener {
 1046                  // Quick edit of the opener: saved into the script, so every call uses it.
 1047                  VStack(alignment: .leading, spacing: 6) {
 1048                      TextEditor(text: $openerDraft)
 1049                          .font(.title3)
 1050                          .scrollContentBackground(.hidden)
 1051                          .padding(6)
 1052                          .frame(minHeight: 80)
 1053                          .background(Brand.navy.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
 1054                          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.blue, lineWidth: 1))
 1055                      HStack(spacing: 10) {
 1056                          Button("Save opener") { saveOpener() }.buttonStyle(BrandPrimaryButton())
 1057                          Button("Cancel") { editingOpener = false }.buttonStyle(.brandLink)
 1058                          Text("Use [Name] for their first name.").font(.caption).foregroundStyle(Brand.muted)
 1059                      }
 1060                  }
 1061              } else if liveCardOpen {
 1062              lineText(inTour && coach.status == .ready ? TourSample.line
 1063                   : coach.suggestion.say.isEmpty
 1064                   ? (Keychain.read(.anthropic) == nil ? "Almost there. Click the gear, then Set up, and upload your keys file." : "Getting your line ready...")
 1065                   : cardLine, emphasized: false) // frozen for the model test: plain line
 1066                  .font(lineFont)
 1067                  .lineSpacing(2)
 1068                  .fixedSize(horizontal: false, vertical: true)
 1069                  .foregroundStyle(lineIsSoft ? Color.secondary : Color.primary)
 1070                  .opacity(coach.historyIndex == nil ? 1 : 0.6)
 1071                  // Between calls, click the opener to edit it.
 1072                  .onTapGesture {
 1073                      guard coach.status == .ready, coach.kind == .opener, !inTour else { return }
 1074                      openerDraft = coach.scriptOpenerLine() ?? coach.suggestion.say
 1075                      editingOpener = true
 1076                  }
 1077                  .help(coach.status == .ready && coach.kind == .opener ? "Click to edit your opener" : "")
 1078              // THINK mode: one thought on the card; the full line only when the rep asks (⌘⇧L).
 1079              if thinkShown || showFullLine {
 1080                  Button(showFullLine ? "Back to the short thought" : "Full line (⌘⇧L)") { showFullLine.toggle() }
 1081                      .buttonStyle(.brandLink).font(.caption2)
 1082                      .keyboardShortcut("l", modifiers: [.command, .shift])
 1083                      .help("Show the full suggested sentence. Only while the app is in front, so it never touches your typing.")
 1084              }
 1085              if let n = coach.meetingThisWeek, coach.status == .live {
 1086                  Text("Meeting \(n) this week")
 1087                      .font(.caption.weight(.semibold))
 1088                      .foregroundStyle(Color.green)
 1089                      .transition(.opacity)
 1090              }
 1091              }
 1092          }
 1093          .padding(CardStyle.padding)
 1094          .frame(maxWidth: .infinity, alignment: .leading)
 1095          .background(Brand.scriptCard, in: RoundedRectangle(cornerRadius: 14))
 1096          .overlay(alignment: .leading) {
 1097              // Thin teal accent: the brand, without a bright panel behind the words.
 1098              Rectangle().fill(Brand.teal).frame(width: 3)
 1099          }
 1100          .clipShape(RoundedRectangle(cornerRadius: 14))
 1101          .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.blue.opacity(0.45), lineWidth: 1))
 1102          .overlay(MeetingGlow(trigger: coach.meetingMoments))
 1103          .animation(.easeOut(duration: 0.15), value: coach.suggestion.say)
 1104          .onChange(of: coach.suggestion.say) { showFullLine = false }
 1105      }
 1106  
 1107      /// THINK mode is on and this card is a normal live line (not a script row, nudge or history).
 1108      private var thinkActive: Bool {
 1109          Think.enabled && coach.status == .live && coach.kind == .reply && !coach.suggestion.nudge && coach.historyIndex == nil
 1110      }
 1111      /// What the big line shows: the thought in THINK mode, otherwise (or on request, or when missing) SAY.
 1112      private var cardLine: String {
 1113          guard thinkActive else { return coach.suggestion.say }
 1114          return Think.primary(think: coach.suggestion.think, say: coach.suggestion.say,
 1115                               exact: coach.suggestion.rowTag != nil, enabled: true, showFull: showFullLine,
 1116                               move: coach.suggestion.move)
 1117      }
 1118      /// A thought (not SAY) is on the card right now.
 1119      private var thinkShown: Bool { thinkActive && cardLine != coach.suggestion.say }
 1120  
 1121      /// The line on the card: big and bold, or a little softer for a nudge.
 1122      private var lineFont: Font {
 1123          coach.suggestion.nudge ? Font.system(size: 22, weight: .medium) : Font.system(size: 26, weight: .semibold)
 1124      }
 1125  
 1126      /// The line, with its one question full strength and the rest a bit lighter (only when clear-cut).
 1127      /// Exact script rows, nudges and the walkthrough stay plain.
 1128      private func lineText(_ say: String, emphasized: Bool) -> Text {
 1129          guard emphasized, let e = LineLook.emphasis(say) else { return Text(say) }
 1130          return Text(e.before).foregroundColor(.secondary) + Text(e.key) + Text(e.after).foregroundColor(.secondary)
 1131      }
 1132  
 1133      private var lineIsSoft: Bool { coach.suggestion.say.isEmpty || coach.suggestion.nudge }
 1134  
 1135      private func tagChip(_ text: String) -> some View {
 1136          Text(text)
 1137              .font(.caption2.weight(.medium))
 1138              .lineLimit(1)
 1139              .padding(.horizontal, 6).padding(.vertical, 1)
 1140              .background(Color.secondary.opacity(0.15), in: Capsule())
 1141              .foregroundStyle(.secondary)
 1142      }
 1143  
 1144      /// The walkthrough is showing: sample info stands in where no list is loaded yet.
 1145      private var inTour: Bool { tourStep != nil }
 1146  
 1147      private var cardLabel: String {
 1148          if inTour && coach.status == .ready { return "WHEN THEY PICK UP" }
 1149          if coach.historyIndex != nil { return "EARLIER LINE" }
 1150          if coach.suggestion.nudge { return "IF IT GOES QUIET" }
 1151          switch coach.kind {
 1152          case .opener: return "WHEN THEY PICK UP"
 1153          case .screener: return "A ROBOT ANSWERED · SAY THIS"
 1154          case .voicemail: return "VOICEMAIL · WAIT FOR THE BEEP"
 1155          case .reply:
 1156              // THINK mode: no label while a thought is up. If THINK didn't hold up, the full line shows and says so.
 1157              if thinkActive { return coach.suggestion.rowTag != nil ? "EXACT" : (thinkShown ? "" : "SAY THIS") }
 1158              return coach.suggestion.rowTag != nil ? "SAY THIS · EXACT" : "SAY THIS" // frozen for the Haiku vs Sonnet test
 1159          }
 1160      }
 1161  
 1162      // MARK: Right under the card: tip, meeting times, transcript
 1163  
 1164      private var belowCard: some View {
 1165          VStack(alignment: .leading, spacing: 8) {
 1166              // Phone tree: one click sends the keys Opus picked into the call.
 1167              if coach.status == .live, coach.suggestion.stage == "Phone tree", !coach.suggestion.keys.isEmpty {
 1168                  HStack(spacing: 8) {
 1169                      Button("Press \(coach.suggestion.keys)") { coach.pressKeys(coach.suggestion.keys) }
 1170                          .buttonStyle(.borderedProminent)
 1171                          .controlSize(.large)
 1172                      if let m = coach.keysMessage {
 1173                          Text(m).font(.caption).foregroundStyle(.secondary)
 1174                      }
 1175                  }
 1176              }
 1177              if !coach.suggestion.cueText.isEmpty {
 1178                  Text(coach.suggestion.cueText)
 1179                      .font(.callout)
 1180                      .foregroundStyle(.secondary)
 1181                      .fixedSize(horizontal: false, vertical: true)
 1182              }
 1183              if coach.suggestion.stage == "Closing", !coach.nextOffer.isEmpty {
 1184                  HStack(spacing: 8) {
 1185                      Image(systemName: "calendar").foregroundStyle(.secondary)
 1186                      Text(coach.nextOffer.map { coach.availability.label($0) }.joined(separator: "  ·  "))
 1187                          .font(.callout.weight(.medium))
 1188                      Spacer()
 1189                      Button("Other times") { coach.skipOfferedTimes() }
 1190                          .buttonStyle(.brandLink).font(.caption)
 1191                  }
 1192              }
 1193          }
 1194      }
 1195  
 1196      // MARK: Real warnings only, never cut off
 1197  
 1198      /// One warning at a time, the most important first. Nothing here while the bar above the
 1199      /// buttons already shows a warning (the Chrome setting is shown there too, so not repeated).
 1200      @ViewBuilder private var warnings: some View {
 1201          if coach.callMessage == nil || (listRanOut) {
 1202              if let problem = coach.problem {
 1203                  warningText(problem)
 1204              } else if let message = coach.callList.message {
 1205                  warningText(message)
 1206              } else if coach.callList.state == .needsChromeSetting, coach.status != .ready {
 1207                  VStack(alignment: .leading, spacing: 4) {
 1208                      warningText("Chrome needs one setting. At the top of your screen: click View, then Developer, then Allow JavaScript from Apple Events.")
 1209                      Button("Show me with pictures") { showSetup = true }
 1210                          .buttonStyle(.brandLink).font(.caption)
 1211                  }
 1212              } else if let message = updater.message, !updater.updating,
 1213                        message.hasPrefix("The update") || message.hasPrefix("Couldn't") {
 1214                  Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1215              }
 1216          }
 1217      }
 1218  
 1219      private func warningText(_ text: String) -> some View {
 1220          Label {
 1221              Text(text).fixedSize(horizontal: false, vertical: true)
 1222          } icon: {
 1223              Image(systemName: "exclamationmark.triangle.fill")
 1224          }
 1225          .font(.caption)
 1226          .foregroundStyle(warning)
 1227      }
 1228  
 1229      /// After a 2nd-try voicemail: "Calling Jane in 4", with a button to stay.
 1230      /// A real talk just ended: three big buttons. One click saves it in Salesforce and moves on.
 1231      private var outcomeBar: some View {
 1232          let object = coach.currentAttemptKey.flatMap { Salesforce.objectFor(id: $0) } ?? "Contact"
 1233          return VStack(alignment: .leading, spacing: 6) {
 1234              HStack {
 1235                  Text("How did it go with \(Screener.firstName(coach.calling) ?? "them")?").font(.callout.weight(.semibold))
 1236                  Spacer(minLength: 0)
 1237                  Button("Skip") { coach.skipOutcome() }.buttonStyle(.brandLink).font(.caption)
 1238                      .help("Don't rate this call, move on")
 1239              }
 1240              HStack(spacing: 8) {
 1241                  ForEach(Outcomes.quick(object), id: \.label) { o in
 1242                      Button {
 1243                          coach.saveStatus(o.value, unqualifiedReason: o.value == "Unqualified" ? "Non-Responsive" : nil)
 1244                      } label: {
 1245                          Text(o.label).font(.callout.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
 1246                      }
 1247                      .buttonStyle(.bordered)
 1248                      .controlSize(.large)
 1249                      .disabled(coach.savingStatus)
 1250                      .help("Saves \(o.value) in Salesforce")
 1251                  }
 1252              }
 1253          }
 1254          .padding(10)
 1255          .brandCard(radius: 10)
 1256      }
 1257  
 1258      private func autoNextBar(_ left: Int) -> some View {
 1259          countdownBar("Calling \(coach.autoNextName ?? coach.nextLeadName ?? "next person") in \(left)", left: left) {
 1260              coach.cancelAutoNext()
 1261          }
 1262      }
 1263  
 1264      /// The one countdown bar: what's about to happen, a shrinking bar, and Pause (or the space bar).
 1265      private func countdownBar(_ title: String, left: Int, pause: @escaping () -> Void) -> some View {
 1266          VStack(alignment: .leading, spacing: 6) {
 1267              HStack(spacing: 8) {
 1268                  Image(systemName: "timer")
 1269                  Text(title).font(.callout.weight(.semibold))
 1270                  Spacer(minLength: 0)
 1271                  Button("Pause") { pause() }
 1272                      .keyboardShortcut(.space, modifiers: [])
 1273                      .controlSize(.large)
 1274                      .help("Stop the countdown (space bar)")
 1275              }
 1276              ProgressView(value: Double(left), total: Double(max(countdownMax, left)))
 1277                  .tint(Brand.blue)
 1278                  .animation(.linear(duration: 1), value: left)
 1279          }
 1280          .padding(10)
 1281          .brandCard(radius: 10)
 1282          .onAppear { countdownMax = left }
 1283          .onChange(of: left) { old, new in if new > old { countdownMax = new } }
 1284      }
 1285  
 1286      // MARK: Navigation: always here, always the same two buttons
 1287  
 1288      @ViewBuilder private var navigation: some View {
 1289          if coach.status != .ready {
 1290              // During a call: no stage buttons, just a way out if the app ever misses the hang-up.
 1291              HStack(spacing: 8) {
 1292                  Button {
 1293                      coach.hangUpAndEnd()
 1294                  } label: {
 1295                      Label("END CALL", systemImage: "phone.down.fill").font(.callout.weight(.semibold))
 1296                          .frame(maxWidth: .infinity)
 1297                  }
 1298                  .buttonStyle(BrandPrimaryButton(color: Brand.stop))
 1299                  .help("Is the call over, but the app is still listening? Click here. (Command-E)")
 1300                  if coach.status == .live {
 1301                      Button("Voicemail") { coach.markVoicemail() }
 1302                          .help("Is it a voicemail, and the app missed it? Click here to see your message.")
 1303                  }
 1304              }
 1305              .controlSize(.large)
 1306          } else if inTour {
 1307              // Walkthrough: a sample person, since no list is loaded yet.
 1308              HStack(spacing: 8) {
 1309                  smallButton("Next Person") {}
 1310                  bigButton("START CALLING LIST", icon: "phone.fill") {}
 1311              }
 1312              .controlSize(.large)
 1313              .allowsHitTesting(false)
 1314          } else {
 1315              goBar
 1316          }
 1317      }
 1318  
 1319      /// Between calls: three fixed spots that never change jobs. Back goes to the person before, the big
 1320      /// Go button does the next right thing (call, call again, or move on), Skip passes this person.
 1321      private var goBar: some View {
 1322          let leadMode = coach.leads.isActive
 1323          let first = leadMode ? (coach.leads.details.map { $0.firstName ?? $0.name } ?? "them") : currentName
 1324          let nextName = leadMode ? coach.leads.nextRow?.name : { () -> String? in
 1325              if case .ready(let name, _, _) = coach.callList.state { return name }
 1326              return nil
 1327          }()
 1328          let calledAlready = leadMode ? coach.currentAttempts > 0 : coach.currentAttemptKey != nil
 1329          let notCalledYet = leadMode ? coach.currentAttempts == 0 : (coach.calling != nil && coach.currentAttemptKey == nil)
 1330          // What Go does now.
 1331          let go: (title: String, icon: String, enabled: Bool, action: () -> Void) = {
 1332              if coach.shouldOfferRedial {
 1333                  return ("Call \(first) again", "arrow.clockwise", leadMode ? canCall : !coach.dialing, { coach.redial() })
 1334              }
 1335              if notCalledYet {
 1336                  return (leadMode ? (coach.dialing ? "Calling..." : callTitle) : (coach.gettingReady ?? (coach.dialing ? "Calling..." : "Call \(currentName)")),
 1337                          "phone.fill", leadMode ? canCall : !coach.dialing,
 1338                          { leadMode ? coach.dial() : coach.callOpenLead() })
 1339              }
 1340              return (nextName != nil ? "START CALLING LIST" : "No one left", "phone.arrow.right",
 1341                      leadMode ? (nextName != nil && !coach.dialing) : (nextEnabled && !coach.dialing),
 1342                      { coach.nextLead() })
 1343          }()
 1344          // Auto dial running: between calls the app moves on by itself, so the button is STOP.
 1345          let autoRunning = coach.autoSession && coach.autoDial
 1346          return VStack(alignment: .leading, spacing: 6) {
 1347              if let error = coach.dialError { warningText(error) }
 1348              HStack(spacing: 8) {
 1349                  Button {
 1350                      coach.previousLead()
 1351                  } label: {
 1352                      Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 36)
 1353                  }
 1354                  .buttonStyle(BrandQuietButton())
 1355                  .disabled(leadMode ? !coach.leads.canGoBack : !backEnabled)
 1356                  .help("Go back to the person before")
 1357  
 1358                  smallButton("Next Person", icon: "person.2") { coach.nextLead() }
 1359                      .keyboardShortcut("n", modifiers: .command)
 1360                      .disabled(nextName == nil || coach.dialing)
 1361                      .help("Skip this person and go to the next one (Command-N)")
 1362  
 1363                  if autoRunning {
 1364                      // Auto dial is working down the list: one big red button stops it.
 1365                      bigButton("STOP CALLING", icon: "stop.fill", color: Brand.stop) { coach.stopCalling() }
 1366                          .keyboardShortcut(.return, modifiers: .command)
 1367                          .help("Stop auto dialing. Nothing new starts until you press START CALLING LIST.")
 1368                  } else {
 1369                      bigButton(go.title, icon: go.icon, color: Brand.go) { coach.startCalling(); go.action() }
 1370                          .keyboardShortcut(.return, modifiers: .command)
 1371                          .disabled(!go.enabled)
 1372                  }
 1373              }
 1374              .controlSize(.large)
 1375              // Call them once more after their two tries (Command-R), without a button taking space.
 1376              .background(
 1377                  Button("") { coach.redial() }
 1378                      .keyboardShortcut("r", modifiers: .command)
 1379                      .opacity(0).frame(width: 0, height: 0)
 1380                      .allowsHitTesting(false)
 1381                      .disabled(!calledAlready)
 1382              )
 1383          }
 1384      }
 1385  
 1386      private func bigButton(_ title: String, icon: String, color: Color = Brand.go, action: @escaping () -> Void) -> some View {
 1387          Button(action: action) {
 1388              HStack(spacing: 12) {
 1389                  Image(systemName: icon).font(.title3)
 1390                  // Shorter words when the button is narrow, never "START CALLING LI…".
 1391                  ViewThatFits(in: .horizontal) {
 1392                      ForEach(Self.shorter(title), id: \.self) { t in
 1393                          Text(t).font(.title3.weight(.bold)).lineLimit(1).fixedSize()
 1394                      }
 1395                      Text(title).font(.title3.weight(.bold)).lineLimit(1)
 1396                  }
 1397                  Spacer(minLength: 0)
 1398              }
 1399              .frame(maxWidth: .infinity)
 1400              .padding(.vertical, 8)
 1401          }
 1402          .buttonStyle(BrandPrimaryButton(color: color))
 1403      }
 1404  
 1405      /// The button's title, then shorter ones for narrow windows.
 1406      private static func shorter(_ title: String) -> [String] {
 1407          switch title {
 1408          case "START CALLING LIST": return ["START CALLING LIST", "START CALLING", "START"]
 1409          case "STOP CALLING": return ["STOP CALLING", "STOP"]
 1410          case "Next Person": return ["Next Person", "Next"]
 1411          default: return [title]
 1412          }
 1413      }
 1414  
 1415      private func smallButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
 1416          Button(action: action) {
 1417              HStack(spacing: 8) {
 1418                  if let icon { Image(systemName: icon) }
 1419                  ViewThatFits(in: .horizontal) {
 1420                      ForEach(Self.shorter(title), id: \.self) { t in
 1421                          Text(t).font(.body.weight(.semibold)).lineLimit(1).fixedSize()
 1422                      }
 1423                  }
 1424              }
 1425              .frame(minWidth: 70)
 1426              .padding(.vertical, 8)
 1427          }
 1428          .buttonStyle(BrandQuietButton())
 1429      }
 1430  
 1431      private var canCall: Bool {
 1432          guard let d = coach.leads.details, !d.doNotCall, d.callNumber != nil, !coach.dialing else { return false }
 1433          return Aircall.canPlaceCalls
 1434      }
 1435  
 1436      private var callTitle: String {
 1437          guard let d = coach.leads.details else { return "Loading..." }
 1438          if d.doNotCall { return "Do Not Call" }
 1439          if !Aircall.canPlaceCalls { return "Set up Aircall first (gear)" }
 1440          return d.callNumber != nil ? "Call \(d.name)" : "No phone number"
 1441      }
 1442  
 1443      // MARK: Up next: the one person everything refers to
 1444  
 1445      /// The person whose Salesforce record is open (the same one the phone, the script and Salesforce use).
 1446      private var prospect: (name: String, title: String?, company: String?, position: Int?, total: Int)? {
 1447          if coach.leads.isActive {
 1448              guard let d = coach.leads.details else { return nil }
 1449              let name = Salesforce.isPlaceholderName(d.name) ? (d.company ?? d.name) : d.name
 1450              return (name, d.title, d.company, coach.leads.index + 1, coach.leads.rows.count)
 1451          }
 1452          guard coach.calling != nil, currentName != "them" else { return nil }
 1453          let records = coach.callList.records
 1454          return (currentName, coach.recordTitle, coach.recordCompany, coach.callList.currentIndex().map { $0 + 1 }, records.count)
 1455      }
 1456  
 1457      /// UP NEXT before a call, ON CALL during it, then the call's outcome until the rep moves on.
 1458      @ViewBuilder private var prospectCard: some View {
 1459          if let p = prospect {
 1460              let onCall = coach.status != .ready
 1461              let called = !onCall && coach.currentAttemptKey != nil
 1462              VStack(alignment: .leading, spacing: 8) {
 1463                  HStack(spacing: 6) {
 1464                      if onCall { Circle().fill(Color.green).frame(width: 8, height: 8) }
 1465                      Text(([onCall ? "ON CALL" : (called ? "CALLED" : "UP NEXT")]
 1466                            + [p.position.map { "\($0) OF \(p.total)" }].compactMap { $0 }).joined(separator: " · "))
 1467                          .font(.caption.weight(.semibold)).tracking(0.6)
 1468                          .foregroundStyle(onCall ? Color.green : Brand.subtext)
 1469                      Spacer(minLength: 0)
 1470                      if !onCall {
 1471                          Button { coach.previousLead() } label: { Image(systemName: "chevron.left") }
 1472                              .buttonStyle(.brandLink).help("The person before")
 1473                          Button { coach.nextLead(dial: false) } label: { Image(systemName: "chevron.right") }
 1474                              .buttonStyle(.brandLink).help("Skip to the next person")
 1475                              .disabled(coach.dialing)
 1476                      }
 1477                  }
 1478                  HStack(alignment: .center, spacing: 12) {
 1479                      VStack(alignment: .leading, spacing: 4) {
 1480                          Text(p.name).font(.title.weight(.bold)).foregroundStyle(Brand.text).lineLimit(1).minimumScaleFactor(0.7)
 1481                          let line = [p.title, p.company].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
 1482                          if !line.isEmpty {
 1483                              Text(line).font(.body).foregroundStyle(Brand.subtext).lineLimit(1)
 1484                          }
 1485                          if called, let outcome = coach.recordStatus, !outcome.isEmpty {
 1486                              Text(outcome).font(.callout.weight(.semibold)).foregroundStyle(Brand.text)
 1487                                  .padding(.horizontal, 8).padding(.vertical, 3)
 1488                                  .background(Brand.quiet, in: Capsule())
 1489                          }
 1490                      }
 1491                      Spacer(minLength: 0)
 1492                      Text(Self.initials(p.name)).font(.title3.weight(.semibold)).foregroundStyle(Brand.text)
 1493                          .frame(width: 52, height: 52)
 1494                          .background(Brand.blue.opacity(0.35), in: Circle())
 1495                  }
 1496              }
 1497              .padding(CardStyle.padding)
 1498              .frame(maxWidth: .infinity, alignment: .leading)
 1499              .background(Brand.card, in: RoundedRectangle(cornerRadius: CardStyle.radius))
 1500              .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.controlEdge, lineWidth: 1))
 1501              .overlay(alignment: .leading) {
 1502                  RoundedRectangle(cornerRadius: 2).fill(Brand.teal).frame(width: 3).padding(.vertical, 14)
 1503              }
 1504              .animation(.easeOut(duration: 0.15), value: p.name)
 1505          }
 1506      }
 1507  
 1508      private static func initials(_ name: String) -> String {
 1509          name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
 1510      }
 1511  
 1512      /// The person on screen now, from the Salesforce tab (e.g. Lead "Burcin Sonmezer").
 1513      private var currentName: String {
 1514          guard let name = Screener.fullName(coach.calling) else { return "them" }
 1515          // "Unknown Unknown" is a placeholder: show the company from the open page instead.
 1516          if Salesforce.isPlaceholderName(name), let company = coach.recordCompany, !company.isEmpty { return company }
 1517          return name
 1518      }
 1519  
 1520      /// Nobody left to call today on this list (or a Salesforce list opened with nobody due).
 1521      private var listRanOut: Bool {
 1522          guard coach.status == .ready else { return false }
 1523          // From the real list, not from a flag: people loaded, and none of them can be called right now.
 1524          if coach.leads.isActive {
 1525              return coach.leads.current == nil && !coach.leads.loading && !coach.leads.rows.isEmpty
 1526          }
 1527          return coach.callList.state == .endOfList
 1528      }
 1529  
 1530      /// A Salesforce list that loaded with nobody on it who can be called (no phone, Do Not Call, taken off).
 1531      private var listIsEmpty: Bool {
 1532          coach.status == .ready && coach.leads.isActive && coach.leads.selected != nil
 1533              && coach.leads.rows.isEmpty && !coach.leads.loading
 1534      }
 1535  
 1536      private var backEnabled: Bool {
 1537          coach.status == .ready ? !coach.callList.records.isEmpty : coach.canGoBack
 1538      }
 1539  
 1540      private var nextEnabled: Bool {
 1541          if coach.status != .ready { return true }
 1542          switch coach.callList.state {
 1543          case .ready, .endOfList: return true // at the end, Next loads more people from the list
 1544          default: return false
 1545          }
 1546      }
 1547  
 1548      /// One message above the buttons at a time, the most important first:
 1549      /// a call problem, the countdown, "send the text", then why Next can't move on.
 1550      @ViewBuilder private var bottomBanner: some View {
 1551          if let until = coach.breakUntil {
 1552              TimelineView(.periodic(from: .now, by: 1)) { context in
 1553                  let left = max(0, Int(until.timeIntervalSince(context.date)))
 1554                  HStack(spacing: 8) {
 1555                      Image(systemName: "cup.and.saucer.fill")
 1556                      Text(String(format: "Break: %d:%02d left. Nice block.", left / 60, left % 60)).font(.callout.weight(.semibold))
 1557                      Spacer(minLength: 0)
 1558                      Button("Skip break") { coach.endBreak() }.controlSize(.large)
 1559                  }
 1560                  .padding(10)
 1561                  .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
 1562              }
 1563          } else if coach.awaitingOutcome {
 1564              VStack(alignment: .leading, spacing: 8) {
 1565                  outcomeBar
 1566                  if let left = coach.autoNextIn { autoNextBar(left) }
 1567              }
 1568          } else if listRanOut {
 1569              let why = CalledToday.breakdown(coach.leads.isActive ? coach.leads.rows.map(\.id) : coach.callList.records.map(\.id))
 1570              VStack(alignment: .leading, spacing: 8) {
 1571                  Text(why.calledToday > 0 ? "Nobody left to call right now on \(campaigns.selected.name). Nice work."
 1572                                           : "Nobody is due to call right now on \(campaigns.selected.name).")
 1573                      .font(.callout.weight(.semibold))
 1574                      .fixedSize(horizontal: false, vertical: true)
 1575                  Button(showWhy ? "Hide why" : "Why?") { showWhy.toggle() }.buttonStyle(.brandLink).font(.caption)
 1576                  if why.noMobile > 0, why.noMobile * 2 >= why.total {
 1577                      // Most of the list is blocked by one setting: say so up front, with the fix.
 1578                      Text("\(why.noMobile) of \(why.total) people have no Mobile number, and Mobile numbers only is on.")
 1579                          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1580                      Button("Call their other numbers too") { MobileOnly.setOn(false) }
 1581                  }
 1582                  if showWhy {
 1583                  VStack(alignment: .leading, spacing: 2) {
 1584                      Text("\(why.total) people on this list:")
 1585                      if why.calledToday > 0 { Text("• \(why.calledToday) called today") }
 1586                      if why.comeBackLater > 0 { Text("• \(why.comeBackLater) come back on another day") }
 1587                      if why.takenOff > 0 { Text("• \(why.takenOff) taken off (no answer, bad number, or not interested)") }
 1588                      if why.planDone > 0 { Text("• \(why.planDone) finished the plan, or picked up") }
 1589                      if why.noMobile > 0 { Text("• \(why.noMobile) have no Mobile number (Mobile numbers only is on)") }
 1590                      if why.noNumber > 0 { Text("• \(why.noNumber) have no phone number in Salesforce") }
 1591                      if why.otherTimeZone > 0 { Text("• \(why.otherTimeZone) are in another time zone") }
 1592                  }
 1593                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1594                  }
 1595                  if let zone = TimeZoneFilter.selected {
 1596                      let held = coach.leads.isActive ? coach.leads.heldByTimeZone : coach.callList.heldByTimeZone
 1597                      Text("You're only calling \(zone.label) time. \(held) more people are waiting in other time zones.")
 1598                          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1599                      if held > 0 {
 1600                          Button("Call all time zones") { coach.setTimeZoneFilter(nil) }
 1601                      }
 1602                  }
 1603                  if let next = nextCampaign {
 1604                      if let left = nextListIn {
 1605                          countdownBar("Starting \(next.name) in \(left)", left: left) { stopNextListCountdown() }
 1606                      }
 1607                      Button("Start next list: \(next.name)") { stopNextListCountdown(); switchTo(next) }
 1608                          .buttonStyle(.borderedProminent)
 1609                  } else {
 1610                      Text("Pick another Salesforce list at the top.")
 1611                          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1612                  }
 1613              }
 1614              .padding(10)
 1615              .frame(maxWidth: .infinity, alignment: .leading)
 1616              .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
 1617          } else if listIsEmpty {
 1618              VStack(alignment: .leading, spacing: 6) {
 1619                  Text("No one on \(coach.leads.selected?.label ?? "this list") can be called.")
 1620                      .font(.callout.weight(.semibold))
 1621                  Text("Everyone is missing a phone number, is marked Do Not Call, or was taken off the list. Check the list in Salesforce, or pick another one.")
 1622                      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1623              }
 1624              .padding(10)
 1625              .frame(maxWidth: .infinity, alignment: .leading)
 1626              .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
 1627          } else if let message = coach.callMessage {
 1628              HStack(alignment: .top, spacing: 6) {
 1629                  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
 1630                  Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
 1631                  Spacer(minLength: 0)
 1632                  Button {
 1633                      coach.callMessage = nil
 1634                  } label: { Image(systemName: "xmark") }
 1635                  .buttonStyle(.borderless)
 1636              }
 1637              .padding(10)
 1638              .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
 1639          } else if let left = coach.autoNextIn {
 1640              autoNextBar(left)
 1641          } else if let detail = coach.gettingReadyDetail {
 1642              HStack(spacing: 8) {
 1643                  ProgressView().controlSize(.small)
 1644                  Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
 1645              }
 1646          } else if coach.waitingForText {
 1647              if let left = coach.textSendIn {
 1648                  VStack(alignment: .leading, spacing: 6) {
 1649                      countdownBar("Sending the text in \(left)", left: left) { coach.stopTextCountdown() }
 1650                      Button("Skip text") { coach.startNextSequence() }.buttonStyle(.brandLink).font(.caption)
 1651                  }
 1652              } else {
 1653              HStack(spacing: 8) {
 1654                  Text(coach.autoDial ? "Send the text. Then the next person loads and the call starts." : "Send the text. Then the next person loads.")
 1655                      .font(.callout).fixedSize(horizontal: false, vertical: true)
 1656                  Spacer(minLength: 0)
 1657                  Button("Skip text") { coach.startNextSequence() }
 1658              }
 1659              .padding(10)
 1660              .brandCard(radius: 10)
 1661              }
 1662          } else if let hint = nextHint, !coach.leads.isActive {
 1663              Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1664          }
 1665      }
 1666  
 1667      /// Why Next can't move on, shown as a line above the buttons (never squeezed into a button).
 1668      private var nextHint: String? {
 1669          guard coach.status == .ready else { return nil }
 1670          switch coach.callList.state {
 1671          case .needsList: return "Open your list in Salesforce, in Chrome. Then the app knows who to call next."
 1672          case .needsChromeSetting: return "Chrome needs one setting. At the top of your screen: click View, then Developer, then Allow JavaScript from Apple Events."
 1673          case .endOfList: return "You called everyone the app can see. Click Next to load more people."
 1674          case .ready: return nil
 1675          }
 1676      }
 1677  
 1678      /// The preview on the Next button: the next step during a call, the next lead between calls.
 1679      private var nextTitle: String {
 1680          if coach.status != .ready {
 1681              return coach.nextStepName.map { "\($0) question" } ?? "New line"
 1682          }
 1683          switch coach.callList.state {
 1684          case .ready: return "START CALLING LIST"
 1685          case .needsList, .needsChromeSetting, .endOfList: return "Next"
 1686          }
 1687      }
 1688  }
 1689  
 1690  /// Opener -> Discovery -> Value -> Close, with the current step highlighted.
 1691  struct StageBar: View {
 1692      let steps: [String]
 1693      let current: Int
 1694      let active: Bool
 1695  
 1696      var body: some View {
 1697          HStack(spacing: 4) {
 1698              ForEach(steps.indices, id: \.self) { i in
 1699                  Text(steps[i])
 1700                      .font(.caption.weight(i == current ? .semibold : .regular))
 1701                      .foregroundStyle(i == current && active ? Color.primary : (i < current ? Color.secondary : Color.secondary.opacity(0.5)))
 1702                      .padding(.horizontal, 8)
 1703                      .padding(.vertical, 3)
 1704                      .background(i == current && active ? Color.secondary.opacity(0.2) : .clear, in: Capsule())
 1705                  if i < steps.count - 1 {
 1706                      Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
 1707                  }
 1708              }
 1709          }
 1710          .frame(maxWidth: .infinity, alignment: .leading)
 1711      }
 1712  }
 1713  
 1714  /// Onboarding and how-to, out of the way of the live screen.
 1715  struct HelpView: View {
 1716      @Environment(\.dismiss) private var dismiss
 1717  
 1718      var body: some View {
 1719          ScrollView {
 1720              VStack(alignment: .leading, spacing: 12) {
 1721                  Text("Help").font(.title2.weight(.semibold))
 1722                  Text("New here? Click the gear, then \"Show me around\". It points at every button.")
 1723                      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 1724                  section("1. Get ready (one time)", [
 1725                      "Click the gear, then Set up. Do each step. Each one turns green when it's done.",
 1726                      "Aircall phone (on the right): sign in one time and set yourself to Available. If it ever freezes: gear, then Settings, then Get help, then Reload the Aircall phone.",
 1727                      "Open your list in Salesforce, in Chrome. The app reads it by itself.",
 1728                  ])
 1729                  section("2. Pick who to call", [
 1730                      "At the top, pick your Salesforce list. Under it, pick the script: what to say.",
 1731                      "Next to it, pick a time zone. Or pick \"Start in the East, go West\".",
 1732                  ])
 1733                  section("3. Make a call", [
 1734                      "Click the big Call button. The app calls their Mobile. If there's no Mobile, it calls their Phone.",
 1735                      "Read the big line out loud. It changes each time they talk.",
 1736                      "Tell them the call is being written down. Some states require it.",
 1737                      "The app knows when the call ends. If it misses, click End call.",
 1738                  ])
 1739                  section("4. After the call", [
 1740                      "No answer the first time: the app calls them one more time. Click Wait to stop it.",
 1741                      "Voicemail: read the message on the screen after the beep.",
 1742                      "Then go top to bottom: say how it went, send the LinkedIn note, then send the text.",
 1743                      "Sending the text loads the next person. Then the app calls them after a short countdown.",
 1744                      "Bad numbers are skipped for you.",
 1745                  ])
 1746                  section("5. The plan for each person", [
 1747                      "We call each person on 5 days: day 1, 2, 5, 8 and 16. Two calls each day.",
 1748                      "They get a voicemail on day 1. Texts go out on days 1, 2 and 16.",
 1749                      "If they pick up, the plan stops for them.",
 1750                  ])
 1751                  section("6. Settings", [
 1752                      "Above the Call button: check Auto dial (the app calls the next person by itself) and Call twice (it tries each person one more time).",
 1753                      "Gear, then Settings, then What's working: see which lines work best.",
 1754                      "Something broken? Gear, then Settings, then Get help, then Send a problem report.",
 1755                  ])
 1756                  HStack {
 1757                      Spacer()
 1758                      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
 1759                  }
 1760              }
 1761              .padding(16)
 1762          }
 1763          .frame(width: 370, height: 560)
 1764      }
 1765  
 1766      private func section(_ title: String, _ lines: [String]) -> some View {
 1767          VStack(alignment: .leading, spacing: 4) {
 1768              Text(title).font(.headline)
 1769              ForEach(lines, id: \.self) { line in
 1770                  Text("• \(line)").font(.callout).fixedSize(horizontal: false, vertical: true)
 1771              }
 1772          }
 1773      }
 1774  }
 1775  
 1776  // MARK: - Opener scoreboard
 1777  
 1778  /// Your own experiment: how each opener does on your calls.
 1779  /// Shown as a section of Script Lab.
 1780  struct ScoreboardView: View {
 1781      @ObservedObject var book: OpenerBook
 1782      @State private var confirmReset = false
 1783  
 1784      var body: some View {
 1785          VStack(alignment: .leading, spacing: 10) {
 1786              Text("Which first line works best").font(.headline)
 1787              Text("Each first line gets \(OpenerBook.warmUp) tries. After that, the app uses the best ones more often.")
 1788                  .font(.callout).foregroundStyle(.secondary)
 1789                  .fixedSize(horizontal: false, vertical: true)
 1790  
 1791              Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
 1792                  GridRow {
 1793                      Text("First line").bold()
 1794                      Text("Calls").bold()
 1795                      Text("Avg score").bold()
 1796                      Text("Goal").bold()
 1797                  }
 1798                  .font(.caption)
 1799                  .foregroundStyle(.secondary)
 1800                  ForEach(ranked, id: \.opener.id) { row in
 1801                      GridRow {
 1802                          HStack(spacing: 6) {
 1803                              if row.opener.id == leaderID { Text("🏆") }
 1804                              if row.opener.id == book.current.id { Image(systemName: "arrow.right.circle.fill").foregroundStyle(Brand.blue) }
 1805                              Text(row.opener.name)
 1806                          }
 1807                          Text("\(row.score.calls)").monospacedDigit()
 1808                          Text(row.score.calls == 0 ? "-" : "\(row.score.average)").monospacedDigit()
 1809                          Text(percent(row.score.goals, of: row.score.calls)).monospacedDigit()
 1810                      }
 1811                  }
 1812              }
 1813  
 1814              Text("Score: \(CallScore.explanation) Voicemails and no-answers don't count.")
 1815                  .font(.caption).foregroundStyle(.secondary)
 1816                  .fixedSize(horizontal: false, vertical: true)
 1817  
 1818              Button("Erase these scores", role: .destructive) { confirmReset = true }
 1819                  .confirmationDialog("Erase every first line's score?", isPresented: $confirmReset) {
 1820                      Button("Reset", role: .destructive) { book.reset() }
 1821                  }
 1822          }
 1823      }
 1824  
 1825      private var ranked: [(opener: Opener, score: OpenerScore)] {
 1826          Opener.all.map { ($0, book.scores[$0.id] ?? OpenerScore()) }
 1827              .sorted { rate($0.score) > rate($1.score) }
 1828      }
 1829  
 1830      /// Leader needs at least 5 calls so one lucky call doesn't win.
 1831      private var leaderID: String? {
 1832          ranked.first { $0.score.calls >= 5 }?.opener.id
 1833      }
 1834  
 1835      private func rate(_ s: OpenerScore) -> Double {
 1836          s.calls == 0 ? -1 : Double(s.points) / Double(s.calls)
 1837      }
 1838  
 1839      private func percent(_ part: Int, of whole: Int) -> String {
 1840          whole == 0 ? "-" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
 1841      }
 1842  }
 1843  
 1844  // MARK: - Voicemail follow-ups
 1845  
 1846  /// After a voicemail: send the text in one click (Aircall) and open LinkedIn with the note copied.
 1847  /// Stays after the call until both are done or it's closed.
 1848  struct FollowUpCard: View {
 1849      @AppStorage("linkedInBotSend") private var autoLinkedIn = true
 1850      @Binding var followUp: FollowUp?
 1851      /// The card is for someone other than the person on screen now.
 1852      var isLastPerson = false
 1853      /// Today's steps for this person (from the 21-day plan).
 1854      var steps: [(title: String, done: Bool)] = []
 1855      var canSend: Bool
 1856      var onSend: () -> Void
 1857      var onLinkedIn: () -> Void
 1858      var onLinkedInMessage: () -> Void
 1859      var onSetupAircall: () -> Void
 1860      /// Opens their LinkedIn profile (any day, nothing copied).
 1861      var onProfile: () -> Void = {}
 1862  
 1863      var body: some View {
 1864          if let f = followUp {
 1865              VStack(alignment: .leading, spacing: 10) {
 1866                  HStack {
 1867                      Text((isLastPerson ? "Last call: " : "Today for ") + (f.prospect ?? "them")).font(.headline)
 1868                      Spacer()
 1869                      // Their profile, any day, right away (the connection note below waits for its words).
 1870                      Button(f.linkedinURL == nil ? "Find on LinkedIn" : "LinkedIn profile") { onProfile() }
 1871                          .buttonStyle(.brandLink).font(.caption)
 1872                          .help(f.linkedinURL == nil ? "No LinkedIn link in Salesforce: searches LinkedIn for them" : "Opens their LinkedIn profile")
 1873                      Button {
 1874                          followUp = nil
 1875                      } label: {
 1876                          Image(systemName: "xmark")
 1877                      }
 1878                      .buttonStyle(.borderless)
 1879                      .help("Close")
 1880                  }
 1881  
 1882                  // Today's plan for this person, checked off as it happens.
 1883                  if !steps.isEmpty {
 1884                      Text(steps.map { ($0.done ? "✓ " : "○ ") + $0.title }.joined(separator: "   "))
 1885                          .font(.caption.weight(.medium))
 1886                          .foregroundStyle(steps.allSatisfy(\.done) ? Color.green : Color.secondary)
 1887                          .fixedSize(horizontal: false, vertical: true)
 1888                  }
 1889  
 1890                  // LinkedIn, only on the plan's LinkedIn days. First touch (connect day): both the
 1891                  // connection note and the message, so neither waits on whether they're connected.
 1892                  // The plan's last call day: just the message.
 1893                  // Always shown, so the rep never hunts for them. The plan only asks for them on some
 1894                  // days; on other days they're marked "extra".
 1895                  Group {
 1896                      if !f.linkedInMessageFirst || f.linkedinDone {
 1897                          row(done: f.linkedinDone, title: "LinkedIn connection note" + (f.linkedInDue ? "" : " (extra today)"), message: f.linkedin) {
 1898                              if f.linkedinDone {
 1899                                  Button("Open again") { onLinkedIn() }.buttonStyle(.brandLink)
 1900                              } else {
 1901                                  Button(f.linkedinURL == nil ? "Search LinkedIn + copy note" : "Open profile + copy note") { onLinkedIn() }
 1902                                      .keyboardShortcut("l", modifiers: .command)
 1903                                      .buttonStyle(.bordered)
 1904                                      .disabled(f.linkedin.isEmpty)
 1905                              }
 1906                          }
 1907                          Toggle("Send LinkedIn connection request automatically", isOn: $autoLinkedIn)
 1908                              .toggleStyle(.checkbox).font(.caption)
 1909                              .help("On: the app sends it in Chrome in the background while you keep calling. Off: it opens their profile and types the note, you click Send, then the next call starts.")
 1910                          if f.linkedinDone && !f.linkedinMessageDone {
 1911                              Text("Connect, Add a note, Paste, Send.")
 1912                                  .font(.caption).foregroundStyle(.secondary)
 1913                          }
 1914                      }
 1915                      row(done: f.linkedinMessageDone, title: "LinkedIn message" + (f.linkedInDue ? "" : " (extra today)"), message: f.linkedinMessage) {
 1916                          if f.linkedinMessageDone {
 1917                              Button("Copy again") { onLinkedInMessage() }.buttonStyle(.brandLink)
 1918                          } else {
 1919                              Button("Copy message") { onLinkedInMessage() }
 1920                                  .buttonStyle(.bordered)
 1921                                  .disabled(f.linkedinMessage.isEmpty)
 1922                          }
 1923                      }
 1924                      if f.linkedinMessageDone {
 1925                          Text("Copied. Message, Paste, Send.")
 1926                              .font(.caption).foregroundStyle(.secondary)
 1927                      }
 1928                  }
 1929  
 1930                  // Text: only on the plan's text day (the 2nd call day), never to Washington numbers.
 1931                  // Never to Washington numbers (consent law), never without a Mobile.
 1932                  if f.textDue || f.textDone || (!f.noMobile && !Cadence.isWashington(f.phone)) {
 1933                  row(done: f.textDone, title: "Text" + (f.textDue || f.textDone ? "" : " (extra today)"), message: f.text,
 1934                      editable: !f.textDone && !f.text.isEmpty ? textBinding : nil) {
 1935                      if f.textDone {
 1936                          Label("Sent", systemImage: "checkmark").foregroundStyle(.green)
 1937                      } else if canSend {
 1938                          HStack(spacing: 6) {
 1939                              TextField("Their phone", text: phoneBinding)
 1940                                  .textFieldStyle(.roundedBorder)
 1941                                  .frame(width: 130)
 1942                              Button("Send text") { onSend() }
 1943                                  .buttonStyle(.borderedProminent)
 1944                                  .keyboardShortcut("t", modifiers: .command)
 1945                                  .disabled(f.text.isEmpty || f.phone.isEmpty || f.sending)
 1946                          }
 1947                      } else {
 1948                          HStack(spacing: 12) {
 1949                              Button("Copy") { copy(f.text); followUp?.textDone = true }
 1950                              Button("Send from Aircall in one click...") { onSetupAircall() }
 1951                                  .buttonStyle(.brandLink)
 1952                          }
 1953                      }
 1954                  }
 1955                  }
 1956                  if let status = f.textStatus {
 1957                      Text(status).font(.caption)
 1958                          .foregroundStyle(f.sending ? Color.secondary : Color.orange)
 1959                          .fixedSize(horizontal: false, vertical: true)
 1960                  }
 1961              }
 1962              .padding(12)
 1963              .brandCard(radius: 12)
 1964              .onChange(of: f.allDone) {
 1965                  // Close only after something was actually sent (a day with nothing due keeps the card up).
 1966                  if f.allDone, f.textDone || f.linkedinDone || f.linkedinMessageDone {
 1967                      Task {
 1968                          try? await Task.sleep(for: .seconds(4))
 1969                          if followUp?.allDone == true { followUp = nil }
 1970                      }
 1971                  }
 1972              }
 1973          }
 1974      }
 1975  
 1976      private func row<Actions: View>(done: Bool, title: String, message: String, editable: Binding<String>? = nil,
 1977                                       @ViewBuilder actions: () -> Actions) -> some View {
 1978          HStack(alignment: .top, spacing: 8) {
 1979              Image(systemName: done ? "checkmark.circle.fill" : "circle")
 1980                  .foregroundStyle(done ? Color.green : Color.secondary)
 1981              VStack(alignment: .leading, spacing: 4) {
 1982                  Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
 1983                  if let editable {
 1984                      // Click and type to change it before it goes out.
 1985                      TextField("Text message", text: editable, axis: .vertical)
 1986                          .font(.callout)
 1987                          .textFieldStyle(.plain)
 1988                          .lineLimit(2...10)
 1989                          .padding(6)
 1990                          .brandCard(radius: 6)
 1991                          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
 1992                          .help("Click to edit the text before you send it")
 1993                  } else {
 1994                      Text(message.isEmpty ? "Writing..." : message)
 1995                          .font(.callout)
 1996                          .foregroundStyle(message.isEmpty || done ? .secondary : .primary)
 1997                          .textSelection(.enabled)
 1998                          .fixedSize(horizontal: false, vertical: true)
 1999                  }
 2000                  actions().font(.caption)
 2001              }
 2002          }
 2003      }
 2004  
 2005      private var textBinding: Binding<String> {
 2006          Binding(get: { followUp?.text ?? "" }, set: { new in
 2007              guard followUp?.text != new else { return }
 2008              followUp?.text = new
 2009              followUp?.textEdited = true
 2010          })
 2011      }
 2012  
 2013      private var phoneBinding: Binding<String> {
 2014          Binding(get: { followUp?.phone ?? "" }, set: { followUp?.phone = $0 })
 2015      }
 2016  
 2017      private func copy(_ text: String) {
 2018          NSPasteboard.general.clearContents()
 2019          NSPasteboard.general.setString(text, forType: .string)
 2020      }
 2021  }
 2022  
 2023  
 2024  // MARK: - Relationship Status / Lead Status
 2025  
 2026  /// Contact: every Relationship Status. Lead: every Lead Status. Round radio buttons, two columns, Save.
 2027  /// Saves to Salesforce. "Not Quality Prospect", "Negative" and "Unqualified" take them off the list.
 2028  /// The 3 one-click outcomes: the button's name and what it saves, for a Lead or a Contact.
 2029  enum Outcomes {
 2030      static func quick(_ object: String) -> [(label: String, value: String)] {
 2031          object == "Lead"
 2032              ? [("Interested", "Interested"), ("Not now", "Nurturing"), ("Not a fit", "Unqualified")]
 2033              : [("Interested", "Engaged"), ("Not now", "No Relationship"), ("Not a fit", "Not Quality Prospect")]
 2034      }
 2035  }
 2036  
 2037  struct RelationshipCard: View {
 2038      @ObservedObject var coach: CoachModel
 2039      @ObservedObject private var connections = Connections.shared
 2040      @State private var picked: String?
 2041      @State private var pickedFor: String?
 2042      /// Lead + Unqualified: Salesforce requires a reason.
 2043      @State private var reason: String?
 2044      /// Folded: one line with the status and the call count. Opens on click.
 2045      @AppStorage(PrefKey.statusCardOpen) private var open = true
 2046      /// The full list of statuses (folded: just the 3 one-click buttons).
 2047      @State private var showAllStatuses = false
 2048  
 2049      private func quickOutcomes(_ object: String) -> [(label: String, value: String)] { Outcomes.quick(object) }
 2050  
 2051      private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
 2052  
 2053      /// "Calls: 2 of 4" (or "Calls: 3 · picked up" once someone answered).
 2054      private func callsLabel(_ id: String) -> String {
 2055          _ = coach.touchpoints.events.count // redraw after each call
 2056          let p = DialHistory.person(id)
 2057          if Cadence.pickedUp(id) { return "Calls: \(p.dials.count) · picked up" }
 2058          _ = p
 2059          return Cadence.label(for: id)
 2060      }
 2061  
 2062      var body: some View {
 2063          let object = coach.statusObject ?? "Contact"
 2064          let current = picked ?? coach.recordStatus
 2065          VStack(alignment: .leading, spacing: 8) {
 2066              Button {
 2067                  open.toggle()
 2068              } label: {
 2069                  HStack(spacing: 6) {
 2070                      Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
 2071                      Text("How did it go?").font(.callout.weight(.semibold))
 2072                          .help(object == "Lead" ? "Saves to Lead Status in Salesforce" : "Saves to Relationship Status in Salesforce")
 2073                      if !open, let current {
 2074                          Text(current).font(.callout).foregroundStyle(.secondary).lineLimit(1)
 2075                      }
 2076                      Spacer()
 2077                      if let id = coach.statusRecordID {
 2078                          Text(callsLabel(id)).font(.caption).foregroundStyle(.secondary)
 2079                      }
 2080                  }
 2081                  .contentShape(Rectangle())
 2082              }
 2083              .buttonStyle(.plain)
 2084              if open {
 2085              // One click saves and moves on. "Not a fit" also takes them off the list.
 2086              HStack(spacing: 8) {
 2087                  ForEach(quickOutcomes(object), id: \.label) { o in
 2088                      Button {
 2089                          picked = o.value
 2090                          pickedFor = coach.statusRecordID
 2091                          coach.saveStatus(o.value, unqualifiedReason: o.value == "Unqualified" ? "Non-Responsive" : nil)
 2092                      } label: {
 2093                          Text(o.label).font(.callout.weight(.semibold)).frame(maxWidth: .infinity)
 2094                      }
 2095                      .buttonStyle(.bordered)
 2096                      .controlSize(.large)
 2097                      .tint(current == o.value ? Brand.blue : nil)
 2098                      .disabled(coach.savingStatus || !Salesforce.isConnected)
 2099                      .help("Saves \(o.value) in Salesforce")
 2100                  }
 2101              }
 2102              Button(showAllStatuses ? "Fewer choices" : "More choices") { showAllStatuses.toggle() }
 2103                  .buttonStyle(.brandLink).font(.caption)
 2104              if showAllStatuses {
 2105              LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
 2106                  ForEach(Salesforce.statuses(object), id: \.self) { value in
 2107                      Button {
 2108                          picked = value
 2109                          pickedFor = coach.statusRecordID
 2110                      } label: {
 2111                          HStack(spacing: 6) {
 2112                              Image(systemName: current == value ? "largecircle.fill.circle" : "circle")
 2113                                  .foregroundStyle(current == value ? Brand.blue : .secondary)
 2114                              Text(value).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
 2115                          }
 2116                          .contentShape(Rectangle())
 2117                      }
 2118                      .buttonStyle(.plain)
 2119                  }
 2120              }
 2121              if object == "Lead", picked == "Unqualified", picked != coach.recordStatus {
 2122                  Picker("Reason", selection: $reason) {
 2123                      Text("Pick a reason").tag(String?.none)
 2124                      ForEach(Salesforce.unqualifiedReasons, id: \.self) { Text($0).tag(String?.some($0)) }
 2125                  }
 2126                  .font(.callout)
 2127              }
 2128              if let picked, Salesforce.removedStatuses.contains(picked), picked != coach.recordStatus {
 2129                  Text("Save this and we stop calling them.").font(.caption).foregroundStyle(.secondary)
 2130              }
 2131              HStack(spacing: 8) {
 2132                  Button(coach.savingStatus ? "Saving..." : "Save") {
 2133                      if let picked { coach.saveStatus(picked, unqualifiedReason: picked == "Unqualified" ? reason : nil) }
 2134                  }
 2135                  .buttonStyle(.bordered)
 2136                  .disabled(picked == nil || picked == coach.recordStatus || coach.savingStatus || !Salesforce.isConnected
 2137                            || (object == "Lead" && picked == "Unqualified" && reason == nil))
 2138              }
 2139              }
 2140              if !Salesforce.isConnected {
 2141                  Text("To save, sign in to Salesforce: click the gear, then Set up.").font(.caption).foregroundStyle(.secondary)
 2142                      .fixedSize(horizontal: false, vertical: true)
 2143              } else if let message = coach.statusMessage {
 2144                  Text(message).font(.caption).foregroundStyle(.secondary)
 2145                      .fixedSize(horizontal: false, vertical: true)
 2146              }
 2147              }
 2148          }
 2149          .padding(10)
 2150          .frame(maxWidth: .infinity, alignment: .leading)
 2151          .brandCard(radius: 10)
 2152          .onChange(of: coach.statusRecordID) {
 2153              // New person on screen: start fresh.
 2154              if pickedFor != coach.statusRecordID { picked = nil; pickedFor = nil; reason = nil }
 2155          }
 2156      }
 2157  }
 2158  
 2159  /// The transcript under the script card. Watches only the transcript, so words streaming in
 2160  /// don't redraw the rest of the screen.
 2161  struct TranscriptSection: View {
 2162      @ObservedObject var transcript: LiveTranscript
 2163      @Binding var open: Bool
 2164  
 2165      var body: some View {
 2166          VStack(alignment: .leading, spacing: 6) {
 2167              Button {
 2168                  open.toggle()
 2169              } label: {
 2170                  HStack(spacing: 4) {
 2171                      Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
 2172                      Text("Transcript").font(.caption)
 2173                      if !open, let last = transcript.turns.last(where: { $0.speaker == .prospect }) {
 2174                          Text("· \(last.text)").font(.caption).lineLimit(1).foregroundStyle(.tertiary)
 2175                      }
 2176                  }
 2177                  .foregroundStyle(.secondary)
 2178              }
 2179              .buttonStyle(.plain)
 2180              if open {
 2181                  ScrollViewReader { proxy in
 2182                      ScrollView {
 2183                          VStack(alignment: .leading, spacing: 6) {
 2184                              ForEach(transcript.turns) { turn in
 2185                                  line(turn.speaker, turn.text)
 2186                              }
 2187                              ForEach([Speaker.rep, .prospect], id: \.self) { speaker in
 2188                                  if let text = transcript.interim[speaker], !text.isEmpty {
 2189                                      line(speaker, text).opacity(0.5)
 2190                                  }
 2191                              }
 2192                              Color.clear.frame(height: 1).id("end")
 2193                          }
 2194                          .frame(maxWidth: .infinity, alignment: .leading)
 2195                      }
 2196                      .frame(maxHeight: 140)
 2197                      .onChange(of: transcript.turns.count) { proxy.scrollTo("end") }
 2198                  }
 2199              }
 2200          }
 2201      }
 2202  
 2203      private func line(_ speaker: Speaker, _ text: String) -> some View {
 2204          VStack(alignment: .leading, spacing: 1) {
 2205              Text(speaker == .rep ? "You" : "Them").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
 2206              Text(text).font(.callout)
 2207          }
 2208      }
 2209  }
 2210  
 2211  /// One soft green glow around the card when a meeting is booked. Fades in, holds, fades out.
 2212  struct MeetingGlow: View {
 2213      let trigger: Int
 2214  
 2215      var body: some View {
 2216          RoundedRectangle(cornerRadius: 14)
 2217              .strokeBorder(Color.green, lineWidth: 2)
 2218              .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, glow in
 2219                  content.opacity(glow).shadow(color: Color.green.opacity(glow * 0.5), radius: 8 * glow)
 2220              } keyframes: { _ in
 2221                  CubicKeyframe(1.0, duration: 0.35)
 2222                  CubicKeyframe(1.0, duration: 0.8)
 2223                  CubicKeyframe(0.0, duration: 1.4)
 2224              }
 2225              .allowsHitTesting(false)
 2226      }
 2227  }
 2228  
```