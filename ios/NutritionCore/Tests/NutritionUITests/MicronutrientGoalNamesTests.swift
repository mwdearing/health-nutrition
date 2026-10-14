import XCTest
@testable import NutritionJournal
@testable import NutritionUI

final class MicronutrientGoalNamesTests: XCTestCase {
    func testMicronutrientsAreOfferedForGoalsAndNamed() {
        for key in HealthKitWritePlanner.micronutrientKeys {
            XCTAssertEqual(NutrientGoalChoices.keys.contains(key), !["vitaminA", "vitaminD", "vitaminE"].contains(key), key)
            XCTAssertNotEqual(NutrientNames.displayName(for: key), key)
        }
        XCTAssertEqual(NutrientNames.displayName(for: "vitaminB12"), "Vitamin B12")
    }
}
