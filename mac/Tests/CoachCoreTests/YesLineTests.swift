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
