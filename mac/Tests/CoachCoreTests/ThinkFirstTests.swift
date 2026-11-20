import XCTest
@testable import CoachCore

/// THINK-first rendering. Inputs are written for the test in the format Claude returns (MOVE/THINK/SAY/CUE),
/// including the [row] CUE tags it adds: they are NOT captured model outputs (the Nov 20 log has no raw THINK).
/// "Before" re-creates the old card decision; "after" is the real resolver the card and the trace now use.
final class ThinkFirstTests: XCTestCase {
    let script = """
    ID | Sounds like | Say | Then
    S2 open | yes, sure | Thanks. Peers tell us reps lose hours typing call notes. Sound familiar? | discovery
    O1 | not interested | Totally fair. Can I send one short email and leave it there? | end
    """

    struct Case { let name: String; let prospect: String; let move: String; let think: String; let say: String; let cue: String; let instant: Bool }

    /// The old card: any [tag] on the CUE made it EXACT (SAY); any THINK problem or a word-overlap mismatch made it SAY.
    func before(_ c: Case) -> String {
        if c.cue.hasPrefix("[") || c.instant { return "SAY (shown as EXACT)" }
        let p = problems(c)
        if !p.isEmpty { return "SAY (THINK cleared: \(p.first!))" }
        if Think.valid(c.think) == nil { return "SAY (no usable THINK)" }
        if !Think.agrees(think: c.think, say: c.say, move: c.move) { return "SAY (wording differs)" }
        return "THINK"
    }

    func problems(_ c: Case) -> [String] {
        Think.problems(think: c.think, say: c.say, move: c.move, intent: ConversationIntent.classify(c.prospect),
                       objectionKind: ObjectionTracker.detect(c.prospect), latestProspect: c.prospect,
                       recentText: c.prospect, scriptText: script, answeredQuestions: [])
    }

    /// The new card: EXACT only for an instant script answer or a SAY that is a script Say line; serious THINK
    /// problems suppress the line (fixLine/show); everything else shows THINK.
    func after(_ c: Case) -> (String, String) {
        let exact = c.instant || ExactScript.isApproved(c.say, script: script)
        let p = problems(c)
        let serious = p.contains { !$0.hasPrefix("THINK is missing") && !$0.hasPrefix("THINK isn't usable")
            && !$0.hasPrefix("THINK and SAY aren't the same move") && !$0.hasPrefix("THINK is about something that hasn't come up") }
        if !exact, serious { return ("suppressed", p.first!) }
        let r = Think.resolve(think: c.think, say: c.say, exact: exact, enabled: true, showFull: false, thinkProblems: p)
        return ("\(r.display.rawValue.uppercased()): \(r.text)", r.reason)
    }

    let cases: [Case] = [
        Case(name: "1 valid THINK, CUE tagged by Claude", prospect: "We already use an AI notetaker.", move: "discover",
             think: "Does your AI notetaker update Salesforce too?",
             say: "That's great. Does your AI notetaker also update Salesforce and create follow-up tasks?", cue: "[S5 tools] ask about the CRM", instant: false),
        Case(name: "2 valid THINK, stage tag on CUE", prospect: "Our Salesforce adoption is poor.", move: "discover",
             think: "What happens when your team tries using Salesforce?",
             say: "What happens when your team tries using Salesforce today? Where do they get stuck?", cue: "[S4] dig into the pain", instant: false),
        Case(name: "3 direct question", prospect: "What is this about?", move: "answer",
             think: "Explain the free AI health check.", say: "It's a free look at how your team logs calls and uses AI.", cue: "Answer plainly", instant: false),
        Case(name: "4 paraphrase the matcher rejects", prospect: "We run everything through Salesforce.", move: "discover",
             think: "Is Salesforce your main system?", say: "Is Salesforce where everything lives for your team?", cue: "", instant: false),
        Case(name: "5 instant script answer", prospect: "I'm not interested.", move: "close",
             think: "", say: "Totally fair. Can I send one short email and leave it there?", cue: "From your script: O1", instant: true),
        Case(name: "6 SAY is a script Say line word for word", prospect: "Yes, sure.", move: "discover",
             think: "Ask if lost hours sound familiar.", say: "Thanks. Peers tell us reps lose hours typing call notes. Sound familiar?", cue: "[S2 open] discovery", instant: false),
        Case(name: "7 THINK missing", prospect: "We use Gong.", move: "discover",
             think: "", say: "Nice. Does Gong handle your follow-ups too?", cue: "", instant: false),
        Case(name: "8 clear refusal, discovery", prospect: "I don't know that I'm the right fit for this right now.", move: "discover",
             think: "Where does your team lose the most time?", say: "Fair. Where does your team lose the most time?", cue: "[S5 pain] keep going", instant: false),
        Case(name: "9 acknowledge a refusal", prospect: "I'm not interested.", move: "acknowledge",
             think: "Acknowledge and end politely.", say: "Totally understand. Thanks for your time.", cue: "[O1] end", instant: false),
    ]

    func testBeforeAndAfter() {
        for c in cases {
            let (shown, why) = after(c)
            print("REPLAY|card|\(c.name)|Prospect: \(c.prospect)|MOVE \(c.move)|THINK: \(c.think)|SAY: \(c.say)|CUE: \(c.cue)|before: \(before(c))|after: \(shown)|why: \(why.isEmpty ? "-" : why)")
        }
        // The required outcomes.
        XCTAssertTrue(after(cases[0]).0.hasPrefix("THINK: Does your AI notetaker"))           // 1. valid THINK by default
        XCTAssertTrue(after(cases[1]).0.hasPrefix("THINK: What happens"))                     // 4. a [tag] is not EXACT
        XCTAssertTrue(after(cases[3]).0.hasPrefix("THINK"))                                   // 2. paraphrase stays THINK
        XCTAssertTrue(after(cases[4]).0.hasPrefix("EXACT"))                                   // 5. true EXACT stays EXACT
        XCTAssertTrue(after(cases[5]).0.hasPrefix("EXACT"))
        XCTAssertTrue(after(cases[6]).0.hasPrefix("FALLBACK"))                                // 3. deliberate fallback
        XCTAssertEqual(after(cases[7]).0, "suppressed")                                       // 10. no discovery after a no
        XCTAssertTrue(after(cases[8]).0.hasPrefix("THINK: Acknowledge"))
    }

    func testFullLineDisabledModeAndStale() {
        let say = "That's great. Does your AI notetaker also update Salesforce and create follow-up tasks?"
        // 6. Asking for the full line shows SAY.
        XCTAssertEqual(Think.resolve(think: "Does your AI notetaker update Salesforce too?", say: say, exact: false, enabled: true, showFull: true).text, say)
        // 7. The next line starts on THINK again (the card resets showFull on every new line: cardVersion).
        XCTAssertEqual(Think.resolve(think: "Does your AI notetaker update Salesforce too?", say: say, exact: false, enabled: true, showFull: false).display, .think)
        // 8. THINK off: SAY, labeled as such.
        XCTAssertEqual(Think.resolve(think: "Does your AI notetaker update Salesforce too?", say: say, exact: false, enabled: false, showFull: false).display, .say)
        // 9. A late answer to an older request never replaces the current one.
        XCTAssertFalse(CoachMachine.isFresh(requestID: 4, latestID: 5))
    }

    func testExactNeedsTheScriptLine() {
        XCTAssertTrue(ExactScript.isApproved("Thanks. Peers tell us reps lose hours typing call notes. Sound familiar?", script: script))
        XCTAssertFalse(ExactScript.isApproved("That's great. Does your AI notetaker also update Salesforce?", script: script))
    }
}
