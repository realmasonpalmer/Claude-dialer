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
}
