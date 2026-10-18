import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Undo of a delete: a delete waits out its window before it is offered to any destination, and Undo inside
/// the window withdraws it without Health or the relay ever seeing it.
final class JournalDeleteUndoTests: XCTestCase {
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a11"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(
            url: directory.appendingPathComponent("journal.store"), enabledDestinations: [.healthKit, .relay])
    }

    private func oats() -> IntakeComponent {
        IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 40, unit: .g)
    }

    private func createIntake(_ store: SwiftDataJournalStore) throws {
        try store.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [oats()], product: nil, now: when)
    }

    private func pendingDeletes(_ store: SwiftDataJournalStore) throws -> [OutboxOperation] {
        try store.pendingOutbox().filter { $0.kind == .delete }
    }

    func testUndoInsideWindowRestoresEntryAndLeavesNoDeleteOperation() throws {
        let store = try makeStore()
        try createIntake(store)
        let deletedAt = Date()
        try store.delete(intakeID: intakeID, now: deletedAt)
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertEqual(try store.pendingDeleteRowCountForTesting(intakeID: intakeID), 2)

        try store.undoDelete(intakeID: intakeID)

        XCTAssertEqual(try store.activeIntakes().map(\.id), [intakeID])
        // The raw rows, not pendingOutbox: a held delete is hidden from pendingOutbox even when it is not withdrawn.
        XCTAssertEqual(try store.pendingDeleteRowCountForTesting(intakeID: intakeID), 0)
        XCTAssertTrue(try store.pendingOutbox().allSatisfy { $0.kind == .upsert })
        let current = try store.projections(of: intakeID).filter(\.isCurrent)
        XCTAssertFalse(current.isEmpty)
        XCTAssertTrue(current.allSatisfy { $0.desiredAction == .upsert })
    }

    func testFailedDeleteLeavesNoGapInTheCommitSequence() throws {
        let store = try makeStore()
        try createIntake(store)
        let other = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a12"
        try store.create(
            Intake(id: other, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "lunch"),
            components: [oats()], product: nil, now: when)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.deleteSequenced(intakeID: intakeID, now: Date()))
        let first = try store.deleteSequenced(intakeID: other, now: Date())
        XCTAssertEqual(first, 1)
        XCTAssertEqual(store.deleteSequence, 1)
    }

    func testNoDeleteIsOfferedBeforeWindowEnds() throws {
        let store = try makeStore()
        try createIntake(store)
        try store.delete(intakeID: intakeID, now: Date())
        XCTAssertTrue(try pendingDeletes(store).isEmpty)
    }

    func testDeleteIsOfferedAfterWindowAndUndoIsRefused() throws {
        let store = try makeStore()
        try createIntake(store)
        let deletedAt = Date().addingTimeInterval(-11)
        try store.delete(intakeID: intakeID, now: deletedAt)
        XCTAssertEqual(Set(try pendingDeletes(store).map(\.destination)), [.healthKit, .relay])
        XCTAssertThrowsError(try store.undoDelete(intakeID: intakeID)) {
            XCTAssertEqual($0 as? JournalError, .undoUnavailable(self.intakeID))
        }
        XCTAssertTrue(try store.activeIntakes().isEmpty)
    }

    func testUndoRefusedOnceADeleteIsAcknowledged() throws {
        let store = try makeStore()
        try createIntake(store)
        let deletedAt = Date().addingTimeInterval(-11)
        try store.delete(intakeID: intakeID, now: deletedAt)
        for operation in try pendingDeletes(store) {
            try store.acknowledge(operationID: operation.operationID, at: Date())
        }
        XCTAssertThrowsError(try store.undoDelete(intakeID: intakeID)) {
            XCTAssertEqual($0 as? JournalError, .undoUnavailable(self.intakeID))
        }
    }

    func testDeleteMadeWhileOpenIsDeliveredOnceWindowEnds() async throws {
        let store = try makeStore()
        try createIntake(store)
        try store.delete(intakeID: intakeID, now: Date())
        XCTAssertTrue(try pendingDeletes(store).isEmpty)
        try await Task.sleep(for: .seconds(JournalUndo.deleteWindow + 0.5))
        XCTAssertEqual(Set(try pendingDeletes(store).map(\.destination)), [.healthKit, .relay])
    }

    func testHeldDeleteStillDeliversAfterRestartOnceWindowHasPassed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.store")
        let first = try SwiftDataJournalStore(url: url, enabledDestinations: [.healthKit, .relay])
        try createIntake(first)
        try first.delete(intakeID: intakeID, now: Date().addingTimeInterval(-11))
        first.close()

        let reopened = try SwiftDataJournalStore(url: url, enabledDestinations: [.healthKit, .relay])
        XCTAssertEqual(try pendingDeletes(reopened).count, 2)
    }
}
