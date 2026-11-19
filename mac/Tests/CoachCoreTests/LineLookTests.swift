import XCTest
@testable import CoachCore

final class LineLookTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(LineLook.label(move: "discover", exact: false), "ASK")
        XCTAssertEqual(LineLook.label(move: "objection", exact: false), "HANDLE THE PUSHBACK")
        XCTAssertEqual(LineLook.label(move: "", exact: true), "SAY THIS · EXACT")
        XCTAssertEqual(LineLook.label(move: "weird", exact: false), "SAY THIS")
    }

    func testQuestionStandsOut() {
        let e = LineLook.emphasis("Got it, HubSpot's solid. How are your reps getting call notes into it today?")
        XCTAssertEqual(e?.key, "How are your reps getting call notes into it today?")
        XCTAssertEqual(e?.before, "Got it, HubSpot's solid. ")
        // Question first, statement after.
        let f = LineLook.emphasis("Who updates the CRM after each call? Most teams say the reps do.")
        XCTAssertEqual(f?.key, "Who updates the CRM after each call?")
    }

    func testNoGuessing() {
        XCTAssertNil(LineLook.emphasis("Totally fair. Thanks for your time."))   // no question
        XCTAssertNil(LineLook.emphasis("What CRM? And who owns it?"))           // two questions
        XCTAssertNil(LineLook.emphasis("What CRM do you use?"))                 // the whole line is the question
    }

    func testOrdinaryLineWaitsForProspect() {
        let s = CoachSignals(hasLine: true, prospectSpeaking: true, repSpeaking: false, secondsSinceShown: 60,
                             repStarted: false, delivered: true, prospectAnsweredSince: true, queued: true,
                             queuedIsForNewTopic: true, lineWords: 10, overlapping: false, repOnLine: false, doNotCall: false)
        XCTAssertTrue(CoachController.waitForProspect(s))
        XCTAssertEqual(CoachController.promote(holdLine: false, signals: s, ageSeconds: 1, repWordsSinceQueued: 0,
                                               repAskedSinceQueued: false, repTextSinceQueued: ""), .wait)
        var optOut = s; optOut.doNotCall = true
        XCTAssertFalse(CoachController.waitForProspect(optOut))
        var quiet = s; quiet.prospectSpeaking = false
        XCTAssertFalse(CoachController.waitForProspect(quiet))
    }
}
