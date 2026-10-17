import Foundation
import SwiftData
import XCTest
import NutritionDomain
@testable import NutritionJournal

/// An entry whose product row has gone missing from the store: edits and meal changes keep the link as it
/// is, and only a product row that is still stored can be cleared by an edit with no product.
final class DanglingProductLinkTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)
    private let snapshotID = "dangling-snapshot"

    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("dangling.store")
    }

    private func product() -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshotID, productID: "dangling-product", name: "Synthetic bar", brand: nil, barcode: nil,
            labelBasis: "per serving", catalogOrigin: "synthetic", catalogVersion: "1", kind: .food,
            nutrients: [:], nutrientDisplayNames: [:])
    }

    /// Logs an entry linked to a product, then removes that product row the way a missing row would look.
    private func logLinkedEntry(at path: URL, id: String) throws {
        let store = try SwiftDataJournalStore(url: path)
        try store.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 1, unit: .g)],
            product: product(), now: when)
        let schema = Schema(versionedSchema: JournalSchemaV10.self)
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: path, cloudKitDatabase: .none))
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<JournalSchemaV6.ProductRecord>(
            predicate: #Predicate { $0.snapshotID == "dangling-snapshot" })) {
            context.delete(row)
        }
        try context.save()
    }

    func testEditWithNoProductKeepsALinkWhoseProductRowIsMissing() throws {
        let path = try url(), id = "00000000-0000-4000-8000-0000000000a1"
        try logLinkedEntry(at: path, id: id)
        let store = try SwiftDataJournalStore(url: path)
        _ = try store.edit(
            intakeID: id,
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 2, unit: .g)],
            product: nil, changeReason: "Amount changed", now: when, occurredAt: nil, timeZoneIdentifier: nil)
        let second = try XCTUnwrap(try store.revisions(of: id).first { $0.number == 2 })
        XCTAssertEqual(second.productSnapshotID, snapshotID)
    }

    func testChangeMealKeepsALinkWhoseProductRowIsMissing() throws {
        let path = try url(), id = "00000000-0000-4000-8000-0000000000a2"
        try logLinkedEntry(at: path, id: id)
        let store = try SwiftDataJournalStore(url: path)
        let revision = try XCTUnwrap(try store.changeMeal(intakeID: id, meal: "dinner", now: when))
        XCTAssertEqual(revision.productSnapshotID, snapshotID)
    }

    func testEditWithNoProductClearsALinkWhenItsProductRowIsStored() throws {
        let path = try url(), id = "00000000-0000-4000-8000-0000000000a3"
        let store = try SwiftDataJournalStore(url: path)
        try store.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 1, unit: .g)],
            product: product(), now: when)
        _ = try store.edit(
            intakeID: id,
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 2, unit: .g)],
            product: nil, changeReason: "Amount changed", now: when, occurredAt: nil, timeZoneIdentifier: nil)
        let second = try XCTUnwrap(try store.revisions(of: id).first { $0.number == 2 })
        XCTAssertNil(second.productSnapshotID)
    }
}
