import XCTest
@testable import CoachCore

/// Replays the November 20 live call (trace: Call started 10:02:05). Each prospect turn, the decision the
/// coach must make in code before any line is written, and whether the lines Haiku produced may show.
/// The script's "Pain open" / "Pain nothing" rows are reconstructed from the trace (the script isn't in the
/// repo): the phrases that matched were a question opener and "I don't know".
final class Nov20ReplayTests: XCTestCase {
    let script = """
    ID | Sounds like | Say
    Pain open | what kind of, how so | When a rep finishes a call today, what happens with the notes and follow-up tasks?
    Pain nothing | i don't know, not much | Fair. If you had to guess, where does a rep lose the most time each week?
    O1 | not interested, no interest | Totally fair. Is that because it's handled, or just not a priority right now?
    """

    func testEachProspectTurn() {
        let answers = ScriptAnswers(script: script)
        let turns: [(said: String, intent: ConversationIntent, instant: Bool, no: Bool)] = [
            ("Hello?", .other, false, false),
            ("What kind of car I mean?", .question, false, false),                 // was: Pain open (wrong)
            ("You... What is this about?", .question, false, false),
            ("What is this called about? This is called out.", .question, false, false),
            ("Are you the one that decides on those types of things?", .question, false, false),
            ("Oh, wait.", .other, false, false),
            ("I I don't know that I'm interested on that.", .rejection, false, true), // the first no
            ("Yeah.", .other, false, false),
            ("I don't know that I'm the right fit for this right now.", .rejection, false, true), // was: Pain nothing (wrong)
        ]
        var nos = 0
        for t in turns {
            XCTAssertEqual(ConversationIntent.classify(t.said), t.intent, t.said)
            XCTAssertEqual(answers.matchInContext(t.said).entry != nil, t.instant, t.said)
            XCTAssertEqual(Rejection.isNo(t.said), t.no, t.said)
            if Rejection.isNo(t.said) { nos += 1 }
        }
        // Two no's: the call closes politely instead of another discovery question.
        XCTAssertTrue(Rejection.callOver(nosSoFar: nos, latest: turns.last!.said))
    }

    func testLinesHaikuWroteOnThisCall() {
        // Shown at 10:03:35: the rep claiming the prospect's role. Must never pass.
        XCTAssertTrue(RoleCheck.speaksAsProspect("Yes, I'm the one who decides on those tools. Do you want a quick look at how your team logs calls?"))
        XCTAssertNil(Think.valid("Yes, I'm the one who decides on those tools."))
        // The answers to "What is this about?" are fine on roles.
        XCTAssertFalse(RoleCheck.speaksAsProspect("It's a free look at how your team logs calls and notes. Is that a headache for you?"))
        XCTAssertFalse(RoleCheck.speaksAsProspect("Who handles sales tools there?"))
    }

    func testScriptAnswersStillWorkWhenTheyFit() {
        let answers = ScriptAnswers(script: script)
        // A plain answer to the rep's question, in context: the row still fires instantly.
        XCTAssertEqual(answers.matchInContext("Not much, honestly").entry?.id, "Pain nothing")
        // The same objection the row is written for.
        XCTAssertEqual(answers.matchInContext("Honestly I'm not interested").entry?.id, "O1")
    }

    func testThinkNudgesFromTheSpec() {
        for good in ["Explain the free AI health check.", "Does Gong handle your follow-ups too?",
                     "Who handles AI and sales tools?", "Thank them and end the call."] {
            XCTAssertNotNil(Think.valid(good), good)
        }
        for bad in ["Find the gap.", "Explore friction.", "Handle the objection.", "Who's the right person? Ask for a name."] {
            XCTAssertNil(Think.valid(bad), bad)
        }
    }
}
