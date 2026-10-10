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
        let cup = try qty("1", .cup).converted(to: .mL).value
        XCTAssertEqual(cup, try dec("236.5882365"))
        XCTAssertEqual(try qty("16", .tablespoon).converted(to: .mL).value, cup)
        let tablespoon = try qty("1", .tablespoon).converted(to: .mL).value
        XCTAssertEqual(try qty("3", .teaspoon).converted(to: .mL).value, tablespoon)
    }

    /// Grams come from the table's own cup figure, so a cup of flour is exactly its table value, not a
    /// cup times a rounded density. Honey is 340 g a cup, so a tablespoon is 21.25 g exactly.
    func testGramsForAVolumeComeFromTheCupFigureExactly() throws {
        let flour = try XCTUnwrap(IngredientDensityCatalog.match("all-purpose flour"))
        XCTAssertEqual(flour.grams(forMilliliters: try dec("473.176473")), try dec("240"))
        let honey = try XCTUnwrap(IngredientDensityCatalog.match("honey"))
        XCTAssertEqual(honey.grams(forMilliliters: try dec("14.78676478125")), try dec("21.25"))
    }

    func testAttributionIsPinned() {
        XCTAssertEqual(
            IngredientDensityCatalog.attribution,
            "Ingredient densities: ExactCup, CC BY 4.0 (exactcup.github.io).")
    }
}
