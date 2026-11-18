import XCTest
@testable import CoachCore

final class Phase7TraceTests: XCTestCase {
    // M5: signals go to the trace as JSON fields.
    func testM5_SignalsAreJSON() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 1.234, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: false, lineWords: 12)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(s.trace))
        XCTAssertEqual(s.trace["rep_speaking"] as? Bool, true)
        XCTAssertEqual(s.trace["seconds_since_shown"] as? Double, 1.23)
    }
}
