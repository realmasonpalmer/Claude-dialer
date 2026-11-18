import XCTest
@testable import CoachCore

final class Phase2MemoryTests: XCTestCase {
    // C3: call A's late summary never lands in call B, and an older summary never replaces a newer one.
    func testC3_SummaryKeptOnlyForSameCallAndNewer() {
        XCTAssertFalse(CallMemoryRules.acceptSummary(currentCallID: "B", summaryCallID: "A", summaryCovers: 20, storedCovers: 0))
        XCTAssertFalse(CallMemoryRules.acceptSummary(currentCallID: "A", summaryCallID: "A", summaryCovers: 16, storedCovers: 20))
        XCTAssertTrue(CallMemoryRules.acceptSummary(currentCallID: "A", summaryCallID: "A", summaryCovers: 24, storedCovers: 20))
    }

    // M4: summary covers 8 turns, call is at 22: turns 9 to 22 go word for word (none dropped).
    func testM4_UncoveredTurnsStayVerbatim() {
        XCTAssertEqual(CallMemoryRules.verbatimStart(totalTurns: 22, summaryCovers: 8, hasSummary: true), 8)
        XCTAssertEqual(CallMemoryRules.verbatimStart(totalTurns: 30, summaryCovers: 28, hasSummary: true), 20) // at least the last 10
        XCTAssertEqual(CallMemoryRules.verbatimStart(totalTurns: 10, summaryCovers: 0, hasSummary: false), 0)
        XCTAssertTrue(CallMemoryRules.summaryDue(totalTurns: 22, summaryCovers: 8, inFlight: false))
        XCTAssertFalse(CallMemoryRules.summaryDue(totalTurns: 22, summaryCovers: 8, inFlight: true))
    }
}
