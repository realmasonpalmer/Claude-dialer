import XCTest
@testable import CoachCore

/// Regression tests from the Sean Collins call (2026-11-17): turn taking, interruptions,
/// backchannels, rep talk vs delivering the line, paraphrased delivery, and do not call.
final class TurnTakingTests: XCTestCase {
    typealias T = SpeechTimeline

    // Sean: "Yes." then the rep answers right away. A normal turn, not an interruption,
    // even though the rep starts well inside the old 1.5 s "still talking" window.
    func testNormalTurnTakingIsNotInterruption() {
        var t = T()
        t.update(.prospect, start: 0, end: 1.0, text: "Yes.", isFinal: true)
        XCTAssertEqual(t.update(.rep, start: 1.1, end: 1.5, text: "Hi, Sean.", isFinal: false), .turnTaking)
        let now = t.now(1.5)
        XCTAssertTrue(now.rep); XCTAssertFalse(now.prospect); XCTAssertFalse(now.overlap)
    }

    // Deepgram boundaries jitter: a 0.1 s touch at the hand-off is still turn taking.
    func testBoundaryJitterIsTurnTaking() {
        var t = T()
        t.update(.prospect, start: 0, end: 1.0, text: "We use HubSpot.", isFinal: true)
        XCTAssertEqual(t.update(.rep, start: 0.9, end: 2.0, text: "Got it, how long?", isFinal: true), .turnTaking)
    }

    // The prospect cuts in and the rep stops: a genuine interruption.
    func testGenuineInterruption() {
        var t = T()
        t.update(.rep, start: 0, end: 2.0, text: "So the reason I'm calling is we help teams", isFinal: true)
        XCTAssertEqual(t.update(.prospect, start: 1.5, end: 2.8, text: "Wait, who is this?", isFinal: true), .interruption)
    }

    // Both keep talking: overlapping speech (crosstalk), and the state shows overlap while it lasts.
    func testOverlappingSpeech() {
        var t = T()
        t.update(.rep, start: 0, end: 4.0, text: "and what that means for your reps is more time selling", isFinal: true)
        XCTAssertEqual(t.update(.prospect, start: 1.0, end: 3.0, text: "I really don't think so", isFinal: true), .overlap)
        XCTAssertTrue(t.now(3.0).overlap)
    }

    // "Uh-huh" while the rep talks is not a turn: the rep keeps the floor.
    func testBackchannelDoesNotTakeTheTurn() {
        var t = T()
        t.update(.rep, start: 0, end: 4.0, text: "we update Salesforce after every call for you", isFinal: false)
        XCTAssertEqual(t.update(.prospect, start: 1.5, end: 1.9, text: "Uh-huh.", isFinal: true), .backchannel)
        let now = t.now(2.0)
        XCTAssertTrue(now.rep); XCTAssertFalse(now.prospect); XCTAssertFalse(now.overlap)
    }

    // A late transcript revision (their words ran longer than first heard) re-classifies the turn.
    func testRevisedBoundaryReclassifies() {
        var t = T()
        t.update(.prospect, start: 0, end: 1.0, text: "We already", isFinal: false)
        XCTAssertEqual(t.update(.rep, start: 1.2, end: 2.0, text: "So tell me", isFinal: true), .turnTaking)
        t.update(.prospect, start: 0, end: 1.6, text: "We already have a partner", isFinal: true)
        XCTAssertEqual(t.segments[.rep]?.last?.kind, .interruption)
    }

    // Rep talking is not delivering: "Okay." is unrelated to the line on screen.
    func testRepSpeechSeparateFromDelivering() {
        func sig(onLine: Bool) -> CoachSignals {
            CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 5, repStarted: true,
                         delivered: false, prospectAnsweredSince: false, queued: false, queuedIsForNewTopic: false,
                         lineWords: 20, overlapping: false, repOnLine: onLine)
        }
        XCTAssertEqual(CoachMachine.state(sig(onLine: false)), .repTalking)
        XCTAssertEqual(CoachMachine.state(sig(onLine: true)), .delivering)
        let line = "Can I get 30 seconds to tell you why I called?"
        XCTAssertFalse(Delivery.onLine(line: line, spoken: "Okay."))
        XCTAssertTrue(Delivery.onLine(line: line, spoken: "can I have thirty seconds to tell you"))
    }

    // The exact Sean opener and what the rep said: 62%, from real key words, with the evidence logged.
    func testSeanParaphraseDeliveryEvidence() {
        let line = "Hi Sean, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"
        let said = "Hi, Sean. My name is Mason. I am from Clarity Consulting. And this is a cold call. So I'm wondering if I can just have thirty seconds to tell you why."
        XCTAssertTrue(Delivery.delivered(line: line, spoken: said))
        XCTAssertEqual(Delivery.confidence(line: line, spoken: said), 8.0 / 12.0, accuracy: 0.001) // stems: call/called count once
        XCTAssertEqual(Delivery.rule(line: line, spoken: said), "question") // its question was asked
        let ev = Delivery.evidence(line: line, spoken: said)
        XCTAssertTrue(ev.matched.contains("second") && ev.matched.contains("tell") && ev.matched.contains("why"))
        XCTAssertTrue(ev.missing.contains("expect"))
        // Greeting words alone are not delivery.
        XCTAssertFalse(Delivery.delivered(line: line, spoken: "Hi Sean, Mason from Clarity Consulting."))
    }

    // "Don't call me back" is terminal: do not call state, nothing replaces the goodbye, no early draft.
    func testExplicitDoNotCall() {
        XCTAssertTrue(OptOut.matches("No. No. Just don't call me back."))
        XCTAssertTrue(OptOut.matches("just dont call me back"))
        XCTAssertTrue(OptOut.matches("Don\u{2019}t call me again"))
        XCTAssertFalse(OptOut.matches("Ever again."))
        XCTAssertFalse(OptOut.matches("Call me back next week"))
        let s = CoachSignals(hasLine: true, prospectSpeaking: true, repSpeaking: true, secondsSinceShown: 1, repStarted: true,
                             delivered: false, prospectAnsweredSince: false, queued: true, queuedIsForNewTopic: true,
                             overlapping: true, doNotCall: true)
        XCTAssertEqual(CoachMachine.state(s), .doNotCall)
        XCTAssertFalse(CoachMachine.canReplace(s))
        XCTAssertNil(EarlyStart.delayMS(for: "No. No. Just don't call me back."))
    }

    // Requests #16 and #17: drafts on "No." and "No. No." were wasted. Fragments no longer start a draft.
    func testEarlyStartSkipsFragments() {
        XCTAssertNil(EarlyStart.delayMS(for: "No."))
        XCTAssertNil(EarlyStart.delayMS(for: "No. No."))
        XCTAssertEqual(EarlyStart.delayMS(for: "I'm not interested, thanks."), 200)
        XCTAssertEqual(EarlyStart.delayMS(for: "we already use a partner for that"), 450)
    }

    // The prompt asks for fewer words than the check allows, so a 21 to 25 word line isn't re-written.
    func testPromptWordBudgetUnderCheck() {
        XCTAssertLessThan(LineBudget.promptMax, LineBudget.checkMax)
    }
}
