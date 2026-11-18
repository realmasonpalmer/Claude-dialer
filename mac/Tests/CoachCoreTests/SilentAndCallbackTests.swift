import XCTest
@testable import CoachCore

final class SilentAndCallbackTests: XCTestCase {
    // MOVE: silent keeps a line that still fits, clears one the talk moved past.
    func testSilentKeepsUsefulClearsOutdated() {
        XCTAssertFalse(SilentRule.clearCurrent(superseded: false, delivered: false, answered: false)) // still useful
        XCTAssertTrue(SilentRule.clearCurrent(superseded: true, delivered: false, answered: false))   // they moved on
        XCTAssertTrue(SilentRule.clearCurrent(superseded: false, delivered: true, answered: true))    // said and answered
    }

    // "Don't call me back until Tuesday" is a callback request, not do-not-call.
    func testCallbackRequestIsNotOptOut() {
        XCTAssertFalse(OptOut.matches("Don't call me back until Tuesday."))
        XCTAssertFalse(OptOut.matches("don't call me back", isFinal: false)) // partial: wait for the rest
        XCTAssertTrue(OptOut.matches("No. No. Just don't call me back."))      // final, nothing after: opt-out
        XCTAssertTrue(OptOut.matches("take me off your list", isFinal: false)) // clear phrase: at once
    }
}
