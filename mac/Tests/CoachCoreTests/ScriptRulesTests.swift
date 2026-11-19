import XCTest
@testable import CoachCore

final class ScriptRulesTests: XCTestCase {
    // "Yeah" to "Still with me?" is not a yes: no ready yes line for a check-in.
    func testCheckInIsNotARealAsk() {
        XCTAssertNil(RepQuestion.closedQuestion(in: "Are you still with me?"))
        XCTAssertNil(RepQuestion.closedQuestion(in: "Can you hear me?"))
        XCTAssertNotNil(RepQuestion.closedQuestion(in: "Can I take 30 seconds to say why I called?"))
    }
    // "Let's see" is not a yes; "No. I'm not really interested" is a no.
    func testYesAndNoRules() {
        XCTAssertNotEqual(ProspectReply.kind("Let's see."), .yes)
        XCTAssertTrue(Rejection.isNo("No. I'm not really interested."))
    }
    // An unfilled slot never shows.
    func testOpenSlot() {
        XCTAssertTrue(TokenFill.hasOpenSlot("I have [Day] at [Time]. Which is better?"))
        XCTAssertFalse(TokenFill.hasOpenSlot("I have Tuesday at 10. Which is better?"))
    }
}
