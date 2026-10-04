import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class RecipeAccessibilityTests: XCTestCase {
    func testStaticLabelsAreNonEmpty() {
        let labels = [
            RecipeLabels.newRecipe, RecipeLabels.saveRecipe, RecipeLabels.addIngredient, RecipeLabels.logPortion,
            RecipeLabels.editRecipe, RecipeLabels.portionField, RecipeLabels.titleField, RecipeLabels.notesField,
            RecipeLabels.yieldAmountField, RecipeLabels.yieldKindPicker, RecipeLabels.recipesRow,
        ]
        for label in labels { XCTAssertFalse(label.isEmpty) }
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testRowLabelsNameTheItem() {
        XCTAssertEqual(RecipeLabels.open(title: "Oat bake", version: 2), "Open Oat bake, version 2")
        XCTAssertEqual(RecipeLabels.delete(title: "Oat bake"), "Delete Oat bake")
        XCTAssertEqual(RecipeLabels.ingredientAmount(2), "Amount of ingredient 2")
        XCTAssertEqual(RecipeLabels.nutrientField("Protein", position: 1), "Protein per unit of ingredient 1")
    }

    func testListViewModelMessages() throws {
        let store = try SwiftDataRecipeStore(url: try uiTempURL(self, "recipes.store"))
        try store.saveNewVersion(uiSampleVersion())
        let model = RecipeListViewModel(store: store)
        model.load()
        XCTAssertEqual(model.items.map { $0.title }, ["Oat bake"])
        XCTAssertNil(model.skippedMessage)
        XCTAssertEqual(RecipeListViewModel.skippedText(3), "3 stored recipes could not be read")
        XCTAssertEqual(RecipeListViewModel.skippedText(1), "1 stored recipe could not be read")
        model.delete(id: "recipe-1")
        XCTAssertTrue(model.items.isEmpty)
    }
}
