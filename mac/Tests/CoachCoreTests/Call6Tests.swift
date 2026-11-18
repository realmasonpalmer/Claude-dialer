import XCTest
@testable import CoachCore

final class Call6Tests: XCTestCase {
    func testTwoNosAndAGo() {
        XCTAssertTrue(Rejection.isNo("No. I'm not really interested."))
        XCTAssertTrue(Rejection.isNo("I don't think this is really relevant to me."))
        XCTAssertFalse(Rejection.callOver(nosSoFar: 1, latest: "I'm not interested."))          // one no: one more try
        XCTAssertTrue(Rejection.callOver(nosSoFar: 2, latest: "Still not interested."))        // two no's: done
        XCTAssertTrue(Rejection.callOver(nosSoFar: 1, latest: "Not relevant to me. So... Yep. Thanks.")) // no + sign-off
    }

    func testFollowRepOncePerStretch() {
        XCTAssertFalse(FollowRepLimit.allowed(repWordsSinceLastAsk: 9, followsThisStretch: 0))
        XCTAssertTrue(FollowRepLimit.allowed(repWordsSinceLastAsk: 16, followsThisStretch: 0))
        XCTAssertFalse(FollowRepLimit.allowed(repWordsSinceLastAsk: 30, followsThisStretch: 1))
    }

    func testEarlyDraftNeedsRealWords() {
        XCTAssertNil(EarlyStart.delayMS(for: "I"))
        XCTAssertNil(EarlyStart.delayMS(for: "Yeah. So I."))
        XCTAssertNotNil(EarlyStart.delayMS(for: "We already use a partner."))
    }
}
