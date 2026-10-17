import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Undoing a restore must not remove a product row that an entry logged after the restore still uses.
final class UndoRestoreSharedProductTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)
    private let snapshotID = "restored-snapshot"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func product() -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshotID, productID: "restored-product", name: "Synthetic bar", brand: nil, barcode: nil,
            labelBasis: "per serving", catalogOrigin: "synthetic", catalogVersion: "1", kind: .food,
            nutrients: [:], nutrientDisplayNames: [:])
    }

    private func restoredEntry(id: String) -> JournalRestoreEntry {
        JournalRestoreEntry(
            intake: Intake(
                id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast",
                lifecycle: .active, currentRevision: 1),
            revisions: [
                IntakeRevision(
                    intakeID: id, number: 1,
                    components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 1, unit: .g)],
                    productSnapshotID: snapshotID, changeReason: "created", createdAt: when)
            ])
    }

    func testUndoKeepsAProductRowAnotherEntryStillUses() throws {
        let path = try directory().appendingPathComponent("shared.store")
        let store = try SwiftDataJournalStore(url: path)
        let restoredID = "00000000-0000-4000-8000-0000000000b1"
        let laterID = "00000000-0000-4000-8000-0000000000b2"
        let receipt = try store.restore(
            JournalRestorePlan(
                entries: [restoredEntry(id: restoredID)], tombstones: [], products: [product()], favorites: []))
        XCTAssertEqual(receipt.insertedProductSnapshotIDs, [snapshotID])

        // An entry logged after the restore reuses the restored snapshot, as a repeat of it does.
        try store.create(
            Intake(id: laterID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "dinner"),
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 1, unit: .g)],
            product: product(), now: when)

        try store.undoRestore(receipt)

        XCTAssertNotNil(try store.product(snapshotID: snapshotID))
        XCTAssertEqual(try store.revisions(of: laterID).last?.productSnapshotID, snapshotID)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [laterID])
    }

    func testUndoStillRemovesAProductRowNothingElseUses() throws {
        let path = try directory().appendingPathComponent("unused.store")
        let store = try SwiftDataJournalStore(url: path)
        let receipt = try store.restore(
            JournalRestorePlan(
                entries: [restoredEntry(id: "00000000-0000-4000-8000-0000000000b3")], tombstones: [],
                products: [product()], favorites: []))
        try store.undoRestore(receipt)
        XCTAssertNil(try store.product(snapshotID: snapshotID))
    }
}
