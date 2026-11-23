import XCTest
@testable import CoachCore

/// Strategy rules, replayed on the real Adam Griffen call (Nov 23, 188 s, humanProspect, 0 meetings).
/// That call's coach kept asking discovery questions after a "we don't need it", through a 50-second pitch,
/// a no, an incentive and an offered callback.
final class CallStrategyTests: XCTestCase {
    typealias T = CallStrategy.Turn
    func P(_ s: String) -> T { T(rep: false, text: s) }
    func R(_ s: String) -> T { T(rep: true, text: s) }

    // The call as the app stores it: consecutive chunks from one side are one turn.
    let hello = "Hello. This is Adam."
    let opener = "Adam, my name is Mason. I'm I'm calling from the Anthropic Partner Network. Have you have you heard the name Anthropic or Claude tossed around?"
    let knowsClaude = "Oh, yeah."
    let repChat = "Nice. Heck yeah. So we build sales workflows that clear a lot of repetitive work from people's teams. Especially people in sales like you. I am curious, what do you do mostly in your role? Are you"
    let director = "I'm the sales director."
    let repQuestion = "nice? And what do you feel like... Do you feel like you have to chase your team a lot on, like, missed opportunities or any, like, lost time that your reps are spending?"
    let noNeed = "I mean, we use Claude right now. I mean, my team's not big enough to go any deeper into using specific custom workflows. We have some things already, but I wouldn't need any more assistance at this point in time with the size of my team."
    let pitch = "Okay. So, really, the the whole reason for my call is we do this, like, free AI health check. And our managing partner Oliver he's a super heavy hitter. He's closed, you know, a couple of 7 figure exits. And what we would do in this call is we would basically just give you three really high leverage uses for AI. We'd kinda go over how you're using AI right now. And hopefully just give you some some quick wins At the very least, it could just be a cool peer conversation. Are you are you available for a call like that? Okay."
    let firstNo = "Not at this point."
    let incentive = "If we bought you a share in in Anthropic, since it just went public, would that be any sort of incentive for you to get on a call like that?"
    let callback = "Not at this point in time. I mean, you can call me back at the end of first quarter and that'll be fine. But no. I don't I need to share one share. If you got a thousand, I'll talk. But"
    let finalNo = "I know. I got you. No. I'm good right now."

    var start: [T] { [P(hello), R(opener), P(knowsClaude), R(repChat), P(director), R(repQuestion)] }

    // MARK: The call, moment by moment

    func testNothingWrongBeforeTheObjection() {
        // "Oh, yeah." and "I'm the sales director." need no strategy card, and 36 rep words is not a pitch.
        XCTAssertNil(CallStrategy.current(Array(start.prefix(3))))
        XCTAssertNil(CallStrategy.current(Array(start.prefix(4))))
        XCTAssertNil(CallStrategy.current(Array(start.prefix(5))))
        XCTAssertNil(CallStrategy.current(start))
    }

    func testAlreadyUsingAndTooSmall() {
        let d = CallStrategy.current(start + [P(noNeed)])
        XCTAssertEqual(d?.kind, .tooSmall)
        XCTAssertEqual(d?.think, "They see no need. Test for one real gap, or exit.")
        XCTAssertFalse(d?.hard ?? true, "the model still writes the question")
        let using = CallStrategy.current([P(hello), R(opener), P("Yeah, I use Claude all the time.")])
        XCTAssertEqual(using?.kind, .alreadyUsing)
        XCTAssertEqual(using?.think, "They already use it. Find out if anything is missing.")
    }

    func testLongPitchWithNoNeedFoundIsStopped() {
        let turns = start + [P(noNeed), R(pitch)]
        let d = CallStrategy.current(turns)
        XCTAssertEqual(d?.kind, .stopPitching)
        XCTAssertEqual(d?.think, "Stop pitching. You haven't found a reason they'd need this.")
        XCTAssertTrue(d?.hard ?? false)
        // Early in the pitch (about 20 words) it is not yet too much: no card.
        let early = "Okay. So, really, the the whole reason for my call is we do this, like, free AI health check."
        XCTAssertNil(CallStrategy.current(start + [P(noNeed), R(early)]))
    }

    func testAPitchIsFineWhenTheyAskedOrNamedAProblem() {
        // They asked a direct question: a long answer is the job.
        let asked = [P(hello), R(opener), P("What does that actually cost, and who is Oliver?"), R(pitch)]
        XCTAssertNil(CallStrategy.current(asked))
        // They named a real problem: explaining how it helps is fine.
        let need = [P(hello), R(opener), P("Honestly our CRM updates take forever and nobody keeps them current."), R(pitch + " " + pitch)]
        XCTAssertNil(CallStrategy.current(need))
    }

