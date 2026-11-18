import XCTest
@testable import CoachCore

final class ReadingLevelTests: XCTestCase {
    func testPlainLinesPass() {
        XCTAssertFalse(ReadingLevel.tooHard("Hi Sean, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"))
        XCTAssertFalse(ReadingLevel.tooHard("Got it. How much time does your team spend on notes after each call?"))
        XCTAssertFalse(ReadingLevel.tooHard("Understood, Sean. You won't hear from us again. Take care."))
    }

    func testHardLinesFail() {
        XCTAssertTrue(ReadingLevel.tooHard("We facilitate comprehensive operational optimization initiatives, enabling organizations to systematically maximize productivity."))
        XCTAssertTrue(ReadingLevel.tooHard("Would implementing an automated documentation methodology meaningfully accelerate your organization's revenue generation capabilities?"))
    }

    func testNamesDontCount() {
        // A long company name alone shouldn't fail a plain line.
        XCTAssertFalse(ReadingLevel.tooHard("Is this Bartholomew from Consolidated Manufacturing International? Do you have a minute?"))
    }

    func testRuleIsInEveryPrompt() {
        XCTAssertTrue(ReadingLevel.rule.contains("5th grade"))
        XCTAssertLessThan(ReadingLevel.target, ReadingLevel.checkMax)
    }
}
