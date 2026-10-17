import XCTest
@testable import NutritionJournal

/// The drink water share: the presets a drink type prefills, and what a component stores when it sets none.
final class DrinkWaterShareTests: XCTestCase {
    func testEveryDrinkTypePresetIsAPercentageFromZeroToHundred() {
        for type in DrinkType.allCases {
            XCTAssertGreaterThanOrEqual(type.hydrationPercent, 0, type.rawValue)
            XCTAssertLessThanOrEqual(type.hydrationPercent, 100, type.rawValue)
        }
    }

    func testWaterPresetIsWholeAndSodaIsTheNinetyPercentDefault() {
        XCTAssertEqual(DrinkType.water.hydrationPercent, 100)
        XCTAssertEqual(DrinkType.soda.hydrationPercent, IntakeComponent.defaultDrinkHydrationPercent)
    }

    func testAComponentWithoutAShareStoresNone() throws {
        let food = IntakeComponent(componentID: "rice", name: "Rice", amount: 100, unit: try MeasureUnit(symbol: "g"))
        XCTAssertNil(food.hydrationPercent)
    }
}
