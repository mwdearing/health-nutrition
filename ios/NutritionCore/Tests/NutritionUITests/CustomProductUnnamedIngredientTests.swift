import Foundation
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

final class CustomProductUnnamedIngredientTests: XCTestCase {
    @MainActor func testUnnamedOtherIngredientShowsNoteOnRowAndBlocksSave() throws {
        let store = ProductEditorStorePort()
        let model = CustomProductEditorViewModel(store: store)
        model.name = "Synthetic ingredient"; model.kind = .supplement
        model.facts = [ProductFactInput(key: "protein", displayName: "Protein", state: .known, amount: "5", unit: .g)]
        let rowID = model.facts[0].id
        model.chooseKey(CustomProductEditorViewModel.otherIngredientTag, for: rowID)
        XCTAssertEqual(model.facts[0].key, "ingredient:")
        XCTAssertEqual(model.unnamedIngredientNote(for: rowID), "Add a name for this ingredient.")
        XCTAssertFalse(model.canSave)
        XCTAssertThrowsError(try model.save(now: Date()))
        XCTAssertTrue(store.commands.isEmpty)
    }
    @MainActor func testWhitespaceOnlyOtherIngredientIsBlockedTheSameWay() throws {
        let store = ProductEditorStorePort()
        let model = CustomProductEditorViewModel(store: store)
        model.name = "Synthetic ingredient"; model.kind = .supplement
        model.facts = [ProductFactInput(key: "ingredient:", displayName: "", state: .known, amount: "5", unit: .g)]
        let rowID = model.facts[0].id
        model.setIngredientName("   ", for: rowID)
        XCTAssertEqual(model.unnamedIngredientNote(for: rowID), "Add a name for this ingredient.")
        XCTAssertFalse(model.canSave)
        XCTAssertThrowsError(try model.save(now: Date()))
        XCTAssertTrue(store.commands.isEmpty)
    }
    @MainActor func testTypingANameClearsNoteAndAllowsSave() throws {
        let store = ProductEditorStorePort()
        let model = CustomProductEditorViewModel(store: store)
        model.name = "Synthetic ingredient"; model.kind = .supplement
        model.servingQuantity = "1"; model.servingUnit = .gummy
        model.facts = [ProductFactInput(key: "ingredient:", displayName: "Activity", state: .known, amount: "5", unit: .g)]
        let rowID = model.facts[0].id
        XCTAssertEqual(model.unnamedIngredientNote(for: rowID), "Add a name for this ingredient.")
        XCTAssertFalse(model.canSave)
        model.setIngredientName("Activity", for: rowID)
        XCTAssertNil(model.unnamedIngredientNote(for: rowID))
        XCTAssertTrue(model.canSave)
        let saved = try model.save(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(saved.content.facts.map(\.key), ["ingredient:Activity"])
        XCTAssertEqual(store.commands.count, 1)
    }
}
