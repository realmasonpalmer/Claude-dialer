import XCTest
@testable import CoachCore

/// 30 conversation moments run through the same decision rules the live coach uses (intent, conversation
/// checks, THINK checks, the final suppress-or-show step). The THINK/SAY candidates are written for this test,
/// in the style the live model produces: most are good, a few are flawed on purpose to check suppression.
/// They are NOT model outputs. Every moment prints a REPLAY|moment|... row for the report.
final class ReplayMomentsTests: XCTestCase {
    let script = """
    Clarity Consulting. Free 45 minute AI and customer records health check with Oliver, our managing partner.
    Sales teams lose hours typing call notes and updating Salesforce. Follow-ups slip. Forecasts feel like a guess.
    Who handles sales tools. Call notes, follow-up tasks, CRM updates, AI tools, adoption.
    """

    struct Moment {
        let prospect: String
        let context: String          // the turns before, for grounding
        let answered: [String]
        let move: String
        let think: String
        let say: String
        let flawed: Bool             // written to be wrong on purpose
    }

    // Mirrors CoachModel.isSerious / lineProblems' conversation checks (the app target isn't testable here).
    func isSerious(_ p: String) -> Bool {
        if p.hasPrefix("THINK is missing") || p.hasPrefix("THINK isn't usable") 
            // Measured: these two checks wrongly reject good pairs (10 of 40 in the THINK/SAY matrix), so they
            // fall back to SAY instead of hiding the line.
            || p.hasPrefix("THINK and SAY aren't the same move") || p.hasPrefix("THINK is about something that hasn't come up") { return false }
        return ["the rep claims", "they asked a direct", "they declined", "THINK ", "MOVE "].contains { p.hasPrefix($0) }
    }
    func conversationProblems(_ m: Moment, _ intent: ConversationIntent) -> [String] {
        var p: [String] = []
        if RoleCheck.speaksAsProspect(m.say) { p.append("the rep claims the prospect's role") }
        if m.move == "discover", intent == .question { p.append("they asked a direct question: answer it first") }
        if ["discover", "clarify", "objection"].contains(m.move), intent == .rejection { p.append("they declined: no sales question") }
        return p
    }

