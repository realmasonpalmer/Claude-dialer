import XCTest
@testable import CoachCore

final class ObjectionTrackerTests: XCTestCase {
    func testAddressedIsNotResolved() {
        var t = ObjectionTracker()
        _ = t.add(turn: "We already use a partner for that.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .raised)
        _ = t.add(turn: "Totally fair, how's that going for your reps?", from: .rep, turn: 4)
        XCTAssertEqual(t.objections.first?.status, .addressed) // the rep's answer alone never resolves it
    }

    func testResolvedOnlyFromProspectEvidence() {
        var t = ObjectionTracker()
        _ = t.add(turn: "I'm not interested.", from: .prospect, turn: 1)
        _ = t.add(turn: "Fair enough, can I ask one quick question?", from: .rep, turn: 2)
        let c = t.add(turn: "Okay, go ahead.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .resolved)
        XCTAssertEqual(c.first?.from, .addressed)
        XCTAssertEqual(t.objections.first?.evidenceTurn, 3)
    }

    func testStillOpen() {
        var t = ObjectionTracker()
        _ = t.add(turn: "Not interested.", from: .prospect, turn: 1)
        _ = t.add(turn: "Totally get it, most leaders say that at first.", from: .rep, turn: 2)
        _ = t.add(turn: "No, like I said, not interested.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .stillOpen)
    }

    func testUncertain() {
        var t = ObjectionTracker()
        _ = t.add(turn: "We don't need that.", from: .prospect, turn: 1)
        _ = t.add(turn: "Makes sense, what do you use today for notes?", from: .rep, turn: 2)
        _ = t.add(turn: "Hmm, I'm not sure.", from: .prospect, turn: 3)
        XCTAssertEqual(t.objections.first?.status, .uncertain)
        XCTAssertTrue(t.promptText.contains("unclear"))
    }

    func testNoObjectionNoEntry() {
        var t = ObjectionTracker()
        XCTAssertTrue(t.add(turn: "Yeah, this is Sean.", from: .prospect, turn: 1).isEmpty)
        XCTAssertTrue(t.promptText.isEmpty)
    }
}
