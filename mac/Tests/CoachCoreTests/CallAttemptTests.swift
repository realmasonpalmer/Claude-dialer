import XCTest
@testable import CoachCore

/// The pickup table: each call runs through the same lifecycle events the app sends.
final class CallAttemptTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func call(_ build: (inout CallAttempt) -> Void, ended: Double = 30, placed: Bool = true) -> CallAttempt {
        var a = CallAttempt(leadID: "00Q1", campaign: "C", startedAt: t0)
        if placed { a.placed(at: at(1)) }
        build(&a)
        a.finalize(endedAt: at(ended))
        return a
    }

    func check(_ a: CallAttempt, human: Bool, prospect: Bool, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.outcome?.humanAnswered, human, "\(name): \(a.outcome?.rawValue ?? "nil") \(a.classificationSource)", file: file, line: line)
        XCTAssertEqual(a.outcome?.prospectReached, prospect, "\(name): \(a.outcome?.rawValue ?? "nil")", file: file, line: line)
    }

    func testPickupTable() {
        check(call({ _ in }, ended: 21), human: false, prospect: false, "No answer 20s")
        check(call({ a in
            a.prospect("Hi, you've reached Dana. Leave a message after the tone.", at: at(4)); a.voicemailDetected()
        }), human: false, prospect: false, "Voicemail greeting")
        check(call({ a in
            a.prospect("For sales press 1. For support press 2.", at: at(3), tag: .menu); a.phoneTreeDetected(); a.badNumberDetected()
        }), human: false, prospect: false, "Phone menu only")
        let menuReception = call({ a in
            a.prospect("For the operator press 0.", at: at(3), tag: .menu); a.phoneTreeDetected()
            a.prospect("Thank you for calling Acme, how can I direct your call?", at: at(12))
        })
        check(menuReception, human: true, prospect: false, "Menu to receptionist")
        check(call({ a in
            a.prospect("Acme, front desk.", at: at(3)); a.rep("Hi, is Dana in?", at: at(5))
            a.prospect("One moment, let me transfer you.", at: at(7)); a.prospect("This is Dana.", at: at(20))
        }), human: true, prospect: true, "Receptionist to prospect")
        check(call({ a in
            a.screenerStarted(); a.prospect("Please say your name and why you're calling.", at: at(3))
        }), human: false, prospect: false, "Screener rejects")
        check(call({ a in
            a.screenerStarted(); a.prospect("Please say your name and why you're calling.", at: at(3))
            a.prospect("Hello, this is Dana.", at: at(15)); a.screenerEnded(personSaid: "Hello, this is Dana.")
        }), human: true, prospect: true, "Screener to prospect")
        check(call({ a in
            a.rep("Hi Dana, it's Mason from Clarity.", at: at(5)); a.prospect("Hi Dana it's Mason from Clarity", at: at(5.5))
        }), human: false, prospect: false, "Rep's own voice transcribed")
        check(call({ a in a.prospect("Sorry, you have the wrong number.", at: at(4)) }), human: true, prospect: false, "Wrong number")
        check(call({ a in
            a.prospect("Hello?", at: at(3)); a.rep("Hi Dana, Mason from Clarity.", at: at(5)); a.prospect("I'm not interested.", at: at(8))
        }), human: true, prospect: true, "Not interested")
        check(call({ a in a.prospect("Yeah, who's this?", at: at(3)) }, ended: 40), human: true, prospect: true, "One sentence, then silence")
        let neverPlaced = call({ _ in }, ended: 2, placed: false)
        XCTAssertEqual(neverPlaced.outcome, .failedConnection)
        XCTAssertEqual(PickupStats([neverPlaced]).placedDials, 0, "Fails before placement: no dial")
    }

    func testMenuWordsBeforeDetectionAreTheMenu() {
        let a = call { a in
            a.prospect("Thank you for calling Acme.", at: at(2)); a.prospect("For billing,", at: at(4))
            a.prospect("press 2.", at: at(5), tag: .menu); a.phoneTreeDetected(); a.prospect("To reach the directory press 9.", at: at(8))
        }
        XCTAssertEqual(a.outcome, .phoneTree, a.classificationSource)
    }

    func testFinalizeOnce() {
        var a = CallAttempt(leadID: "00Q1", campaign: nil, startedAt: t0)
        a.placed(at: at(1)); a.prospect("Hello?", at: at(2))
        XCTAssertTrue(a.finalize(endedAt: at(10)))
        XCTAssertFalse(a.finalize(endedAt: at(99)))
        XCTAssertEqual(a.callEndedAt, at(10))
    }

    func testAppQuitReconciles() {
        // Saved mid-call, then the app quit: on the next launch it is finalized from what was saved.
        var a = CallAttempt(leadID: "00Q1", campaign: nil, startedAt: t0)
        a.placed(at: at(1)); a.prospect("Hello, Dana speaking.", at: at(3))
        let saved = try! JSONDecoder().decode(CallAttempt.self, from: JSONEncoder().encode(a))
        var recovered = saved
        XCTAssertTrue(recovered.finalize(endedAt: at(3), source: "recovered after app quit"))
        XCTAssertEqual(recovered.outcome, .humanProspect)
        XCTAssertTrue(recovered.classificationSource.hasPrefix("recovered"))
    }

    func testModelNeverChangesTheOutcome() {
        func run(_ stages: [String]) -> CallAttempt {
            call { a in
                a.prospect("Hello?", at: at(3)); a.rep("Hi Dana.", at: at(4)); a.prospect("Who's this?", at: at(6))
                for s in stages { a.modelStage(s) }
            }
        }
        let haiku = run(["Voicemail", "Gatekeeper"]), sonnet = run(["Opener", "Discovery"])
        XCTAssertEqual(haiku.outcome, sonnet.outcome)
        XCTAssertEqual(haiku.conversation, sonnet.conversation)
        XCTAssertEqual(haiku.outcome, .humanProspect)
    }

    func testConversationUsesHangUpTime() {
        let short = call({ a in a.prospect("Hello?", at: at(3)) }, ended: 20)
        XCTAssertFalse(short.conversation)
        let long = call({ a in a.prospect("Hello?", at: at(3)) }, ended: 50)
        XCTAssertTrue(long.conversation)
    }

    func testThreeRates() {
        let reached = call({ a in a.prospect("This is Dana.", at: at(3)); a.prospect("Sure.", at: at(9)); a.prospect("Okay.", at: at(14)) })
        let gk = call({ a in a.prospect("Front desk, who's calling?", at: at(3)) })
        var other = CallAttempt(leadID: "00Q2", campaign: "C", startedAt: t0); other.placed(at: at(1)); other.finalize(endedAt: at(21))
        let s = PickupStats([reached, gk, other])
        XCTAssertEqual(s.placedDials, 3)
        XCTAssertEqual(s.humanAnswered, 2)
        XCTAssertEqual(s.conversations, 1)
        XCTAssertEqual(s.leadsAttempted, 2)
        XCTAssertEqual(s.leadsReached, 1)
    }
}
