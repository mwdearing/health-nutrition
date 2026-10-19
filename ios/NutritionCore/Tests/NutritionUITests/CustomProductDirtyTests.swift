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
}
