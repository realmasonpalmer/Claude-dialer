import XCTest
@testable import CoachCore

/// The six "can break a live call" fixes. Times are injected (secondsWaited), no real sleeps.
final class LiveCallFixTests: XCTestCase {
    // Fix 1a: no utterance end ever comes; after 1.3 s it's an opt-out.
    func testFix1a_TimeoutResolvesAsOptOut() {
        XCTAssertEqual(PendingOptOut.resolve(pending: "Don't call me back.", later: "", utteranceEnded: false, callEnded: false, secondsWaited: 0.5), .wait)
        XCTAssertEqual(PendingOptOut.resolve(pending: "Don't call me back.", later: "", utteranceEnded: false, callEnded: false, secondsWaited: 1.3), .optOut)
    }
    // Fix 1b: the call ends first: still an opt-out.
    func testFix1b_CallEndFlushesAsOptOut() {
        XCTAssertEqual(PendingOptOut.resolve(pending: "Don't call me back.", later: "", utteranceEnded: false, callEnded: true, secondsWaited: 0.2), .optOut)
    }
    // Fix 1c: they keep talking about something else: the pending phrase is still an opt-out.
    func testFix1c_OtherWordsStillOptOut() {
        XCTAssertEqual(PendingOptOut.resolve(pending: "Don't call me back.", later: "I'm busy.", utteranceEnded: false, callEnded: false, secondsWaited: 0.4), .optOut)
    }
    // Fix 1d: "...until Tuesday" is a callback; no timeout opt-out.
    func testFix1d_LaterTimeIsCallback() {
        XCTAssertEqual(PendingOptOut.resolve(pending: "Don't call me back", later: "until Tuesday.", utteranceEnded: false, callEnded: false, secondsWaited: 0.3), .callback)
    }
    // Fix 3: no early draft on a possible opt-out, even one with no final punctuation yet.
    func testFix3_NoEarlyDraftOnPossibleOptOut() {
        XCTAssertNil(EarlyStart.delayMS(for: "Don't call me back."))
        XCTAssertNil(EarlyStart.delayMS(for: "Well don't call me back until"))
    }
    // Fix 5: counts down per full turn.
    func testFix5_GoalCountsTurnsNotChunks() {
        XCTAssertEqual(GoalPendingRule.turnsLeft(after: 2, confirmed: false), 1)
        XCTAssertEqual(GoalPendingRule.turnsLeft(after: 1, confirmed: false), 0)
        XCTAssertTrue(GoalEvidence.confirms("Yeah, let's do that."))
    }
    // Fix 6: a 20-word line 2 s on screen isn't replaced by a screener line; nor over speech.
    func testFix6_ScreenerRespectsReading() {
        var s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: false, secondsSinceShown: 2, repStarted: false,
                             delivered: false, prospectAnsweredSince: false, queued: false, queuedIsForNewTopic: false, lineWords: 20)
        XCTAssertFalse(CoachController.canInterrupt(signals: s))
        s.secondsSinceShown = 6; s.repSpeaking = true
        XCTAssertFalse(CoachController.canInterrupt(signals: s))
        s.repSpeaking = false
        XCTAssertTrue(CoachController.canInterrupt(signals: s))
    }
}
