import XCTest
@testable import CoachCore

final class MoveAndFinishTests: XCTestCase {
    func testMoveParsed() {
        XCTAssertEqual(Move.parse("MOVE: answer"), .answer)
        XCTAssertEqual(Move.parse("MOVE: Discover"), .discover)
        XCTAssertEqual(Move.parse("MOVE: handle objection"), .objection)
        XCTAssertEqual(Move.parse("MOVE: silent"), .silent)
        XCTAssertNil(Move.parse("SAY: hello"))
    }

    // The transcriber's end-of-speech call ends the turn right away: no 1.5 s wait.
    func testEndpointFirst() {
        XCTAssertFalse(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "We help sales teams.",
                                            secondsSinceFinal: 0.4, inFallbackWindow: true))
        // No end-of-speech call yet: the window is the fallback.
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: false, endpointed: false, lastFinal: "We help sales teams.",
                                           secondsSinceFinal: 0.4, inFallbackWindow: true))
        // A hanging sentence holds even after an end-of-speech call (a breath mid-thought), up to 3 s.
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "take notes and keep",
                                           secondsSinceFinal: 1.7, inFallbackWindow: false))
        XCTAssertFalse(RepTurn.stillTalking(wordsInTheAir: false, endpointed: true, lastFinal: "take notes and keep",
                                            secondsSinceFinal: 3.2, inFallbackWindow: false))
        // Words in the air always win.
        XCTAssertTrue(RepTurn.stillTalking(wordsInTheAir: true, endpointed: true, lastFinal: "Done.", secondsSinceFinal: 0, inFallbackWindow: false))
    }
}
