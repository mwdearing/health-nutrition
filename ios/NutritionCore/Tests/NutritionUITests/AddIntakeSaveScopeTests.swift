import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeSaveScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testTypedInEntryIsDiaryOnly() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.name = "Example snack"
        model.amountText = "50"
        model.unit = .g
        XCTAssertEqual(model.saveScopeMessage, "Adds one entry to your Diary only.")
    }

    func testLabelProductIsAlsoSavedToProducts() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-label", productID: "example-label",
            name: "Example bar", labelBasis: "per serving", catalogOrigin: ProductOrigin.label_capture,
            catalogVersion: "1", nutrients: ["protein": .known(10, .g)]), fromLabelCapture: true)
        XCTAssertEqual(model.saveScopeMessage,
            "Adds one entry to your Diary. The product is also saved to Library > Products.")
    }
}
