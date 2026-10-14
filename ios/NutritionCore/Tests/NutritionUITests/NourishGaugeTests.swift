import XCTest
@testable import NutritionUI

final class NourishGaugeTests: XCTestCase {
    func testFractionIsProportionalAndCapped() {
        XCTAssertEqual(NourishGauge.fraction(value: 1_050, goal: 2_100), 0.5, accuracy: 0.0001)
        XCTAssertEqual(NourishGauge.fraction(value: 3_000, goal: 2_100), 1)
    }

    func testNoUsableGoalOrValueDrawsNothing() {
        XCTAssertEqual(NourishGauge.fraction(value: 500, goal: nil), 0)
        XCTAssertEqual(NourishGauge.fraction(value: 500, goal: 0), 0)
        XCTAssertEqual(NourishGauge.fraction(value: -5, goal: 100), 0)
        XCTAssertEqual(NourishGauge.fraction(value: .infinity, goal: 100), 0)
    }
}

final class NourishClampTests: XCTestCase {
    func testNonFiniteFractionsDrawNothing() {
        XCTAssertEqual(NourishGauge.clamped(.nan), 0)
        XCTAssertEqual(NourishGauge.clamped(.infinity), 0)
        XCTAssertEqual(NourishGauge.clamped(1.5), 1)
        XCTAssertEqual(NourishGauge.clamped(-1), 0)
    }
}
