import XCTest
@testable import CoachCore

final class Phase3RaceTests: XCTestCase {
    // C4: the rep asked while the line was still being written: it's stale.
    func testC4_QuestionWhileStreamingMakesItStale() {
        XCTAssertTrue(QueuedLine.repAskedSinceRequest(requestedAt: 10.0, lastRepQuestionAt: 10.6))
        XCTAssertFalse(QueuedLine.repAskedSinceRequest(requestedAt: 10.0, lastRepQuestionAt: 9.0))
    }

    // H2: an unstarted 20-word line is not replaced at 2.5 s (it needs about 5 s to read).
    func testH2_ReadingTimeProtectsLongLines() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: false, secondsSinceShown: 2.5, repStarted: false,
                             delivered: false, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: true, lineWords: 20)
        XCTAssertFalse(CoachMachine.canReplace(s))
        var later = s; later.secondsSinceShown = 7
        XCTAssertTrue(CoachMachine.canReplace(later))
        // The rep's interim words are on the wire: they're talking, so no swap.
        var reading = later; reading.repStarted = true; reading.repSpeaking = true
        XCTAssertFalse(CoachMachine.canReplace(reading))
    }

    // H6: "Actually, quick question for you." (no question mark) makes the queued line stale.
    func testH6_PivotPhraseIsStale() {
        XCTAssertNotNil(QueuedLine.staleReason(ageSeconds: 1, repWordsSinceQueued: 5, repAskedSinceQueued: false,
                                               repTextSinceQueued: "Actually, quick question for you."))
        XCTAssertNil(QueuedLine.staleReason(ageSeconds: 1, repWordsSinceQueued: 2, repAskedSinceQueued: false, repTextSinceQueued: "Okay, cool."))
    }
}
