import XCTest
@testable import CoachCore

final class Round2FixTests: XCTestCase {
    // 1: a line the rep moved past while it was written is dropped, not shown.
    func testOfferDropsStaleLine() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: false, secondsSinceShown: 8, repStarted: true,
                             delivered: true, prospectAnsweredSince: true, queued: false, queuedIsForNewTopic: true, lineWords: 10)
        XCTAssertEqual(CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: s,
                                             staleReason: "the rep asked their own question since"),
                       .drop("the rep asked their own question since"))
        XCTAssertEqual(CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: s), .show)
    }

    // 4 and 5: a callback isn't an opt-out; "still" isn't "till".
    func testOptOutBoundaries() {
        XCTAssertTrue(OptOut.matches("Don't call me back, I'm still not interested."))
        XCTAssertFalse(OptOut.matches("Don't call me back till Friday."))
        XCTAssertFalse(OptOut.matches("Don't call me back", isFinal: false))
    }

    // 6: a day alone isn't a booked meeting.
    func testGoalNeedsAgreement() {
        XCTAssertFalse(GoalEvidence.confirms("Tuesday is difficult."))
        XCTAssertTrue(GoalEvidence.confirms("Tuesday works."))
        XCTAssertFalse(GoalEvidence.confirms("Yes."))
        XCTAssertTrue(GoalEvidence.confirms("Yes.", afterTimeOffer: true))
    }

    // 7: silent never clears a line the rep is reading or saying.
    func testSilentClearRespectsReading() {
        var s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 1, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: false, queuedIsForNewTopic: false, lineWords: 20)
        XCTAssertFalse(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s))
        s.repSpeaking = false; s.repStarted = false; s.secondsSinceShown = 1
        XCTAssertFalse(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s)) // still reading
        s.secondsSinceShown = 7
        XCTAssertTrue(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s))
    }

    // 8: a breath after "do" or "have" is mid-thought.
    func testMoreHangingWords() {
        XCTAssertTrue(RepTurn.hangs("so what do"))
        XCTAssertTrue(RepTurn.hangs("and we have"))
    }
}
