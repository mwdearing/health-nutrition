import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Pruning of acknowledged outbox rows. A pruned row is observable through `acknowledge`: acknowledging an
/// unknown operation throws `unknownOperation`, while a kept row accepts the call as the idempotent no-op it is.
final class JournalRetentionTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore(_ directory: URL) throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func newID() -> String {
        UUID().uuidString.lowercased()
    }

    private func sampleIntake(id: String) -> Intake {
        Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast")
    }

    private func oats(_ grams: Decimal = 40) -> IntakeComponent {
        IntakeComponent(componentID: "oats", name: "Rolled oats", amount: grams, unit: .g)
    }

    private func product(_ snapshotID: String, name: String) -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshotID, productID: "product-1", name: name, brand: "Sample Brand",
            barcode: "00000000", labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1")
    }

    /// Creates one intake (two outbox rows, one per enabled destination) and returns its operation IDs.
    private func queueIntake(_ store: SwiftDataJournalStore, id: String) throws -> [String] {
        try store.create(sampleIntake(id: id), components: [oats()], product: nil, now: when)
        return try store.pendingOutbox().filter { $0.intakeID == id }.map(\.operationID)
    }

    private func acknowledge(_ store: SwiftDataJournalStore, _ operationIDs: [String], daysBefore: Double) throws {
        for operationID in operationIDs {
            try store.acknowledge(operationID: operationID, at: when.addingTimeInterval(-daysBefore * day))
        }
    }

    private func exportData(_ store: SwiftDataJournalStore) throws -> Data {
        try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: store, favorites: nil, appVersion: "test", exportedAt: when))
    }

    func testRetentionPrunesAcknowledgedOutboxRowsOlderThanThirtyDays() throws {
        let store = try makeStore(try makeDirectory())
        let old = try queueIntake(store, id: newID())
        let exactlyThirty = try queueIntake(store, id: newID())
        let within = try queueIntake(store, id: newID())
        XCTAssertEqual(old.count, 2, "one row per enabled destination")
        try acknowledge(store, old, daysBefore: 31)
        try acknowledge(store, exactlyThirty, daysBefore: 30)
        try acknowledge(store, within, daysBefore: 29)

        XCTAssertEqual(
            try store.pruneAcknowledgedOutbox(now: when), old.count,
            "only the rows acknowledged strictly more than 30 days before now are pruned")

        for operationID in old {
            XCTAssertThrowsError(try store.acknowledge(operationID: operationID, at: when)) {
                XCTAssertEqual($0 as? JournalError, .unknownOperation(operationID))
            }
        }
        for operationID in exactlyThirty + within {
            XCTAssertNoThrow(try store.acknowledge(operationID: operationID, at: when),
                             "a row acknowledged 30 days or less before now is kept")
        }
    }

    func testRetentionNeverPrunesUnacknowledgedRows() throws {
        let store = try makeStore(try makeDirectory())
        let queued = try queueIntake(store, id: newID())
        let suspendedIntake = try queueIntake(store, id: newID())
        let suspended = try XCTUnwrap(suspendedIntake.first)
        try store.recordFailure(operationID: suspended, retryAt: nil, needsAttention: true, reason: "test reason")

        let outboxBefore = try store.pendingOutbox()
        let suspendedBefore = try store.suspendedOperationIDs()
        XCTAssertTrue(suspendedBefore.contains(suspended))

        let now = when.addingTimeInterval(90 * day)
        XCTAssertEqual(try store.pruneAcknowledgedOutbox(now: now), 0)

        XCTAssertEqual(try store.pendingOutbox(), outboxBefore)
        XCTAssertEqual(try store.suspendedOperationIDs(), suspendedBefore)
        XCTAssertEqual(Set(try store.pendingOutbox().map(\.operationID)), Set(queued + suspendedIntake))
    }

    func testRetentionLeavesTombstonesRevisionsAndSnapshotsAlone() throws {
        let store = try makeStore(try makeDirectory())
        let keptID = newID()
        let deletedID = newID()
        let keptOps = try queueIntake(store, id: keptID)
        try store.edit(
            intakeID: keptID, components: [oats(55)], product: product("snap-2", name: "Oats new"),
            changeReason: "bigger bowl", now: when)
        let deletedOps = try queueIntake(store, id: deletedID)
        try store.delete(intakeID: deletedID, now: when)
        try acknowledge(store, keptOps + deletedOps, daysBefore: 31)

        let activeBefore = try store.activeIntakes().map(\.id)
        let deletedBefore = try store.deletedIntakes().map(\.id)
        let keptRevisionsBefore = try store.revisions(of: keptID).count
        let deletedRevisionsBefore = try store.revisions(of: deletedID).count
        let projectionsBefore = try store.projections(of: keptID).count + store.projections(of: deletedID).count

        XCTAssertGreaterThan(try store.pruneAcknowledgedOutbox(now: when), 0)

        XCTAssertEqual(try store.activeIntakes().map(\.id), activeBefore)
        XCTAssertEqual(try store.deletedIntakes().map(\.id), deletedBefore)
        XCTAssertEqual(try store.revisions(of: keptID).count, keptRevisionsBefore)
        XCTAssertEqual(try store.revisions(of: deletedID).count, deletedRevisionsBefore)
        XCTAssertEqual(
            try store.projections(of: keptID).count + store.projections(of: deletedID).count, projectionsBefore)
        XCTAssertNotNil(try store.product(snapshotID: "snap-2"))
    }

    func testRetentionPassIsRepeatable() throws {
        let store = try makeStore(try makeDirectory())
        let ops = try queueIntake(store, id: newID())
        try acknowledge(store, ops, daysBefore: 31)

        XCTAssertEqual(try store.pruneAcknowledgedOutbox(now: when), ops.count)
        XCTAssertEqual(try store.pruneAcknowledgedOutbox(now: when), 0, "a second pass with the same now finds nothing")
    }

    func testRetentionLeavesTheExportUnchanged() throws {
        let store = try makeStore(try makeDirectory())
        let keptID = newID()
        let deletedID = newID()
        let keptOps = try queueIntake(store, id: keptID)
        try store.edit(
            intakeID: keptID, components: [oats(55)], product: product("snap-2", name: "Oats new"),
            changeReason: "bigger bowl", now: when)
        let deletedOps = try queueIntake(store, id: deletedID)
        try store.delete(intakeID: deletedID, now: when)
        try acknowledge(store, keptOps + deletedOps, daysBefore: 31)

        let before = try exportData(store)
        XCTAssertGreaterThan(try store.pruneAcknowledgedOutbox(now: when), 0)
        XCTAssertEqual(try exportData(store), before)
    }
}
