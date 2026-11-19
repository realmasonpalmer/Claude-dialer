import XCTest
@testable import CoachCore

final class ThinkTests: XCTestCase {
    let say = "Makes sense, lots of teams do. What's still eating your reps' time even with them in place?"

    func testOffMeansLivePromptAndCardUnchanged() {
        XCTAssertEqual(Think.promptLine(enabled: false), "")
        XCTAssertEqual(Think.primary(think: "What still takes time, even with your AI team?", say: say,
                                     exact: false, enabled: false, showFull: false), say)
    }

    func testThoughtIsTheCardWhenOn() {
        XCTAssertTrue(Think.promptLine(enabled: true).hasPrefix("THINK:"))
        XCTAssertEqual(Think.primary(think: "What still takes time, even with your AI team?", say: say,
                                     exact: false, enabled: true, showFull: false),
                       "What still takes time, even with your AI team?")
    }

    func testFullLineOnRequestAndScriptRowsInFull() {
        XCTAssertEqual(Think.primary(think: "Who would be the best person to speak with?", say: say, exact: false, enabled: true, showFull: true), say)
        XCTAssertTrue(Think.promptLine(enabled: true).contains("your team"))
        XCTAssertEqual(Think.primary(think: "Pitch it.", say: "We set up an AI notetaker...", exact: true, enabled: true, showFull: false),
                       "We set up an AI notetaker...")
    }

    func testBadThoughtFallsBackToSay() {
        for bad in ["Explore whether Gong handles CRM updates.", "Who's the right person? Ask for a name.",
                    "Ask what they'd want in it.", "", "Ask", "<the rep's next move>", "SAY: hello there friend",
                    "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen"] {
            XCTAssertEqual(Think.primary(think: bad, say: say, exact: false, enabled: true, showFull: false), say, bad)
        }
    }
}