    func testFirstNoIsRespected() {
        let turns = start + [P(noNeed), R(pitch), P(firstNo)]
        let d = CallStrategy.current(turns)
        XCTAssertEqual(d?.kind, .respectNo)
        XCTAssertEqual(d?.think, "Respect the no. Don't offer another incentive.")
    }

    func testIncentiveAfterANoIsFlaggedWhileTheRepSpeaks() {
        let partial = "Okay. If we bought you a share in in Anthropic, since it just went public, would that"
        let d = CallStrategy.current(start + [P(noNeed), R(pitch), P(firstNo), R(partial)])
        XCTAssertEqual(d?.kind, .respectNo)
        XCTAssertEqual(d?.think, "Respect the no. Don't offer another incentive.")
        XCTAssertTrue(d?.hard ?? false)
        // Even a long push with no incentive word is too much after a no.
        let push = "Well, hear me out for a second, because most teams your size actually see the most value from a quick outside look at what they already have."
        XCTAssertEqual(CallStrategy.current(start + [P(noNeed), R(pitch), P(firstNo), R(push)])?.kind, .respectNo)
    }

    func testOfferedCallbackIsAcceptedAndNeverOutPitched() {
        let turns = start + [P(noNeed), R(pitch), P(firstNo), R(incentive), P(callback)]
        let d = CallStrategy.current(turns)
        XCTAssertEqual(d?.kind, .acceptFollowUp)
        XCTAssertEqual(d?.think, "They offered a follow-up. Accept it and end the call.")
        XCTAssertEqual(d?.say, "Sounds good. I'll reach out at the end of first quarter. Thanks for your time.")
        XCTAssertTrue(d?.hard ?? false)
        XCTAssertEqual(d?.move, "close")
        // The line the coach really showed next ("What would make a 20-minute call worth your time this quarter?"),
        // and the discovery the model wrote, are both refused under that strategy.
        let late = CallStrategy.problems(directive: d, move: "discover", think: "Ask what would make a call worth their time.",
                                         say: "Fair enough, Adam. What would make a 20-minute call worth your time this quarter?")
        XCTAssertFalse(late.isEmpty)
        XCTAssertTrue(late.allSatisfy { $0.hasPrefix("STRATEGY") })
        // A plain accept is fine.
        XCTAssertTrue(CallStrategy.problems(directive: d, move: "close", think: "They offered a follow-up. Accept it and end the call.",
                                            say: "Sounds good. I'll call you back at the end of Q1. Thanks for your time.").isEmpty)
    }

    func testClearNoStaysClosedUntilTheyShowNewInterest() {
        let base = start + [P(noNeed), R(pitch), P(firstNo)]
        // "No. I'm good right now." is a no too, and "Okay" after a no must not reopen the sale.
        XCTAssertEqual(CallStrategy.current(base + [R("Right on."), P(finalNo)])?.kind, .respectNo)
        XCTAssertEqual(CallStrategy.current(base + [R("Right on."), P("Okay.")])?.kind, .respectNo)
        let d = CallStrategy.current(base + [R("Right on."), P(finalNo)])
        let reopen = CallStrategy.problems(directive: d, move: "discover", think: "Ask what would make a call worth their time.",
                                           say: "What would make a 20-minute call worth your time this quarter?")
        XCTAssertFalse(reopen.isEmpty, "no discovery or meeting ask after a no")
        // A new signal of interest ends it.
        XCTAssertNil(CallStrategy.current(base + [R("Right on."), P("Actually, how does that work? What does it cost?")]))
    }

    // MARK: Smaller rules

    func testPartialTranscriptsNeverTriggerAnOffer() {
        XCTAssertFalse(FollowUp.isOffered("Give me a call at the end of"))
        XCTAssertFalse(FollowUp.isOffered("The end of first quarter is busy for us"))
        XCTAssertNil(CallStrategy.current([P(hello), R(opener), P("Give me a call at the end of")]))
        XCTAssertTrue(FollowUp.isOffered("Give me a call at the end of Q1."))
        XCTAssertTrue(FollowUp.isOffered("Check back with me next quarter."))
        XCTAssertTrue(FollowUp.isOffered("Try me again in January."))
        XCTAssertFalse(FollowUp.isOffered("Don't call me again in Q1."), "that is a refusal, not an offer")
    }

