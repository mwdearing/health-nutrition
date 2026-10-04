import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
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
        for bad in ["1,5", "abc"] {
            let model = filledModel(store)
            model.ingredients[0].amountText = bad
            XCTAssertFalse(model.save(now: when))
            XCTAssertFalse(model.messages.isEmpty)
        }
        let model = filledModel(store)
        model.ingredients[0].nutrientTexts["protein"] = "1,5"
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
}
