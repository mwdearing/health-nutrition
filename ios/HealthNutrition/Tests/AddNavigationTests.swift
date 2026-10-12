import NutritionUI
import NutritionDomain
import NutritionJournal
import Foundation
import XCTest
@testable import HealthNutrition

@MainActor
final class AddNavigationTests: XCTestCase {
    func testAddNavigationResetsOnCancelAndSave() {
        let model = AddNavigationModel()
        for route in [AddRoute.barcodeScanner, .labelScanner, .library, .productSearch, .details(nil)] {
            model.path = [route]
            model.reset()
            XCTAssertEqual(model.path, [])
        }
    }
}

@MainActor extension AddNavigationTests {
    func testProductSelectionRoutesToDetailsWithoutLoggingOrPublishing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("synthetic.store"))
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: .init(name: "Synthetic product", kind: .supplement, basis: .perServing))
        try store.saveCustomProduct(.init(revision: item), now: Date())
        let navigation = AddNavigationModel(), home = AddHomeViewModel(store: store)
        try navigation.openProduct(item, home: home, now: Date())
        guard case .details(let prefill) = navigation.path.last else { return XCTFail("Expected intake details") }
        XCTAssertEqual(prefill?.model.name, item.content.name)
        XCTAssertEqual(prefill?.model.amountText, "")
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.productOperations(ownerID: UUID()).isEmpty)
        let editor = CustomProductEditorViewModel(store: store, revision: item)
        navigation.path.append(.productEditor(ProductEditorPrefill(model: editor)))
        navigation.reset(); XCTAssertTrue(navigation.path.isEmpty)
    }
}
