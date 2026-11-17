import XCTest
@testable import CoachCore

final class CoachCoreTests: XCTestCase {
    func sig(line: Bool = true, prospect: Bool = false, rep: Bool = false, shown: Double = 5, started: Bool = false,
             delivered: Bool = false, answered: Bool = false, queued: Bool = false, newTopic: Bool = false, words: Int = 0) -> CoachSignals {
        CoachSignals(hasLine: line, prospectSpeaking: prospect, repSpeaking: rep, secondsSinceShown: shown, repStarted: started,
                     delivered: delivered, prospectAnsweredSince: answered, queued: queued, queuedIsForNewTopic: newTopic,
                     lineWords: words)
    }

    // Silent reading: a 20-word line is protected for ~5 s even with nobody speaking.
    func testSilentReadingProtectedByLength() {
        XCTAssertFalse(CoachMachine.canReplace(sig(shown: 3, words: 20)))
        XCTAssertTrue(CoachMachine.canReplace(sig(shown: 5.1, words: 20)))
        XCTAssertTrue(CoachMachine.canReplace(sig(shown: 1.3, words: 4)))
    }

    // Started but not delivered, and the prospect hasn't moved on: keep it.
    func testStartedLineKeptUntilDeliveredOrMovedOn() {
        XCTAssertFalse(CoachMachine.canReplace(sig(started: true)))
        XCTAssertTrue(CoachMachine.canReplace(sig(started: true, delivered: true)))
    }

    // Asking is not the same as being answered.
    func testDeliveryAndResolutionSeparate() {
        XCTAssertEqual(CoachMachine.state(sig(started: true, delivered: true, answered: false)), .reading)
        XCTAssertEqual(CoachMachine.state(sig(started: true, delivered: true, answered: true)), .resolved)
    }

    // Both talking at once.
    func testOverlap() {
        XCTAssertEqual(CoachMachine.state(sig(prospect: true, rep: true)), .interrupted)
        XCTAssertFalse(CoachMachine.canReplace(sig(prospect: true, rep: true, queued: true, newTopic: true)))
    }

    // Never cut off the rep.
    func testNeverReplaceWhileRepSpeaks() {
        XCTAssertFalse(CoachMachine.canReplace(sig(rep: true, started: true, queued: true, newTopic: true)))
        XCTAssertEqual(CoachMachine.state(sig(rep: true, started: true)), .delivering)
    }

    func testProtectsFirstMomentOfReading() {
        XCTAssertFalse(CoachMachine.canReplace(sig(shown: 0.4)))
        XCTAssertTrue(CoachMachine.canReplace(sig(shown: 2)))
    }

    func testInterruptionFlagsOutdatedWithoutReplacingMidSentence() {
        XCTAssertEqual(CoachMachine.state(sig(prospect: true, rep: true, started: true)), .interrupted)
        XCTAssertEqual(CoachMachine.state(sig(started: true, queued: true, newTopic: true)), .superseded)
        XCTAssertTrue(CoachMachine.canReplace(sig(started: true, queued: true, newTopic: true)))
        // Flagged, but never swapped while the rep is still mid-sentence.
        XCTAssertFalse(CoachMachine.canReplace(sig(rep: true, started: true, queued: true, newTopic: true)))
    }

    func testResolvedAfterDeliveryAndAnswer() {
        XCTAssertEqual(CoachMachine.state(sig(started: true, delivered: true, answered: true)), .resolved)
        XCTAssertEqual(CoachMachine.state(sig(line: false)), .idle)
    }

    // Stale answers never overwrite newer ones.
    func testOutOfOrderResponsesDropped() {
        XCTAssertFalse(CoachMachine.isFresh(requestID: 4, latestID: 5))
        XCTAssertTrue(CoachMachine.isFresh(requestID: 5, latestID: 5))
    }

    // Paraphrase counts as delivery.
    func testParaphraseDelivered() {
        let line = "That makes sense. How much time does your team spend updating Salesforce after calls?"
        XCTAssertTrue(Delivery.delivered(line: line, spoken: "Got it, so roughly how much time is your team spending updating Salesforce after each call?"))
        XCTAssertFalse(Delivery.delivered(line: line, spoken: "Okay great, thanks for that."))
    }

    // Known objections answered instantly from the script.
    func testScriptObjectionMatch() {
        let script = """
        OBJECTIONS
        ID | Sounds like | Say | Then
        OBJ email | "send me an email", "just email me" | Happy to. What should it cover so it isn't generic? | back
        OBJ not interested | "not interested", "no thanks" | Fair enough. Is it the timing, or is the system working fine? | no_count +1
        """
        let a = ScriptAnswers(script: script)
        XCTAssertEqual(a.match("Look, can you just email me something?")?.id, "OBJ email")
        XCTAssertEqual(a.match("I'm really not interested")?.id, "OBJ not interested")
        XCTAssertNil(a.match("We use Salesforce for everything"))
    }
}
