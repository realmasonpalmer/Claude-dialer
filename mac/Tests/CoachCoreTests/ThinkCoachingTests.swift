import XCTest
@testable import CoachCore

/// The THINK quality rules (no model call): the move fits, no repeats, grounded in the call, THINK and SAY agree.
final class ThinkCoachingTests: XCTestCase {
    let script = "Sales teams lose hours typing call notes. Free AI health check on how your team uses AI and customer records. Who handles sales tools."

    func problems(_ think: String, say: String, move: String, prospect: String, recent: String = "", answered: [String] = []) -> [String] {
        Think.problems(think: think, say: say, move: move, intent: ConversationIntent.classify(prospect),
                       objectionKind: ObjectionTracker.detect(prospect), latestProspect: prospect,
                       recentText: recent.isEmpty ? prospect : recent, scriptText: script, answeredQuestions: answered)
    }

    func testDirectQuestionMustBeAnsweredFirst() {
        // Nov 20: "What is this about?" got a discovery question.
        let bad = problems("When a rep finishes a call, what happens with the notes?",
                           say: "When a rep finishes a call today, what happens with the notes and follow-up tasks?",
                           move: "discover", prospect: "What is this about?")
        XCTAssertTrue(bad.contains { $0.contains("direct question") }, "\(bad)")
        let good = problems("Explain the free AI health check.",
                            say: "It's a free look at how your team logs calls and notes. Is that a headache for you?",
                            move: "answer", prospect: "What is this about?")
        XCTAssertEqual(good, [])
    }

    func testRejectionGetsAcknowledgementNotAQuestion() {
        let p = "I don't know that I'm the right fit for this right now."
        XCTAssertFalse(problems("Where does your team lose the most time?", say: "Fair. Where does your team lose the most time each week?",
                                move: "discover", prospect: p).isEmpty)
        XCTAssertEqual(problems("Acknowledge. Don't push.", say: "Totally understand. Thanks for your time.", move: "acknowledge", prospect: p), [])
        // But SAY that keeps asking contradicts a stop THINK.
        XCTAssertFalse(problems("Acknowledge. Don't push.", say: "Totally understand. Where does a rep lose time?", move: "acknowledge", prospect: p).isEmpty)
    }

    func testWrongPersonKeepsTheQuestion() {
        let p = "I'm not the right person for this."
        XCTAssertEqual(problems("Who handles AI and sales tools?", say: "Fair. Who handles AI and sales tools on your side?",
                                move: "objection", prospect: p), [])
    }

    func testRepeatedQuestionIsCaught() {
        let answered = ["When a call ends, what happens with the notes and follow-up tasks?"]
        let bad = problems("What happens with the notes after a call?", say: "What happens with the notes after a call?",
                           move: "discover", prospect: "They go into Salesforce later.", answered: answered)
        XCTAssertTrue(bad.contains { $0.contains("already answered") }, "\(bad)")
        XCTAssertTrue(Repeats.same("Where does a rep lose the most time each week?", "Fair. If you had to guess, where does a rep lose the most time each week?"))
        XCTAssertFalse(Repeats.same("Who handles sales tools?", "What happens with the notes after a call?"))
    }

    func testUnrelatedTopicAndAssumedPainAreCaught() {
        let said = "We use Gong, but our team updates Salesforce by hand."
        XCTAssertTrue(problems("How is your quarterly forecast reviewed?", say: "How is your quarterly forecast reviewed?",
                               move: "discover", prospect: said).contains { $0.contains("hasn't come up") })
        XCTAssertTrue(problems("Your team must be wasting hours.", say: "Your team must be wasting hours on notes, right?",
                               move: "acknowledge", prospect: "We use Gong.").contains { $0.contains("assumes a problem") })
        // Grounded in what they said: fine.
        XCTAssertEqual(problems("How much time do those Salesforce updates take?", say: "How much time do those Salesforce updates take your team?",
                                move: "discover", prospect: said), [])
    }

    func testThinkAndSayMustBeTheSameQuestion() {
        let adoption = "Our sales team uses Salesforce, but adoption is poor."
        XCTAssertEqual(problems("What's stopping your team from using Salesforce?", say: "What gets in the way of your team using Salesforce?",
                                move: "discover", prospect: adoption), [])
        // Different question, shared word "Salesforce": not the same move.
        XCTAssertFalse(problems("What's stopping your team from using Salesforce?", say: "How many people use Salesforce each week?",
                                move: "discover", prospect: adoption).isEmpty)
        XCTAssertFalse(problems("Who handles sales tools there?", say: "What is the biggest challenge with your CRM?",
                                move: "discover", prospect: adoption).isEmpty)
    }

    func testMissingOrUnusableThinkIsAProblem() {
        XCTAssertFalse(problems("", say: "What happens after a call?", move: "discover", prospect: "We take lots of calls.").isEmpty)
        XCTAssertFalse(problems("Explore friction.", say: "What happens after a call?", move: "discover", prospect: "We take lots of calls.").isEmpty)
    }

    func testQuestionAnswersCarryTheirStrength() {
        var t = QuestionTracker()
        _ = t.add(turn: "Where do your call notes end up?", from: .rep)
        _ = t.add(turn: "They go into Salesforce, our reps type the call notes in after each call.", from: .prospect)
        XCTAssertTrue(t.promptText.contains("their words show it"), t.promptText)
        var u = QuestionTracker()
        _ = u.add(turn: "Where do your call notes end up?", from: .rep)
        _ = u.add(turn: "Yeah, mostly.", from: .prospect)
        XCTAssertTrue(u.promptText.contains("Probably answered"), u.promptText)
        XCTAssertFalse(u.promptText.contains("their words show it"))
    }

    func testScriptRowsAreOnlyHighConfidence() {
        let answers = ScriptAnswers(script: """
        ID | Sounds like | Say
        Pain nothing | i don't know, not much | Fair. If you had to guess, where does a rep lose the most time each week?
        O1 | not interested, no interest | Totally fair. Is that because it's handled, or just not a priority right now?
        """)
        // Short, the phrase is most of what they said: fires.
        XCTAssertEqual(answers.matchInContext("Not much, honestly").entry?.id, "Pain nothing")
        // A long sentence with the phrase buried in it: doesn't.
        XCTAssertNil(answers.matchInContext("I don't know, we've been thinking about replacing a few tools in the spring, it's complicated").entry)
        // The row would re-ask something already answered: doesn't.
        XCTAssertNil(answers.matchInContext("Not much, honestly",
                                            answeredQuestions: ["Where does a rep lose the most time each week?"]).entry)
    }
}
