import Foundation
import XCTest
@testable import NutritionUI

final class RecipeEnergyWholeCaloriesTests: XCTestCase {
    func testRecipeEnergyReadsWholeCaloriesLikeToday() {
        let text = RecipeDetailViewModel.valueText(.known(Decimal(string: "123.5")!, .kcal))
        XCTAssertFalse(text.contains("."), "energy has no decimal: \(text)")
        XCTAssertEqual(text, AmountDisplay.nutrient(Decimal(string: "123.5")!, unit: .kcal).text)
    }

    func testOtherRecipeUnitsKeepTheirFigure() {
        let text = RecipeDetailViewModel.valueText(.known(Decimal(string: "12.5")!, .g))
        XCTAssertEqual(text, NutrientGapRow.figure(Decimal(string: "12.5")!, .g))
    }
}
