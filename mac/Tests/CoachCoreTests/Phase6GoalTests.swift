import XCTest
@testable import CoachCore

final class Phase6GoalTests: XCTestCase {
    // N4: a "meeting confirmed" line on screen isn't a booked meeting. Their words must agree.
    func testN4_GoalNeedsTheirAgreement() {
        XCTAssertTrue(GoalEvidence.confirms("Tuesday at 10 works for me."))
        XCTAssertTrue(GoalEvidence.confirms("Sure."))
        XCTAssertFalse(GoalEvidence.confirms("Maybe, let me check."))
        XCTAssertFalse(GoalEvidence.confirms("No, I'm not interested."))
        XCTAssertFalse(GoalEvidence.confirms("Sounds good but not this week."))
        XCTAssertFalse(GoalEvidence.confirms("Who is this?"))
    }
}
