import XCTest
@testable import CoachCore

final class Round3FixTests: XCTestCase {
    func testSilentNeverBlanksALinePartwayThrough() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: false, secondsSinceShown: 6, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: false, queuedIsForNewTopic: false, lineWords: 20)
        XCTAssertFalse(SilentRule.clearNow(superseded: true, delivered: false, answered: false, signals: s))
    }

    func testGoalFalsePositivesAndTimes() {
        XCTAssertFalse(GoalEvidence.confirms("Have a great day."))
        XCTAssertFalse(GoalEvidence.mentionsTime("Can I get 30 seconds?"))
        XCTAssertTrue(GoalEvidence.mentionsTime("Does Tuesday at 10 work?"))
        XCTAssertTrue(GoalEvidence.mentionsTime("How about 2:30?"))
    }

    func testCommaEndpointIsMidThought() {
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "So, essentially,",
                                           secondsSinceFinal: 0.5, inFallbackWindow: false))
    }

    func testMoreCallbackPhrases() {
        XCTAssertFalse(OptOut.matches("Don't call me again until next month."))
        XCTAssertTrue(OptOut.hasAmbiguous("don't call me back"))
        XCTAssertTrue(OptOut.matches("Stop calling me.", isFinal: false))
    }
}
