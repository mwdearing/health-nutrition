import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

@MainActor
final class RecipeEditorDirtyTests: XCTestCase {
    private func makeModel() throws -> RecipeEditorViewModel {
        let store = try SwiftDataRecipeStore(url: try uiTempURL(self, "recipes-dirty.store"))
        return RecipeEditorViewModel(store: store)
    }

    func testNewRecipeIsNotChangedUntilSomethingIsTyped() throws {
        let model = try makeModel()
        XCTAssertFalse(model.hasTypedInput)
        model.title = "Pancakes"
        XCTAssertTrue(model.hasTypedInput)
    }

    func testIngredientNameCountsAsAChange() throws {
        let model = try makeModel()
        model.ingredients[0].name = "Flour"
        XCTAssertTrue(model.hasTypedInput)
    }

    func testTypingOnlyANutrientCountsAsAChange() throws {
        let model = try makeModel()
        XCTAssertFalse(model.hasTypedInput)
        model.ingredients[0].nutrientTexts["protein"] = "12"
        XCTAssertTrue(model.hasTypedInput)
    }
}
