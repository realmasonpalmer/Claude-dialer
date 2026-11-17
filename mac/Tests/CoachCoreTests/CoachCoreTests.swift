import XCTest
@testable import CoachCore

final class CoachCoreTests: XCTestCase {
    func sig(line: Bool = true, prospect: Bool = false, rep: Bool = false, shown: Double = 5, started: Bool = false,
             delivered: Bool = false, answered: Bool = false, queued: Bool = false, newTopic: Bool = false, words: Int = 0,
             overlap: Bool = false, onLine: Bool = true, dnc: Bool = false) -> CoachSignals {
        CoachSignals(hasLine: line, prospectSpeaking: prospect, repSpeaking: rep, secondsSinceShown: shown, repStarted: started,
                     delivered: delivered, prospectAnsweredSince: answered, queued: queued, queuedIsForNewTopic: newTopic,
                     lineWords: words, overlapping: overlap, repOnLine: onLine, doNotCall: dnc)
    }

    // Silent reading: a 20-word line is protected for ~5 s even with nobody speaking.
    // An unstarted line never times out: only something new from the prospect replaces it.
    func testUnstartedLineNeverTimesOut() {
        XCTAssertFalse(CoachMachine.canReplace(sig(shown: 60, words: 20)))
        XCTAssertTrue(CoachMachine.canReplace(sig(shown: 3, newTopic: true, words: 20)))
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
        XCTAssertEqual(CoachMachine.state(sig(prospect: true, rep: true, overlap: true)), .interrupted)
        XCTAssertFalse(CoachMachine.canReplace(sig(prospect: true, rep: true, queued: true, newTopic: true)))
    }

    // Never cut off the rep.
    func testNeverReplaceWhileRepSpeaks() {
        XCTAssertFalse(CoachMachine.canReplace(sig(rep: true, started: true, queued: true, newTopic: true)))
        XCTAssertEqual(CoachMachine.state(sig(rep: true, started: true)), .delivering)
    }

    func testProtectsFirstMomentOfReading() {
        XCTAssertFalse(CoachMachine.canReplace(sig(shown: 0.4, newTopic: true)))
        XCTAssertTrue(CoachMachine.canReplace(sig(shown: 2, newTopic: true)))
    }

    func testInterruptionFlagsOutdatedWithoutReplacingMidSentence() {
        XCTAssertEqual(CoachMachine.state(sig(prospect: true, rep: true, started: true, overlap: true)), .interrupted)
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

final class QuestionTrackerTests: XCTestCase {
    func testAskedThenAnswered() {
        var t = QuestionTracker()
        _ = t.add(turn: "How many reps are on the team?", from: .rep)
        let c = t.add(turn: "About twelve.", from: .prospect)
        XCTAssertEqual(t.questions.first?.status, .answered)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(t.promptText.contains("never ask again"))
    }

    func testUhHuhIsNotAnAnswer() {
        var t = QuestionTracker()
        _ = t.add(turn: "Who handles the CRM?", from: .rep)
        _ = t.add(turn: "Mhm", from: .prospect)
        XCTAssertEqual(t.questions.first?.status, .open)
    }

    func testInterruptedAndAbandoned() {
        var t = QuestionTracker()
        _ = t.add(turn: "Is that you guys?", from: .rep)
        _ = t.add(turn: "Wait who is this", from: .prospect, overlapped: true)
        XCTAssertEqual(t.questions.first?.status, .interrupted)
        _ = t.add(turn: "Sorry, quick one. Do you use Salesforce?", from: .rep)
        XCTAssertEqual(t.questions.first?.status, .abandoned)
        XCTAssertEqual(t.questions.last?.status, .open)
    }

    func testProspectQuestionStaysOpenUntilRepAnswers() {
        var t = QuestionTracker()
        _ = t.add(turn: "What does it cost?", from: .prospect)
        XCTAssertTrue(t.promptText.contains("NOT yet answered"))
        _ = t.add(turn: "The health check is free.", from: .rep)
        XCTAssertEqual(t.questions.first?.status, .answered)
    }
}
