import XCTest
@testable import NutritionUI

@MainActor
final class CustomProductDirtyTests: XCTestCase {
    private func makeModel() -> CustomProductEditorViewModel {
        CustomProductEditorViewModel(store: ProductEditorStorePort())
    }

    func testUnchangedProductAfterBeingShownHasNoTypedInput() {
        let model = makeModel()
        model.markShown()
        XCTAssertFalse(model.hasTypedInput)
    }

    func testEditingTheNameAfterBeingShownCountsAsTypedInput() {
        let model = makeModel()
        model.markShown()
        model.name = "Vitamin D"
        XCTAssertTrue(model.hasTypedInput)
    }
}
