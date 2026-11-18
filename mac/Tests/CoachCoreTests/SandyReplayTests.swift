import XCTest
@testable import CoachCore

/// Replay of the Sandy Adkins call (2026-11-18 13:31:07 to 13:32:24), step by step through the
/// coach's decisions. The rep's actual words are the source of truth; the script is the guide.
final class SandyReplayTests: XCTestCase {
    let opener = "Hi Sandy, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"

    // Was: "delivered (62%)" before the rep had asked for the 30 seconds. Now: only once the question is asked.
    func testOpenerDeliveredOnlyWhenItsQuestionIsAsked() {
        let partway = "Hi, Sandy. This is Mason at Clarity Consulting. I know you weren't expecting my call. Can I give you"
        XCTAssertFalse(Delivery.delivered(line: opener, spoken: partway))
        XCTAssertTrue(Delivery.delivered(line: opener, spoken: partway + " can I get thirty seconds just to tell you why I called?"))
    }

    // After "Sure.", the rep explains Clarity in their own words: that's the rep talking, not delivering the old line.
    func testRepExplainingAfterResolvedIsNotDelivering() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: false, repSpeaking: true, secondsSinceShown: 20, repStarted: true,
                             delivered: true, prospectAnsweredSince: true, queued: true, queuedIsForNewTopic: true,
                             lineWords: 25, overlapping: false, repOnLine: true)
        XCTAssertEqual(CoachMachine.state(s), .repTalking)
    }

    // Was: the line written after "Sure." showed 23.6 s later, after the rep had pitched and asked about their CRM.
    // Now: dropped as stale. The rep asked their own question, so no new line is pushed over it.
    func testQueuedLineDroppedWhenRepMovedOn() {
        let repSince = "Cool. So, essentially, what we do is we are... We work with sales and RevOps teams. To, kind of, like, uncover where missed time is. So what, like, CRM are you guys using?"
        let words = repSince.split(separator: " ").count
        XCTAssertNotNil(QueuedLine.staleReason(ageSeconds: 23.6, repWordsSinceQueued: words, repAskedSinceQueued: true))
        // A line queued a moment ago, with the rep only saying "Cool.", still shows.
        XCTAssertNil(QueuedLine.staleReason(ageSeconds: 1.5, repWordsSinceQueued: 1, repAskedSinceQueued: false))
        // The rep pitched in their own words and paused without a question: stale, and a fresh line follows them.
        XCTAssertEqual(QueuedLine.staleReason(ageSeconds: 6, repWordsSinceQueued: 20, repAskedSinceQueued: false),
                       "the rep said 20 words of their own since")
    }

    // Was: 5 early requests (#13 to #17) in 4.5 s during one statement. Now: at most 2.
    func testEarlyDraftsDontBurst() {
        let partials = [
            "Okay. Well, that's something that we use",
            "Okay. Well, that's something that we use internally.",
            "Okay. Well, that's something that we use internally. So it's not",
            "Okay. Well, that's something that we use internally. So it's not something I can discuss",
            "Okay. Well, that's something that we use internally. So it's not something I can discuss outside of here.",
            "Okay. Well, that's something that we use internally. So it's not something I can discuss outside of here. But thank you for calling me.",
        ]
        var last: String?, drafts = 0
        for p in partials where EarlyStart.delayMS(for: p) != nil
            && EarlyStart.shouldRedraft(previous: last, text: p, draftsThisTurn: drafts) {
            last = p; drafts += 1
        }
        XCTAssertLessThanOrEqual(drafts, 2)
        XCTAssertGreaterThanOrEqual(drafts, 1)
    }

    // Was: "already have it". It's a boundary, then a polite goodbye.
    func testBoundaryAndEndingRecognized() {
        XCTAssertEqual(ObjectionTracker.detect("Okay. Well, that's something that we use internally. So it's not something I can discuss"), "won't share")
        XCTAssertEqual(ObjectionTracker.detect("But thank you for calling me. I appreciate your help."), "ending the call")
        var t = ObjectionTracker()
        _ = t.add(turn: "So it's not something I can discuss outside of here.", from: .prospect, turn: 9)
        XCTAssertTrue(t.promptText.contains("don't ask about it again"))
    }

    // Was: a second Haiku request (about 1 s) just to remove "CRM". Now fixed in code.
    func testAbbreviationFixedWithoutAnotherRequest() {
        let fixed = LineRepair.fix("Sorry, Sandy. Which CRM does your sales team use today?")
        XCTAssertNotNil(fixed)
        XCTAssertFalse(fixed!.contains("CRM"))
        XCTAssertNil(LineRepair.fix("Do you use XQZ for that?")) // unknown: still goes back to Claude
    }
}
