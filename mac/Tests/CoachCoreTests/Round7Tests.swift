import XCTest
@testable import CoachCore

final class Round7Tests: XCTestCase {
    func testReadingTimeHasOnsetBuffer() {
        XCTAssertEqual(CoachMachine.readingTime(words: 0), 2.0)
        XCTAssertEqual(CoachMachine.readingTime(words: 12), 5.5, accuracy: 0.01)
        XCTAssertEqual(CoachMachine.readingTime(words: 30), 6.5)
    }
    func testBrushOffsAreNotNos() {
        XCTAssertFalse(Rejection.isNo("We're good, we already have a process."))
        XCTAssertFalse(Rejection.isNo("Not interested in tools right now, though our CRM data is a mess."))
        XCTAssertTrue(Rejection.isNo("I'm not interested."))
    }
    func testQuestionWithoutQuestionMark() {
        XCTAssertNotNil(RepQuestion.closedQuestion(in: "You guys use Salesforce right"))
        XCTAssertNil(RepQuestion.closedQuestion(in: "We help sales teams."))
    }
}
