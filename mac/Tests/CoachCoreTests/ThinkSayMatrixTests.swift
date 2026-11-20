import XCTest
@testable import CoachCore

/// Measures the THINK/SAY agreement check against human labels. It does not fail on disagreements:
/// it prints every pair (REPLAY|matrix|...) so false approvals and false rejections can be read in the log.
final class ThinkSayMatrixTests: XCTestCase {
    // (THINK, SAY, move, same meaning? by a human reader)
    let pairs: [(String, String, String, Bool)] = [
        // Same question, different words
        ("What's stopping your team from using Salesforce?", "What gets in the way of your team using Salesforce?", "discover", true),
        ("What's blocking Salesforce adoption?", "Why aren't people using the CRM?", "discover", true),
        ("Does Gong handle your follow-ups too?", "Makes sense. Does Gong also take care of the follow-up emails?", "discover", true),
        ("Who handles sales tools there?", "Fair. Who looks after your sales tools?", "objection", true),
        ("How do call notes get into Salesforce?", "Got it. How do your call notes end up in Salesforce today?", "discover", true),
        ("How much time do those updates take?", "Roughly how many hours a week go into those updates?", "discover", true),
        ("What happens after a call ends?", "When a call ends, what happens next with the notes?", "discover", true),
        ("Who else weighs in on tools like this?", "Who else would have a say in a tool like this?", "discover", true),
        ("Would Tuesday or Wednesday work for a look?", "Would Tuesday at 10 or Wednesday at 2 work for a quick look?", "close", true),
        ("Is a free health check worth 45 minutes?", "Would a free 45 minute health check be worth it?", "close", true),
        ("What made you look at AI tools?", "What got your team looking at AI in the first place?", "discover", true),
        ("Why did the last rollout stall?", "What got in the way when you rolled it out last time?", "discover", true),
        ("How are follow-ups tracked today?", "Today, how does your team keep track of follow-ups?", "discover", true),
        ("Is Salesforce your main system?", "Is Salesforce where everything lives for your team?", "discover", true),
        ("What would a good outcome look like?", "If this went well, what would that look like for you?", "discover", true),
        // Instructions that SAY carries out
        ("Explain the free AI health check.", "It's a free look at how your team logs calls and uses AI.", "answer", true),
        ("Thank them and end the call.", "Totally understand. Thanks for your time. Have a good one.", "close", true),
        ("Acknowledge. Don't push.", "Fair enough, I appreciate you being straight with me.", "acknowledge", true),
        ("Explain how you got their number.", "I found you on LinkedIn as the head of sales at Acme.", "answer", true),
        ("Be upfront that it's a sales call.", "Honestly, yes, it's a cold call. I'll be quick.", "answer", true),
        // Different questions
        ("What's stopping your team from using Salesforce?", "What happens when your team tries to use it?", "discover", false),
        ("Who handles sales tools there?", "What is the biggest challenge with your CRM?", "discover", false),
        ("How much time do those updates take?", "Who handles those updates on your team?", "discover", false),
        ("Does Gong handle your follow-ups too?", "How many reps does your team have?", "discover", false),
        ("What's stopping your team from using Salesforce?", "How many people use Salesforce each week?", "discover", false),
        ("How do call notes get into Salesforce?", "Who reads the call notes after they're logged?", "discover", false),
        ("Would Tuesday or Wednesday work?", "Who else should join the meeting?", "close", false),
        ("Who else weighs in on tools like this?", "What tools does your team use today?", "discover", false),
        ("Why did the last rollout stall?", "When did you roll it out?", "discover", false),
        ("What made you look at AI tools?", "Which AI tools have you looked at?", "discover", false),
        ("Is Salesforce your main system?", "How long have you used Salesforce?", "discover", false),
        ("How are follow-ups tracked today?", "How many follow-ups slip each week?", "discover", false),
        ("What would a good outcome look like?", "What would make this a bad fit for you?", "discover", false),
        ("Is a free health check worth 45 minutes?", "Is your team open to new tools right now?", "close", false),
        ("How much do manual updates cost you?", "How much do you spend on Salesforce licenses?", "discover", false),
        // Instructions that SAY contradicts
        ("Thank them and end the call.", "Totally understand. Where does your team lose the most time?", "close", false),
        ("Acknowledge. Don't push.", "Fair. If you had to guess, where does a rep lose the most time?", "acknowledge", false),
        ("Explain the free AI health check.", "When a rep finishes a call, what happens with the notes?", "answer", false),
        ("Explain how you got their number.", "Do you handle the sales tools there?", "answer", false),
        ("Be upfront that it's a sales call.", "How many reps are on your team?", "answer", false),
    ]

    func testMatrix() {
        var tp = 0, tn = 0, falseApproval = 0, falseRejection = 0
        for (think, say, move, same) in pairs {
            let ok = Think.agrees(think: think, say: say, move: move)
            let verdict: String
            switch (same, ok) {
            case (true, true): tp += 1; verdict = "correct approve"
            case (false, false): tn += 1; verdict = "correct reject"
            case (false, true): falseApproval += 1; verdict = "FALSE APPROVAL"
            case (true, false): falseRejection += 1; verdict = "FALSE REJECTION"
            }
            print("REPLAY|matrix|\(verdict)|move=\(move)|THINK: \(think)|SAY: \(say)")
        }
        print("REPLAY|matrix-summary|pairs=\(pairs.count)|correct=\(tp + tn)|false approvals=\(falseApproval)|false rejections=\(falseRejection)")
        XCTAssertEqual(pairs.count, 40)
    }
}
