import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

final class RecipeMathTests: XCTestCase {
    func testDecimalIsExact() {
        XCTAssertEqual(dec("0.1") + dec("0.2"), dec("0.3"))
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("a", amount: "1", perUnit: energyPerUnit("0.1")),
                sampleIngredient("b", amount: "1", perUnit: energyPerUnit("0.2")),
            ], yield: .servings(1))
        XCTAssertEqual(RecipeMath.totals(of: version).values["energy"], .known(dec("0.3"), .kcal))
    }

    func testPerServingMath() throws {
        let totals = RecipeMath.totals(of: sampleVersion())
        XCTAssertEqual(totals.values["energy"], .known(dec("896"), .kcal))
        let one = try RecipeMath.perPortion(totals, yield: .servings(4), portion: 1)
        XCTAssertEqual(one["energy"], .known(dec("224"), .kcal))
        let two = try RecipeMath.perPortion(totals, yield: .servings(4), portion: 2)
        XCTAssertEqual(two["energy"], .known(dec("448"), .kcal))
    }

    func testPerGramOfTotalYield() throws {
        let yield = RecipeYield.total(Quantity(value: dec("800"), unit: .g))
        let totals = RecipeMath.totals(of: sampleVersion(yield: yield))
        let portion = try RecipeMath.perPortion(totals, yield: yield, portion: 100)
        XCTAssertEqual(portion["energy"], .known(dec("112"), .kcal))
        let inKilograms = try RecipeMath.perPortion(totals, yield: yield, portion: dec("0.1"), portionUnit: .kg)
        XCTAssertEqual(inKilograms["energy"], .known(dec("112"), .kcal))
    }

    func testPortionDimensionMismatchThrows() {
        let yield = RecipeYield.total(Quantity(value: 800, unit: .g))
        let totals = RecipeMath.totals(of: sampleVersion(yield: yield))
        XCTAssertThrowsError(try RecipeMath.perPortion(totals, yield: yield, portion: 1, portionUnit: .mL)) {
            XCTAssertEqual($0 as? RecipeError, .portionDimensionMismatch)
        }
    }

    func testUnknownPropagatesWithLackingCount() throws {
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("a", amount: "10", perUnit: ["energy": .known(1, .kcal), "protein": .known(1, .g)]),
                sampleIngredient("b", amount: "10", perUnit: ["energy": .unknown, "protein": .known(1, .g)]),
                sampleIngredient("c", amount: "10", perUnit: ["protein": .known(1, .g)]),
            ])
        let totals = RecipeMath.totals(of: version)
        XCTAssertEqual(totals.values["energy"], .unknown)
        XCTAssertEqual(totals.lacking["energy"], 2)
        XCTAssertEqual(totals.values["protein"], .known(30, .g))
        XCTAssertEqual(totals.lacking["protein"], 0)
        XCTAssertEqual(totals.ingredientCount, 3)
        let portion = try RecipeMath.perPortion(totals, yield: .servings(4), portion: 1)
        XCTAssertEqual(portion["energy"], .unknown)
    }

    func testOneOfThreeLackingCoverageText() {
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("a", amount: "10", perUnit: energyPerUnit("1")),
                sampleIngredient("b", amount: "10", perUnit: energyPerUnit("1")),
                sampleIngredient("c", amount: "10", perUnit: [:]),
            ])
        let totals = RecipeMath.totals(of: version)
        XCTAssertEqual(totals.lacking["energy"], 1)
        let line = RecipeCoverage.make(from: totals).first
        XCTAssertEqual(line?.text(nutrientName: "energy"), "1 of 3 ingredients lack energy")
    }

    func testKnownZeroStaysZero() {
        let version = sampleVersion(
            ingredients: [sampleIngredient("water", amount: "100", perUnit: energyPerUnit("0"))])
        let totals = RecipeMath.totals(of: version)
        XCTAssertEqual(totals.values["energy"], .known(0, .kcal))
        XCTAssertEqual(totals.lacking["energy"], 0)
    }

    func testMassUnitsConvert() {
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("a", amount: "0.5", unit: .kg, perUnit: energyPerUnit("2"), basis: .g),
                sampleIngredient("b", amount: "500", unit: .mg, perUnit: energyPerUnit("2"), basis: .g),
            ])
        // 0.5 kg = 500 g -> 1000 kcal; 500 mg = 0.5 g -> 1 kcal.
        XCTAssertEqual(RecipeMath.totals(of: version).values["energy"], .known(1001, .kcal))
    }

    func testMassToVolumeWithoutDensityIsLacking() {
        let version = sampleVersion(
            ingredients: [sampleIngredient("milk", amount: "250", unit: .mL, perUnit: energyPerUnit("0.5"), basis: .g)])
        let totals = RecipeMath.totals(of: version)
        XCTAssertEqual(totals.values["energy"], .unknown)
        XCTAssertEqual(totals.lacking["energy"], 1)
    }

    func testMassToVolumeWithDensityResolves() {
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("milk", amount: "250", unit: .mL, perUnit: energyPerUnit("0.5"), density: dec("1.0"), basis: .g)
            ])
        XCTAssertEqual(RecipeMath.totals(of: version).values["energy"], .known(125, .kcal))
    }

    func testYieldZeroAndNegativeRejected() {
        for bad in [Decimal(0), Decimal(-1)] {
            XCTAssertThrowsError(try sampleVersion(yield: .servings(bad)).validate()) {
                XCTAssertEqual($0 as? RecipeError, .nonPositiveYield)
            }
        }
        XCTAssertThrowsError(try sampleVersion(yield: .total(Quantity(value: 0, unit: .g))).validate())
    }

    func testPortionNotPositiveRejected() {
        let totals = RecipeMath.totals(of: sampleVersion())
        for bad in [Decimal(0), Decimal(-2)] {
            XCTAssertThrowsError(try RecipeMath.perPortion(totals, yield: .servings(4), portion: bad)) {
                XCTAssertEqual($0 as? RecipeError, .nonPositivePortion)
            }
        }
    }

    func testValidationRules() {
        XCTAssertThrowsError(try sampleVersion(title: "  ").validate())
        XCTAssertThrowsError(try sampleVersion(ingredients: []).validate())
        XCTAssertThrowsError(try sampleVersion(number: 0).validate())
        let duplicate = [
            sampleIngredient("a", amount: "1", perUnit: [:]), sampleIngredient("a", amount: "2", perUnit: [:]),
        ]
        XCTAssertThrowsError(try sampleVersion(ingredients: duplicate).validate()) {
            XCTAssertEqual($0 as? RecipeError, .duplicateIngredientID("a"))
        }
        let zero = [sampleIngredient("a", amount: "0", perUnit: [:])]
        XCTAssertThrowsError(try sampleVersion(ingredients: zero).validate())
        XCTAssertNoThrow(try sampleVersion().validate())
    }
}
