import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

@MainActor
final class RecipeEditorViewModelTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataRecipeStore {
        try SwiftDataRecipeStore(url: try uiTempURL(self, "recipes.store"))
    }

    private func filledModel(_ store: RecipeStore) -> RecipeEditorViewModel {
        let model = RecipeEditorViewModel(store: store, makeID: { "recipe-new" })
        model.title = "Oat bake"
        model.ingredients[0].name = "Oat flour"
        model.ingredients[0].amountText = "200"
        model.ingredients[0].nutrientTexts["energy"] = "3.5"
        model.yieldAmountText = "4"
        return model
    }

    func testSaveCreatesVersion1() throws {
        let store = try makeStore()
        let model = filledModel(store)
        XCTAssertTrue(model.save(now: when))
        let saved = try store.version(recipeID: "recipe-new", number: 1)
        XCTAssertEqual(saved?.ingredients.first?.perUnit["energy"], .known(uiDec("3.5"), .kcal))
        XCTAssertEqual(saved?.ingredients.first?.perUnit["protein"], .unknown)
    }

    func testEditCreatesVersion2AndKeepsVersion1() throws {
        let store = try makeStore()
        let first = filledModel(store)
        XCTAssertTrue(first.save(now: when))
        let v1 = try XCTUnwrap(try store.version(recipeID: "recipe-new", number: 1))
        let edit = RecipeEditorViewModel(store: store, editing: v1)
        edit.ingredients[0].amountText = "250"
        XCTAssertTrue(edit.save(now: when))
        XCTAssertEqual(try store.version(recipeID: "recipe-new", number: 1), v1)
        XCTAssertEqual(try store.version(recipeID: "recipe-new", number: 2)?.ingredients.first?.quantity.value, 250)
    }

    func testEmptyTitleAndNoIngredientsRejected() throws {
        let store = try makeStore()
        let model = RecipeEditorViewModel(store: store)
        model.removeIngredient(id: model.ingredients[0].id)
        XCTAssertFalse(model.save(now: when))
        XCTAssertTrue(model.messages.contains("Enter a title."))
        XCTAssertTrue(model.messages.contains("Add at least one ingredient."))
        XCTAssertTrue(try store.list().recipes.isEmpty)
    }

    func testBadDecimalTextRejected() throws {
        let store = try makeStore()
        for bad in ["1,5,0", "abc"] {
            let model = filledModel(store)
            model.ingredients[0].amountText = bad
            XCTAssertFalse(model.save(now: when))
            XCTAssertFalse(model.messages.isEmpty)
        }
        let model = filledModel(store)
        model.ingredients[0].nutrientTexts["protein"] = "1,5,0"
        XCTAssertFalse(model.save(now: when))
        XCTAssertTrue(try store.list().recipes.isEmpty)
    }

    func testUnknownUnitAndBadYieldRejected() throws {
        let store = try makeStore()
        let model = filledModel(store)
        model.ingredients[0].unitSymbol = "pinch"
        model.yieldAmountText = "0"
        XCTAssertFalse(model.save(now: when))
        XCTAssertEqual(model.messages.count, 2)
    }

    func testZeroNutrientIsKnownAndBlankIsUnknown() throws {
        let store = try makeStore()
        let model = filledModel(store)
        model.ingredients[0].nutrientTexts["sodium"] = "0"
        XCTAssertTrue(model.save(now: when))
        let saved = try store.version(recipeID: "recipe-new", number: 1)
        XCTAssertEqual(saved?.ingredients.first?.perUnit["sodium"], .known(0, .mg))
        XCTAssertEqual(saved?.ingredients.first?.perUnit["protein"], .unknown)
    }

    /// Editing a recipe must not drop the unit its per-unit values are stated in, even though the
    /// editor has no field for it.
    func testEditKeepsExplicitBasisUnit() throws {
        let store = try makeStore()
        let version = RecipeVersion(
            recipeID: "recipe-basis", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .mL),
                    perUnit: ["energy": .known(uiDec("3.5"), .kcal)], density: uiDec("0.4"),
                    basisUnit: .g)
            ],
            yield: .servings(4), createdAt: when)
        try store.saveNewVersion(version)

        let edit = RecipeEditorViewModel(store: store, editing: version)
        edit.ingredients[0].amountText = "250"
        XCTAssertTrue(edit.save(now: when), "\(edit.messages)")

        let v2 = try XCTUnwrap(try store.version(recipeID: "recipe-basis", number: 2))
        XCTAssertEqual(v2.ingredients.first?.basisUnit, .g)
        XCTAssertEqual(v2.ingredients.first?.quantity.value, 250)
        XCTAssertEqual(v2.ingredients.first?.density, uiDec("0.4"))
        // The stored version still round-trips through the same store.
        let reread = try XCTUnwrap(try store.version(recipeID: "recipe-basis", number: 2))
        XCTAssertEqual(reread.ingredients.first?.basisUnit, .g)
    }

    /// A new draft has no explicit basis unit; the ingredient's own unit is the basis.
    func testNewDraftHasNoExplicitBasisUnit() throws {
        let store = try makeStore()
        let model = filledModel(store)
        XCTAssertNil(model.ingredients[0].basisUnit)
        XCTAssertTrue(model.save(now: when))
        XCTAssertNil(try store.version(recipeID: "recipe-new", number: 1)?.ingredients.first?.basisUnit)
    }

    /// A value stored in another unit of the same kind is converted into the field's unit, so a
    /// title-only edit never turns 1000 mg of protein into 1000 g.
    func testLoadedNutrientInAnotherUnitIsConvertedExactly() throws {
        let store = try makeStore()
        let version = RecipeVersion(
            recipeID: "recipe-units", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                    perUnit: ["protein": .known(1000, .mg)])
            ],
            yield: .servings(4), createdAt: when)
        try store.saveNewVersion(version)

        let edit = RecipeEditorViewModel(store: store, editing: version)
        XCTAssertEqual(edit.ingredients[0].nutrientTexts["protein"], "1")
        XCTAssertNil(edit.ingredients[0].nutrientUnits["protein"])
        XCTAssertTrue(edit.save(now: when), "\(edit.messages)")

        let v2 = try XCTUnwrap(try store.version(recipeID: "recipe-units", number: 2))
        XCTAssertEqual(v2.ingredients.first?.perUnit["protein"], .known(1, .g))
    }

    /// A unit that cannot be converted (a mass against an energy value) keeps both the number and the
    /// unit it was stored in, rather than being written under the field's unit.
    func testLoadedNutrientThatCannotBeConvertedKeepsItsOwnUnit() throws {
        let store = try makeStore()
        let version = RecipeVersion(
            recipeID: "recipe-odd", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                    perUnit: ["protein": .known(1000, .iu)])
            ],
            yield: .servings(4), createdAt: when)
        try store.saveNewVersion(version)

        let edit = RecipeEditorViewModel(store: store, editing: version)
        XCTAssertEqual(edit.ingredients[0].nutrientTexts["protein"], "1000")
        XCTAssertEqual(edit.ingredients[0].nutrientUnits["protein"], .iu)
        XCTAssertTrue(edit.save(now: when), "\(edit.messages)")

        let v2 = try XCTUnwrap(try store.version(recipeID: "recipe-odd", number: 2))
        XCTAssertEqual(v2.ingredients.first?.perUnit["protein"], .known(1000, .iu))
    }

    /// Not-applicable and below-threshold are stated values, not missing ones, so an edit that leaves the
    /// field alone must not turn them into unknown.
    func testNotApplicableAndBelowThresholdSurviveAnEdit() throws {
        let store = try makeStore()
        let version = RecipeVersion(
            recipeID: "recipe-states", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                    perUnit: [
                        "energy": .known(Decimal(360), .kcal),
                        "protein": .notApplicable,
                        "sodium": .belowReportingThreshold(.mg),
                        "fiber": .unknown,
                    ])
            ],
            yield: .servings(4), createdAt: when)
        try store.saveNewVersion(version)

        let edit = RecipeEditorViewModel(store: store, editing: version)
        edit.title = "Oat bake, richer"
        XCTAssertTrue(edit.save(now: when), "\(edit.messages)")

        let v2 = try XCTUnwrap(try store.version(recipeID: "recipe-states", number: 2))
        let perUnit = try XCTUnwrap(v2.ingredients.first?.perUnit)
        XCTAssertEqual(perUnit["protein"], .notApplicable)
        XCTAssertEqual(perUnit["sodium"], .belowReportingThreshold(.mg))
        XCTAssertEqual(perUnit["fiber"], .unknown)
        XCTAssertEqual(perUnit["energy"], .known(Decimal(360), .kcal))
    }

    /// Typing a number where a state was stored replaces it: that is what the user asked for.
    func testTypingOverAStateReplacesIt() throws {
        let store = try makeStore()
        let version = RecipeVersion(
            recipeID: "recipe-states-typed", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                    perUnit: ["protein": .notApplicable])
            ],
            yield: .servings(4), createdAt: when)
        try store.saveNewVersion(version)

        let edit = RecipeEditorViewModel(store: store, editing: version)
        edit.ingredients[0].nutrientTexts["protein"] = "12"
        XCTAssertTrue(edit.save(now: when), "\(edit.messages)")

        let v2 = try XCTUnwrap(try store.version(recipeID: "recipe-states-typed", number: 2))
        XCTAssertEqual(v2.ingredients.first?.perUnit["protein"], .known(Decimal(12), .g))
    }

    /// A damaged stored row still holds its version number, so saving takes the number the store expects
