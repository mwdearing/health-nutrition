import XCTest
@testable import NutritionUI

/// Whole thousands are grouped in every nutrient figure, and a decimal keeps its fraction (#Today separators).
final class AmountDisplayGroupingTests: XCTestCase {
    func testEnergyGroupsThousands() {
        XCTAssertEqual(AmountDisplay.nutrient(2494, unit: .kcal).text, "2,494 Calories")
    }

    func testMilligramsGroupThousands() {
        XCTAssertEqual(AmountDisplay.nutrient(1305, unit: .mg).text, "1,305 mg")
    }

    func testAGroupedDecimalKeepsItsFraction() {
        XCTAssertEqual(AmountDisplay.nutrient(1234.56, unit: .mg).text, "1,234.6 mg")
        XCTAssertEqual(AmountDisplay.nutrient(3.5, unit: .g).text, "3.5 g")
    }

    func testTheVitaminsFigureGroupsTheSameWay() {
        XCTAssertEqual(NutrientGapRow.figure(1234.56, .mg), "1,234.6 mg")
    }

    func testAnAmountBelowTheSmallestFigureStillSaysSo() {
        XCTAssertEqual(AmountDisplay.nutrient(Decimal(string: "0.004")!, unit: .mg).text, "< 0.01 mg")
    }
}
