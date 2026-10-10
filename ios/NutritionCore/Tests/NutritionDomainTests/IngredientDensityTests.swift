import XCTest
@testable import NutritionDomain

final class IngredientDensityTests: XCTestCase {
    func testCatalogHoldsEightyRows() {
        XCTAssertEqual(IngredientDensityCatalog.rows.count, 80)
    }

    func testFlourMatchesByNameAliasAndSlug() throws {
        let byName = try XCTUnwrap(IngredientDensityCatalog.match("All-Purpose Flour"))
        XCTAssertEqual(byName.slug, "all-purpose-flour")
        XCTAssertEqual(IngredientDensityCatalog.match("  ALL-PURPOSE   flour ")?.slug, "all-purpose-flour")
        XCTAssertEqual(IngredientDensityCatalog.match("all purpose flour")?.slug, "all-purpose-flour")
        XCTAssertEqual(IngredientDensityCatalog.match("plain flour")?.slug, "all-purpose-flour")
        XCTAssertEqual(IngredientDensityCatalog.match("AP  Flour")?.slug, "all-purpose-flour")
    }

    func testAmbiguousNamesReturnNil() {
        // Each of these names belongs to more than one row, so the lookup refuses to guess.
        XCTAssertNil(IngredientDensityCatalog.match("walnuts"))
        XCTAssertNil(IngredientDensityCatalog.match("caster sugar"))
        XCTAssertNil(IngredientDensityCatalog.match("pecans"))
    }

    func testUnknownAndPartialNamesReturnNil() {
        XCTAssertNil(IngredientDensityCatalog.match("dragon fruit"))
        XCTAssertNil(IngredientDensityCatalog.match("flour"))
        XCTAssertNil(IngredientDensityCatalog.match("purpose flour"))
    }

    func testGramsPerMilliliterRoundsToSixFractionDigits() throws {
        let flour = try XCTUnwrap(IngredientDensityCatalog.match("all-purpose flour"))
        // 120 g per cup divided by 236.5882365 mL is 0.50721034...; the stored value keeps six digits.
        XCTAssertEqual(flour.gramsPerMilliliter, try dec("0.50721"))
    }

    func testVolumeFactorsAreExact() throws {
        XCTAssertEqual(milliliters(1, .cup), try dec("236.5882365"))
        XCTAssertEqual(milliliters(16, .tablespoon), milliliters(1, .cup))
        XCTAssertEqual(milliliters(3, .teaspoon), milliliters(1, .tablespoon))
    }

    func testAttributionIsPinned() {
        XCTAssertEqual(
            IngredientDensityCatalog.attribution,
            "Ingredient densities: ExactCup, CC BY 4.0 (exactcup.github.io).")
    }
}
