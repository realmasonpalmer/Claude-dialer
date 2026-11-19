import XCTest
@testable import CoachCore

final class ModelTestTests: XCTestCase {
    func testVerdict() {
        // 250 calls each: 30% vs 20% reached the ask is a clear win.
        XCTAssertEqual(ModelTest.verdict(75, of: 250, vs: 50, of: 250, names: ("Sonnet", "Haiku")), "Sonnet wins (95% sure)")
        // 22% vs 20%: too close.
        XCTAssertEqual(ModelTest.verdict(55, of: 250, vs: 50, of: 250, names: ("Sonnet", "Haiku")), "too close to call yet")
        XCTAssertEqual(ModelTest.verdict(3, of: 10, vs: 1, of: 10, names: ("Sonnet", "Haiku")), "not enough calls yet (need 20+ each)")
    }
}
