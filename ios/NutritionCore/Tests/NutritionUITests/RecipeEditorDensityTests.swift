import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

@MainActor
final class RecipeEditorDensityTests: XCTestCase {
    private func makeModel() throws -> RecipeEditorViewModel {
        let store = try SwiftDataRecipeStore(url: try uiTempURL(self, "recipes.store"))
        let model = RecipeEditorViewModel(store: store)
        model.ingredients[0].name = "All-Purpose Flour"
        return model
    }

    func testSuggestionAppearsWhenDensityIsBlank() throws {
        let model = try makeModel()
        let suggestion = try XCTUnwrap(model.densitySuggestion(for: model.ingredients[0]))
        XCTAssertEqual(suggestion.name, "All-Purpose Flour")
        XCTAssertEqual(suggestion.gramsPerCup, uiDec("120"))
        XCTAssertEqual(suggestion.gramsPerMilliliter, uiDec("0.50721"))
    }

    func testNoSuggestionForUnknownNameOrAmbiguousName() throws {
        let model = try makeModel()
        model.ingredients[0].name = "Dragon fruit"
        XCTAssertNil(model.densitySuggestion(for: model.ingredients[0]))
        model.ingredients[0].name = "Walnuts"
        XCTAssertNil(model.densitySuggestion(for: model.ingredients[0]))
    }

    func testApplyFillsDensityAndMarksItAsCatalogValue() throws {
        let model = try makeModel()
        let id = model.ingredients[0].id
        model.applyDensitySuggestion(to: id)
        XCTAssertEqual(model.ingredients[0].densityText, "0.50721")
        XCTAssertNil(model.densitySuggestion(for: model.ingredients[0]))
        XCTAssertTrue(model.showsCatalogDensity(for: id))
        model.ingredients[0].densityText = "0.5"
        XCTAssertFalse(model.showsCatalogDensity(for: id))
    }

    func testTypedDensityIsNeverOverwritten() throws {
        let model = try makeModel()
        let id = model.ingredients[0].id
        model.ingredients[0].densityText = "0.6"
        XCTAssertNil(model.densitySuggestion(for: model.ingredients[0]))
        model.applyDensitySuggestion(to: id)
        XCTAssertEqual(model.ingredients[0].densityText, "0.6")
        XCTAssertFalse(model.showsCatalogDensity(for: id))
    }

    func testSuggestionUsesTheAliasAndKeepsItsName() throws {
        let model = try makeModel()
        model.ingredients[0].name = "plain flour"
        let suggestion = try XCTUnwrap(model.densitySuggestion(for: model.ingredients[0]))
        XCTAssertEqual(suggestion.name, "All-Purpose Flour")
    }
}
