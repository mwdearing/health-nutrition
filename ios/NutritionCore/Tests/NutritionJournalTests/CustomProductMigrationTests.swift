import Foundation
import SwiftData
import XCTest
import NutritionDomain
@testable import NutritionJournal

final class CustomProductMigrationTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("migration.store")
    }
    func testV6MigrationPreservesEveryExistingEntityAndAddsNoProducts() throws {
        let path = try url()
        try writeV6(path)
        let store = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertEqual(try store.revisions(of: "00000000-0000-4000-8000-000000000001").count, 1)
        XCTAssertEqual(try store.pendingOutbox().count, 1)
        XCTAssertEqual(try store.projections(of: "00000000-0000-4000-8000-000000000001").count, 1)
        let snapshot = try XCTUnwrap(try store.product(snapshotID: "legacy-snapshot"))
        XCTAssertEqual(snapshot.name, "Synthetic V6")
        XCTAssertEqual(snapshot.kind, .supplement)
        XCTAssertEqual(snapshot.nutrients["protein"], .known(Decimal(string: "1.25")!, .g))
        XCTAssertTrue(try store.customProducts().isEmpty)
        store.close()
        let reopened = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try reopened.product(snapshotID: "legacy-snapshot"), snapshot)
    }
    private func writeV6(_ path: URL) throws {
        let schema = Schema(versionedSchema: JournalSchemaV6.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: path, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = "00000000-0000-4000-8000-000000000001"
        context.insert(JournalSchemaV6.IntakeRecord(intakeID: id, category: "supplement", occurredAt: when, timeZoneIdentifier: "UTC", meal: nil, note: nil, lifecycleRaw: "active", currentRevision: 1))
        context.insert(JournalSchemaV6.RevisionRecord(intakeID: id, number: 1, componentsJSON: "[]", productSnapshotID: "legacy-snapshot", changeReason: "created", createdAt: when, occurredAt: when, timeZoneIdentifier: "UTC"))
        context.insert(JournalSchemaV6.ProductRecord(snapshotID: "legacy-snapshot", productID: "legacy-product", name: "Synthetic V6", brand: nil, barcode: nil, labelBasis: "per100g", catalogOrigin: "synthetic", catalogVersion: "1", nutrientsJSON: "[{\"id\":\"protein\",\"state\":\"known\",\"valueText\":\"1.25\",\"unitSymbol\":\"g\"}]", kindRaw: "supplement"))
        context.insert(JournalSchemaV6.ProjectionRecord(intakeID: id, revision: 1, destinationRaw: "relay", actionRaw: "upsert", stateRaw: "pending", isCurrent: true))
        context.insert(JournalSchemaV6.OutboxRecord(operationID: UUID().uuidString, kindRaw: "upsert", intakeID: id, revision: 1, destinationRaw: "relay", payloadHash: "synthetic"))
        try context.save()
    }
    func testFullV1ThroughV7MigrationKeepsContentAndRevisionTime() throws {
        let path = try url(), id = "00000000-0000-4000-8000-000000000002"
        let intake = Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC")
        let snapshot = ProductDefinition(snapshotID: "v1-snapshot", productID: "v1-product", name: "Synthetic V1", labelBasis: "per100g", catalogOrigin: "synthetic", catalogVersion: "1")
        try SwiftDataJournalStore.writeLegacyRevisionForTesting(url: path, intake: intake,
            components: [IntakeComponent(componentID: "portion", name: "Synthetic", amount: 25, unit: .g)], product: snapshot, now: when)
        let store = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertEqual(try store.product(snapshotID: "v1-snapshot"), snapshot)
        XCTAssertEqual(try store.revisions(of: id).first?.components.first?.amount, 25)
        XCTAssertEqual(try store.revisions(of: id).first?.occurredAt, when)
        XCTAssertTrue(try store.customProducts().isEmpty)
    }
}
