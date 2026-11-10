import Foundation
import NutritionDomain
@testable import NutritionJournal
import XCTest

final class JournalExportDamagedProductTests: XCTestCase {
    func testExportKeepsAnEntryWhoseProductNutrientsAreDamaged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let product = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Oats", brand: "Sample Brand",
            barcode: "00000000", labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1")
            .withNutrients(["protein": .known(Decimal(5), .g)])
        try store.create(
            Intake(id: "00000000-0000-4000-8000-000000000001", category: "food", occurredAt: when,
                   timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: product, now: when)
        try store.damageNutrientsOnSnapshotForTesting(snapshotID: "snap-1")

        let export = try JournalExporter.makeExport(
            store: store, goals: InMemoryGoalStore(), appVersion: "test", exportedAt: when)

        XCTAssertEqual(export.intakes.count, 1)
        XCTAssertEqual(export.intakes[0].revisions[0].provenance?.name, "Oats")
    }
}
