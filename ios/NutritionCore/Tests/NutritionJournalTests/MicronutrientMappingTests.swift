import XCTest
@testable import NutritionJournal

final class MicronutrientMappingTests: XCTestCase {
    /// Apple Health's dietary vitamin and mineral types, by the identifier suffix after
    /// `HKQuantityTypeIdentifierDietary`.
    private let expectedSuffixes: Set<String> = [
        "VitaminA", "VitaminB6", "VitaminB12", "VitaminC", "VitaminD", "VitaminE", "VitaminK",
        "Thiamin", "Riboflavin", "Niacin", "Folate", "Biotin", "PantothenicAcid",
        "Calcium", "Iron", "Magnesium", "Phosphorus", "Potassium", "Zinc", "Chloride", "Chromium",
        "Copper", "Iodine", "Manganese", "Molybdenum", "Selenium",
    ]

    func testEveryMicronutrientMapsToItsOwnHealthKitType() {
        let prefix = "HKQuantityTypeIdentifierDietary"
        var suffixes = Set<String>()
        for key in HealthKitWritePlanner.micronutrientKeys {
            guard let mapping = HealthKitWritePlanner.mapping(for: key) else {
                return XCTFail("\(key) has no HealthKit mapping")
            }
            XCTAssertTrue(mapping.quantityTypeIdentifier.hasPrefix(prefix))
            suffixes.insert(String(mapping.quantityTypeIdentifier.dropFirst(prefix.count)))
        }
        XCTAssertEqual(suffixes, expectedSuffixes)
        XCTAssertEqual(HealthKitWritePlanner.micronutrientKeys.count, expectedSuffixes.count)
    }

    func testMappingsHaveUniqueKeysAndTypes() {
        let types = HealthKitWritePlanner.mappings.map(\.quantityTypeIdentifier)
        XCTAssertEqual(types.count, Set(types).count)
    }

    func testSeleniumIsPlannedInMicrograms() {
        let specs = HealthKitWritePlanner.plan(
            intakeID: "i", revision: 1, occurredAt: Date(timeIntervalSince1970: 0),
            totals: ["selenium": .known(55, .mcg)])
        XCTAssertEqual(specs.map(\.quantityTypeIdentifier), ["HKQuantityTypeIdentifierDietarySelenium"])
        XCTAssertEqual(specs.first?.unitSymbol, "mcg")
    }
}
