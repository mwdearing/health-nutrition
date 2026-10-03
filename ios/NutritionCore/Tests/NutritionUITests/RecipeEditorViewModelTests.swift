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
}
