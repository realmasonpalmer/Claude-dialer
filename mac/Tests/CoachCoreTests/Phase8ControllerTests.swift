import XCTest
@testable import CoachCore

final class Phase8ControllerTests: XCTestCase {
    func sig(rep: Bool = false, started: Bool = true, delivered: Bool = false, newTopic: Bool = true, shown: Double = 6) -> CoachSignals {
        CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: rep, secondsSinceShown: shown, repStarted: started,
                     delivered: delivered, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: newTopic, lineWords: 15)
    }

    // H7: the real decision functions the app calls. Never over the rep mid-sentence.
    func testH7_NeverSwapWhileRepSpeaks() {
        XCTAssertEqual(CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: sig(rep: true)), .queue)
        XCTAssertEqual(CoachController.promote(holdLine: false, signals: sig(rep: true), ageSeconds: 1, repWordsSinceQueued: 0,
                                               repAskedSinceQueued: false, repTextSinceQueued: ""), .wait)
    }

    func testH7_StaleDroppedFreshShown() {
        XCTAssertEqual(CoachController.promote(holdLine: false, signals: sig(), ageSeconds: 1, repWordsSinceQueued: 2,
                                               repAskedSinceQueued: false, repTextSinceQueued: "Okay."), .show)
        if case .drop = CoachController.promote(holdLine: false, signals: sig(), ageSeconds: 1, repWordsSinceQueued: 3,
                                                repAskedSinceQueued: false, repTextSinceQueued: "Actually, one last thing.") {} else {
            XCTFail("a pivot should drop the queued line")
        }
        XCTAssertEqual(CoachController.promote(holdLine: true, signals: sig(), ageSeconds: 1, repWordsSinceQueued: 0,
                                               repAskedSinceQueued: false, repTextSinceQueued: ""), .wait)
    }
}
