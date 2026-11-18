import XCTest
@testable import CoachCore

final class Phase4LineTests: XCTestCase {
    // H4: a second "?" is fixed in code, no extra request.
    func testH4_InternalQuestionMarkFixedInCode() {
        XCTAssertEqual(LineRepair.fix("Makes sense? How many reps are on your team?"), "Makes sense. How many reps are on your team?")
    }

    // M7: a long two-sentence line keeps its question, not the last 25 words of a fragment.
    func testM7_TrimKeepsWholeSentences() {
        let long = "Lots of sales leaders we talk to tell us their reps lose hours every single week typing call notes into the system. Is that true for your team?"
        let out = LineRepair.trimToFit(long, max: 25)
        XCTAssertEqual(out, "Is that true for your team?")
        let noQ = "We help teams get hours back every week. We do it by updating Salesforce after each call for every single rep on the team today."
        XCTAssertEqual(LineRepair.trimToFit(noQ, max: 12), "We help teams get hours back every week.")
    }
}
