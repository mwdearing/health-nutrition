import XCTest
@testable import NutritionUI

final class NutrientNamesTests: XCTestCase {
    /// A scanned label that printed "protein" in lower case still shows the canonical "Protein".
    func testKnownNutrientShowsItsCanonicalNameNotThePrintedWords() throws {
        XCTAssertEqual(NutrientNames.displayName(for: "protein", displayNames: ["protein": "protein"]), "Protein")
        XCTAssertEqual(NutrientNames.displayName(for: "fat", displayNames: ["fat": "fat"]), "Fat")
    }

    /// An extra with no canonical name keeps the words the label printed for it.
    func testExtraWithoutCanonicalNameKeepsItsPrintedName() throws {
        XCTAssertEqual(NutrientNames.displayName(for: "ingredient:salt", displayNames: ["ingredient:salt": "Salt"]), "Salt")
    }

    /// A camel-case key with no printed name is spelled out, matching the picker's names.
    func testCamelCaseFallbackMatchesPickerNames() throws {
        XCTAssertEqual(NutrientNames.displayName(for: "transFat"), "Trans fat")
        XCTAssertEqual(NutrientNames.displayName(for: "saturatedFat"), "Saturated fat")
        XCTAssertEqual(NutrientNames.displayName(for: "addedSugars"), "Added sugars")
        XCTAssertEqual(NutrientNames.displayName(for: "sugars"), "Total sugars")
        XCTAssertEqual(NutrientNames.displayName(for: "cholesterol"), "Cholesterol")
    }
}
