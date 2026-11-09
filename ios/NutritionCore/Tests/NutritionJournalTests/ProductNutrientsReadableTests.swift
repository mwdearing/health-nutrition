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

    func testAnUpsertOfADifferentProductOntoADamagedRowIsAConflict() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("conflict.store"))
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

        let different = ProductDefinition(
            snapshotID: "snap-1", productID: "product-2", name: "Rice", brand: "Sample Brand",
            barcode: "00000000", labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1")
            .withNutrients(["protein": .known(Decimal(13), .g)])
        XCTAssertThrowsError(try store.edit(
            intakeID: intake.id, components: [component], product: different, changeReason: "rescan", now: when)
        ) {
            XCTAssertEqual($0 as? JournalError, .snapshotConflict("snap-1"))
        }
        // The row is unchanged: it is still damaged, and the same product can still heal it.
        XCTAssertThrowsError(try store.product(snapshotID: "snap-1"))
        try store.edit(
            intakeID: intake.id, components: [component], product: original.withNutrients(["protein": .known(Decimal(7), .g)]),
            changeReason: "rescan", now: when)
        let healed = try XCTUnwrap(try store.product(snapshotID: "snap-1"))
        XCTAssertEqual(healed.productID, "product-1")
        XCTAssertEqual(healed.value(for: "protein"), .known(Decimal(7), .g))
    }

    private func makeDamagedStore(_ name: String) throws -> (SwiftDataJournalStore, Intake, IntakeComponent, ProductDefinition) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("\(name).store"))
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
        return (store, intake, component, original)
    }

    func testMealRetagWorksOnADamagedProduct() throws {
        let (store, intake, _, _) = try makeDamagedStore("retag")
        let when = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertNotNil(try store.changeMeal(intakeID: intake.id, meal: "dinner", now: when))
        XCTAssertEqual(try store.activeIntakes().first?.meal, "dinner")
    }

    func testRestoreHealsADamagedRowWithTheSameIdentity() throws {
        // A restore needs a store with no entries, but it can still meet a product row an earlier store left.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("restore.store"))
        let original = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Oats", brand: "Sample Brand",
            barcode: "00000000", labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1")
            .withNutrients(["protein": .known(Decimal(5), .g)])
        try store.insertProductSnapshotForTesting(original)
        try store.damageNutrientsOnSnapshotForTesting(snapshotID: "snap-1")
        let incoming = original.withNutrients(["protein": .known(Decimal(9), .g)])
        _ = try store.restore(
            JournalRestorePlan(entries: [], tombstones: [], products: [incoming], favorites: []))
        XCTAssertEqual(try store.product(snapshotID: "snap-1")?.value(for: "protein"), .known(Decimal(9), .g))
    }
}
