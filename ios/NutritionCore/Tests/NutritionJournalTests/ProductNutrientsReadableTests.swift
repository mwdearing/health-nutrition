import Foundation
import XCTest
import NutritionDomain
@testable import NutritionJournal

/// A damaged nutrient payload must not read as a product with no nutrients (#1221 item 1).
final class ProductNutrientsReadableTests: XCTestCase {
    func testAMissingPayloadIsReadable() {
        XCTAssertTrue(SwiftDataJournalStore.nutrientsReadable(nil))
    }

    func testAnEmptyListIsReadable() {
        XCTAssertTrue(SwiftDataJournalStore.nutrientsReadable("[]"))
    }

    func testAPayloadThatDoesNotDecodeIsNotReadable() {
        XCTAssertFalse(SwiftDataJournalStore.nutrientsReadable("{not json"))
        XCTAssertFalse(SwiftDataJournalStore.nutrientsReadable("{\"id\":\"fiber\"}"))
    }

    func testAnUpsertReplacesAProductWhosePayloadDoesNotDecode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("readable.store"))
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let intake = Intake(
            id: "00000000-0000-4000-8000-000000000001", category: "food", occurredAt: when,
            timeZoneIdentifier: "UTC", meal: "breakfast")
        let component = IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)
        let original = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Oats", brand: "Sample Brand",
            barcode: "00000000", labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1")
            .withNutrients(["protein": .known(Decimal(5), .g)])
        try store.create(intake, components: [component], product: original, now: when)
        try store.damageNutrientsOnSnapshotForTesting(snapshotID: "snap-1")
        XCTAssertThrowsError(try store.product(snapshotID: "snap-1"))

        let incoming = original.withNutrients(["protein": .known(Decimal(13), .g)])
        try store.edit(
            intakeID: intake.id, components: [component], product: incoming, changeReason: "rescan", now: when)

        XCTAssertEqual(try store.product(snapshotID: "snap-1")?.value(for: "protein"), .known(Decimal(13), .g))
    }
}
