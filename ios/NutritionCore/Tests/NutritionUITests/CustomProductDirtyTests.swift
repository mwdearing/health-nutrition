import XCTest
@testable import NutritionUI

@MainActor
final class CustomProductDirtyTests: XCTestCase {
    private func makeModel() -> CustomProductEditorViewModel {
        CustomProductEditorViewModel(store: ProductEditorStorePort())
    }

    func testUnchangedProductAfterBeingShownHasNoTypedInput() {
        let model = makeModel()
        XCTAssertFalse(model.hasTypedInput)
    }

    func testEditingTheNameAfterBeingShownCountsAsTypedInput() {
        let model = makeModel()
        model.name = "Vitamin D"
        XCTAssertTrue(model.hasTypedInput)
    }

    /// Saving makes what is on screen the saved baseline, so leaving does not ask to discard it.
    func testSavedEditHasNoTypedInputUntilChangedAgain() throws {
        let store = ProductEditorStorePort()
        let model = CustomProductEditorViewModel(store: store)
        model.name = "Synthetic product"; model.kind = .food
        _ = try model.save(now: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(model.hasTypedInput)
        model.name = "Synthetic product two"
        XCTAssertTrue(model.hasTypedInput)
    }
}