    var moments: [Moment] { [
        // Discovery
        Moment(prospect: "Our sales team uses Salesforce, but adoption is poor.", context: "Rep: Does that sound familiar?", answered: [],
               move: "discover", think: "What happens when your team tries to use it?", say: "Got it. What happens when your team tries to use it?", flawed: false),
        Moment(prospect: "We use Gong for calls.", context: "Rep: How do call notes get logged today?", answered: [],
               move: "discover", think: "Does Gong handle your follow-ups too?", say: "Nice. Does Gong handle your follow-ups too, or does your team?", flawed: false),
        Moment(prospect: "We use Gong, but our team still updates Salesforce by hand.", context: "", answered: [],
               move: "discover", think: "How much time do those Salesforce updates take?", say: "How much time do those Salesforce updates take each week?", flawed: false),
        Moment(prospect: "Reps type notes in after every call, it takes forever.", context: "Rep: What happens after a call ends?", answered: ["What happens after a call ends?"],
               move: "discover", think: "Roughly how many hours a week does that take?", say: "Roughly how many hours a week does that take your team?", flawed: false),
        Moment(prospect: "Maybe ten hours a week per rep.", context: "Rep: Roughly how many hours a week does that take?", answered: ["Roughly how many hours a week does that take your team?"],
               move: "discover", think: "Who else feels that time loss?", say: "That's a lot. Who else on the team feels that time loss?", flawed: false),
        Moment(prospect: "Follow-ups slip all the time.", context: "", answered: [],
               move: "discover", think: "What happens when a follow-up slips?", say: "What happens when a follow-up slips?", flawed: false),
        Moment(prospect: "We tried an AI notetaker last year.", context: "", answered: [],
               move: "discover", think: "What got in the way with that notetaker?", say: "What got in the way with that notetaker?", flawed: false),
        // Repeats (flawed on purpose)
        Moment(prospect: "Yeah, mostly by hand.", context: "Rep: How do call notes get into Salesforce?", answered: ["How do call notes get into Salesforce today?"],
               move: "discover", think: "How do call notes get into Salesforce?", say: "How do call notes get into Salesforce?", flawed: true),
        // Direct questions
        Moment(prospect: "What is this about?", context: "Rep: Can I get thirty seconds to tell you why I called?", answered: [],
               move: "answer", think: "Explain the free AI health check.", say: "It's a free AI health check on how your team logs calls. Worth a look?", flawed: false),
        Moment(prospect: "What is this about?", context: "", answered: [],
               move: "discover", think: "What happens with notes after a call?", say: "When a rep finishes a call today, what happens with the notes?", flawed: true),
        Moment(prospect: "How did you get my number?", context: "", answered: [],
               move: "answer", think: "Explain how you found them.", say: "I found you on LinkedIn as head of sales. Fair question.", flawed: false),
        Moment(prospect: "Is this a sales call?", context: "", answered: [],
               move: "answer", think: "Be upfront that it's a sales call.", say: "Honestly, yes, it's a sales call. Can I take thirty seconds?", flawed: false),
        Moment(prospect: "Who is Oliver?", context: "Rep: It's a free health check with Oliver.", answered: [],
               move: "answer", think: "Explain who Oliver is.", say: "Oliver is our managing partner. He runs the health checks himself.", flawed: false),
        Moment(prospect: "Are you the one that decides on those types of things?", context: "", answered: [],
               move: "answer", think: "Clarify you're the caller, not the buyer.", say: "Yes, I'm the one who decides on those tools.", flawed: true),
        // Objections (one relevant question allowed)
        Moment(prospect: "We already use another tool for that.", context: "", answered: [],
               move: "objection", think: "What does that tool still miss?", say: "Makes sense. What does that tool still miss for your team?", flawed: false),
        Moment(prospect: "I don't have time right now.", context: "", answered: [],
               move: "objection", think: "Ask for a better time to call.", say: "No problem. When's a better time to call back?", flawed: false),
        Moment(prospect: "Just send me an email.", context: "", answered: [],
               move: "objection", think: "What's the best email for you?", say: "Happy to. What's the best email for you?", flawed: false),
        Moment(prospect: "I'm not the right person for this.", context: "", answered: [],
               move: "objection", think: "Who handles sales tools there?", say: "Fair. Who handles sales tools on your side?", flawed: false),
        Moment(prospect: "We're all good, we're set.", context: "", answered: [],
               move: "objection", think: "Offer the free health check anyway.", say: "Love that. Worth a free health check to be sure?", flawed: false),
        // Clear refusals
        Moment(prospect: "I'm not interested.", context: "", answered: [],
               move: "acknowledge", think: "Acknowledge. Don't push.", say: "Totally fair. I appreciate you being straight with me.", flawed: false),
        Moment(prospect: "I'm not interested.", context: "", answered: [],
               move: "close", think: "Can I send one short email?", say: "Understood. Can I send one short email and leave it there?", flawed: false),
        Moment(prospect: "I don't know that I'm the right fit for this right now.", context: "", answered: [],
               move: "discover", think: "Where does your team lose the most time?", say: "Fair. If you had to guess, where does a rep lose the most time?", flawed: true),
        Moment(prospect: "No thanks, not for us.", context: "", answered: [],
               move: "objection", think: "What would make it a fit?", say: "Fair. What would make it a fit for you?", flawed: true),
        // Confusion
        Moment(prospect: "What do you mean by customer records?", context: "Rep: It's a health check on AI and customer records.", answered: [],
               move: "clarify", think: "Explain: Salesforce and call notes.", say: "I mean your CRM, like Salesforce, and the call notes in it.", flawed: false),
        Moment(prospect: "Sorry, I didn't catch that.", context: "Rep: Free health check on how your team uses AI.", answered: [],
               move: "clarify", think: "Repeat the reason in one sentence.", say: "No worries. It's a free check on how your team uses AI and the CRM.", flawed: false),
        // Objection already answered
        Moment(prospect: "Like I said, we already use Gong.", context: "Prospect: We use Gong. Rep: Does Gong handle your follow-ups too?", answered: [],
               move: "discover", think: "Does Gong handle your follow-ups too?", say: "Does Gong handle your follow-ups too?", flawed: true),
        // Closing
        Moment(prospect: "Okay, that sounds interesting.", context: "Rep: Would a free health check help?", answered: [],
               move: "close", think: "Offer Tuesday or Wednesday.", say: "Great. Would Tuesday at 10 or Wednesday at 2 work?", flawed: false),
        Moment(prospect: "Tuesday works.", context: "Rep: Would Tuesday at 10 or Wednesday at 2 work?", answered: [],
               move: "close", think: "Who else should join?", say: "Perfect. Who else should join the call with Oliver?", flawed: false),
        Moment(prospect: "Thanks, have a good day.", context: "", answered: [],
               move: "close", think: "Thank them and end the call.", say: "You too. Thanks for your time.", flawed: false),
        Moment(prospect: "Thanks, have a good day.", context: "", answered: [],
               move: "close", think: "Can we book a time first?", say: "Before you go, can we book a time?", flawed: true),
    ] }

    func testReplay() {
        var shown = 0, fallback = 0, suppressed = 0, flawedShown = 0, goodSuppressed = 0
        for (i, m) in moments.enumerated() {
            let intent = ConversationIntent.classify(m.prospect)
            let all = conversationProblems(m, intent) + Think.problems(
                think: m.think, say: m.say, move: m.move, intent: intent, objectionKind: ObjectionTracker.detect(m.prospect),
                latestProspect: m.prospect, recentText: m.context + " " + m.prospect, scriptText: script, answeredQuestions: m.answered)
            let decision: String
            if all.isEmpty { decision = "THINK shown"; shown += 1 }
            else if all.contains(where: isSerious) { decision = "suppressed (after the one retry, if it fails the same way)"; suppressed += 1 }
            else { decision = "SAY shown, labeled SAY THIS"; fallback += 1 }
            if m.flawed, all.isEmpty { flawedShown += 1 }
            if !m.flawed, all.contains(where: isSerious) { goodSuppressed += 1 }
            print("REPLAY|moment \(i + 1)|\(m.flawed ? "flawed on purpose" : "good")|intent=\(intent.rawValue)|move=\(m.move)|Prospect: \(m.prospect)|THINK: \(m.think)|SAY: \(m.say)|problems: \(all.isEmpty ? "none" : all.joined(separator: "; "))|\(decision)")
        }
        print("REPLAY|moment-summary|moments=\(moments.count)|THINK shown=\(shown)|SAY fallback=\(fallback)|suppressed=\(suppressed)|flawed but shown=\(flawedShown)|good but suppressed=\(goodSuppressed)")
        XCTAssertEqual(moments.count, 30)
    }
}
