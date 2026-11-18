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