/// rather than refusing the edit.
    func testEditingSucceedsAfterADamagedStoredVersion() throws {
        let store = try makeStore()
        let first = filledModel(store)
        XCTAssertTrue(first.save(now: when))
        try store.insertRawRowForTesting(
            recipeID: "recipe-new", number: 2, title: "Oat bake", payloadJSON: "{not json",
            createdAt: when)

        let edit = RecipeEditorViewModel(store: store, editing: try XCTUnwrap(store.version(recipeID: "recipe-new", number: 1)))
        edit.title = "Oat bake, richer"
        XCTAssertTrue(edit.save(now: when), "\(edit.messages)")
        XCTAssertEqual(try store.version(recipeID: "recipe-new", number: 3)?.title, "Oat bake, richer")
    }

    /// The prompt above the nutrient fields names the unit the values are actually stated in.
    func testBasisSymbolNamesTheExplicitBasisUnit() throws {
        let store = try makeStore()
        let version = RecipeVersion(
            recipeID: "recipe-basis-label", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "milk", name: "Milk", quantity: Quantity(value: 250, unit: .mL),
                    perUnit: ["protein": .known(3, .g)], basisUnit: .g)
            ],
            yield: .servings(2), createdAt: when)
        try store.saveNewVersion(version)

        let edit = RecipeEditorViewModel(store: store, editing: version)
        XCTAssertEqual(edit.ingredients[0].unitSymbol, "mL")
        XCTAssertEqual(edit.ingredients[0].basisSymbol, "g")
        let fresh = RecipeEditorViewModel(store: store)
        XCTAssertEqual(fresh.ingredients[0].basisSymbol, "g")
    }

    /// Every nutrient the Today screen tracks by default must be enterable in the recipe editor,
    /// otherwise a recipe logged from the editor always reads as lacking it.
    func testEveryDefaultTrackedNutrientIsEditable() throws {
        let editable = Set(RecipeNutrientField.all.map(\.id))
        for nutrient in TodayViewModel.defaultTrackedNutrients {
            XCTAssertTrue(editable.contains(nutrient), "\(nutrient) has no editor field")
        }
        XCTAssertEqual(RecipeNutrientField.all.first { $0.id == "potassium" }?.unit, .mg)
        XCTAssertEqual(RecipeNutrientField.all.first { $0.id == "fiber" }?.unit, .g)

        let store = try makeStore()
        let model = filledModel(store)
        model.ingredients[0].nutrientTexts["potassium"] = "400"
        model.ingredients[0].nutrientTexts["fiber"] = "10"
        XCTAssertTrue(model.save(now: when), "\(model.messages)")
        let saved = try XCTUnwrap(try store.version(recipeID: "recipe-new", number: 1))
        XCTAssertEqual(saved.ingredients.first?.perUnit["potassium"], .known(400, .mg))
        XCTAssertEqual(saved.ingredients.first?.perUnit["fiber"], .known(10, .g))
    }

    /// The recipe editor must not offer the ounces. A recipe yield becomes the component of a logged
    /// entry through `RecipeLogger.portionQuantity`, with no normalization step of its own, so an
    /// ounce yield would be stored as an ounce and reach the export, which Add intake never does.
    func testTheRecipeEditorOffersNoOunceUnits() throws {
        let store = try makeStore()
        let model = RecipeEditorViewModel(store: store)

        XCTAssertFalse(model.unitSymbols.contains("oz"))
        XCTAssertFalse(model.unitSymbols.contains("fl oz"))
        // The typed volume measures are input-only too, so the recipe editor offers none of them.
        XCTAssertFalse(model.unitSymbols.contains("cup"))
        XCTAssertFalse(model.unitSymbols.contains("tbsp"))
        XCTAssertFalse(model.unitSymbols.contains("tsp"))
        XCTAssertEqual(
            Set(model.unitSymbols),
            Set(UnitRegistry.all.map(\.symbol)).subtracting(["oz", "fl oz", "cup", "tbsp", "tsp"]))
        // The units a recipe does offer are all metric, so a saved yield is stored as one of them.
        for symbol in model.unitSymbols {
            let unit = try XCTUnwrap(try? MeasureUnit(symbol: symbol), symbol)
            XCTAssertNotEqual(unit, .oz, symbol)
            XCTAssertNotEqual(unit, .flOz, symbol)
        }
        XCTAssertEqual(RecipeEditorViewModel.unitSymbols, model.unitSymbols)
    }

    /// A total yield saved from the editor is stored in the metric unit it was entered in, which is
    /// what makes the logged component metric too.
    func testARecipeYieldIsSavedInAMetricUnit() throws {
        let store = try makeStore()
        let model = filledModel(store)
        model.yieldKind = .total
        model.yieldAmountText = "500"
        model.yieldUnitSymbol = "g"
        XCTAssertTrue(model.save(now: when), "\(model.messages)")

        let saved = try XCTUnwrap(try store.version(recipeID: "recipe-new", number: 1))
        guard case .total(let quantity) = try XCTUnwrap(saved.yield) else {
            return XCTFail("the yield was not saved as a total")
        }
        XCTAssertEqual(quantity.unit, .g)
        XCTAssertEqual(quantity.value, Decimal(500))
        XCTAssertTrue(model.unitSymbols.contains(quantity.unit.symbol))
    }
}