    func testTimingIsSaidBackNaturally() {
        XCTAssertEqual(FollowUp.timing("call me at the end of Q1").map(FollowUp.spoken), "at the end of Q1")
        XCTAssertEqual(FollowUp.timing("reach out in Q2").map(FollowUp.spoken), "in Q2")
        XCTAssertEqual(FollowUp.timing("check back next quarter").map(FollowUp.spoken), "next quarter")
    }

    func testOptOutIsLeftToItsOwnPath() {
        XCTAssertNil(CallStrategy.current([P(hello), R(opener), P("Take me off your list.")]))
    }

    func testRiskyPromisesAreFlagged() {
        let d = CallStrategy.current([P(hello), R(opener), P(knowsClaude), R("We guarantee you'll double your pipeline in a month.")])
        XCTAssertEqual(d?.kind, .riskyClaim)
        XCTAssertTrue(CallStrategy.riskyClaims(in: "Since it just went public").contains("went public"))
        XCTAssertTrue(CallStrategy.riskyClaims(in: "Our recipients love it").isEmpty, "whole words only")
    }

    func testIncentiveAndMeetingWords() {
        XCTAssertTrue(CallStrategy.offersIncentive("It's like a $100 in your pocket."))
        XCTAssertTrue(CallStrategy.offersIncentive("We'd buy the team lunch."))
        XCTAssertFalse(CallStrategy.offersIncentive("Thanks for your time."))
        XCTAssertTrue(CallStrategy.pitchesMeeting("Can we book a quick health check?"))
    }

    // MARK: The paraphrase rule and the measures

    func testFollowingTheMoveInOtherWordsCounts() {
        XCTAssertTrue(CallStrategy.followed(kind: .acceptFollowUp, repSaid: "Perfect, I'll talk to you then."))
        XCTAssertFalse(CallStrategy.followed(kind: .acceptFollowUp, repSaid: "Before you go, can we book a quick call?"))
        XCTAssertTrue(CallStrategy.followed(kind: .respectNo, repSaid: "No problem, I appreciate your time."))
        XCTAssertFalse(CallStrategy.followed(kind: .respectNo, repSaid: "Totally fair, but it's free and we'd buy lunch."))
        XCTAssertTrue(CallStrategy.followed(kind: .stopPitching, repSaid: "Let me stop there. What do you do today?"))
        XCTAssertFalse(CallStrategy.followed(kind: .stopPitching, repSaid: "And the best part is Oliver has closed a lot of deals"))
        XCTAssertTrue(CallStrategy.followed(kind: .alreadyUsing, repSaid: "Nice. What's one thing it doesn't do for you yet?"))
    }

    func testEvaluateJudgesTheStrategyAndTheRepSeparately() {
        let d = CallStrategy.afterProspect(start + [P(noNeed), R(pitch), P(firstNo), R(incentive), P(callback)])
        let good = CallStrategy.evaluate(directive: d, move: "close", think: "They offered a follow-up. Accept it and end the call.",
                                         say: "Sounds good. I'll reach out then. Thanks for your time.", repSaidAfter: "Right on. Sounds good, talk then.")
        XCTAssertTrue(good.strategyMatched)
        XCTAssertTrue(good.followed)
        let bad = CallStrategy.evaluate(directive: d, move: "discover", think: "Ask what would make a call worth it.",
                                        say: "What would make a call worth your time this quarter?", repSaidAfter: "It's like a $100 in your pocket.")
        XCTAssertFalse(bad.strategyMatched)
        XCTAssertFalse(bad.followed)
    }

    // MARK: THINK and SAY

    func testThinkThatOnlyRepeatsSayIsRejected() {
        let p = Think.problems(think: "Explain the free AI health check to them.", say: "Explain the free AI health check to them.",
                               move: "answer", intent: .other, objectionKind: nil, latestProspect: "What is it?",
                               recentText: "free AI health check", scriptText: "", answeredQuestions: [])
        XCTAssertTrue(p.contains { $0.hasPrefix("THINK repeats SAY") }, "\(p)")
        let ok = Think.problems(think: "Explain what the health check covers.", say: "It's a free look at how your team uses AI today, with three quick wins.",
                                move: "answer", intent: .other, objectionKind: nil, latestProspect: "What is it?",
                                recentText: "free AI health check", scriptText: "", answeredQuestions: [])
        XCTAssertFalse(ok.contains { $0.hasPrefix("THINK repeats SAY") }, "\(ok)")
    }

    func testPromptTextCarriesTheRule() {
        let d = CallStrategy.afterProspect(start + [P(noNeed)])!
        let text = CallStrategy.promptText(d)
        XCTAssertTrue(text.contains("They see no need"))
        XCTAssertTrue(text.contains("No incentive, no meeting ask"))
    }
}
