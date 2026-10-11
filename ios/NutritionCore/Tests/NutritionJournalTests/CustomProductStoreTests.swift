import Foundation
import SwiftData
import XCTest
import NutritionDomain
@testable import NutritionJournal

final class CustomProductStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let owner = UUID()
    private let epoch = UUID()
    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("synthetic.store")
    }
    private func revision(product: UUID = UUID(), name: String = "Synthetic") -> CustomProductRevision {
        CustomProductRevision(localProductID: product, revisionID: UUID(), content: CustomProductContent(name: name, kind: .food, basis: .per100g))
    }
    private func operation(_ revision: CustomProductRevision) -> ProductShareOperation {
        ProductShareOperation(ownerID: owner, localProductID: revision.localProductID, operationID: UUID(), clientRevisionID: revision.revisionID,
            kind: .publish, content: revision.content, consentVersion: 2, consentGeneration: "1", epoch: epoch)
    }
    private func draft(_ revision: CustomProductRevision) -> ProductIntakeDraft {
        ProductIntakeDraft(intake: Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "portion", name: "Portion", amount: 40, unit: .g)],
            snapshot: ProductDefinition(snapshotID: revision.revisionID.uuidString, productID: revision.localProductID.uuidString,
                name: revision.content.name, labelBasis: "per 100 g", catalogOrigin: "custom", catalogVersion: revision.revisionID.uuidString))
    }
    func testRollbackWritesNothingAndReopenRetainsWholeCommittedTransaction() throws {
        let path = try url(), revision = revision()
        let store = try SwiftDataJournalStore(url: path)
        let command = CustomProductSave(revision: revision, intake: draft(revision), publication: operation(revision))
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.saveCustomProduct(command, now: now))
        XCTAssertEqual(try store.customProducts().count, 0)
        XCTAssertEqual(try store.activeIntakes().count, 0)
        XCTAssertEqual(try store.dueProductOperations(ownerID: owner, now: now).count, 0)
        XCTAssertEqual(try store.pendingOutbox().count, 0)
        try store.saveCustomProduct(command, now: now)
        store.close()
        let reopened = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try reopened.customProducts(), [revision])
        XCTAssertEqual(try reopened.activeIntakes().count, 1)
        XCTAssertEqual(try reopened.dueProductOperations(ownerID: owner, now: now).count, 1)
    }
    func testEditsKeepOldSnapshotsAndProductsOutliveDeletedIntakes() throws {
        let store = try SwiftDataJournalStore(url: url())
        let first = revision(), intake = draft(first)
        try store.saveCustomProduct(CustomProductSave(revision: first, intake: intake), now: now)
        let before = try store.product(snapshotID: first.revisionID.uuidString)
        let second = revision(product: first.localProductID, name: "Edited")
        try store.saveCustomProduct(CustomProductSave(revision: second, expectedLocalRevision: first.revisionID), now: now)
        XCTAssertEqual(try store.product(snapshotID: first.revisionID.uuidString), before)
        XCTAssertThrowsError(try store.saveCustomProduct(CustomProductSave(revision: revision(product: first.localProductID), expectedLocalRevision: first.revisionID), now: now))
        try store.delete(intakeID: intake.intake.id, now: now)
        XCTAssertEqual(try store.customProducts(), [second])
    }
    func testAttemptedPredecessorResolvesSuccessorAndReopenKeepsExactEnvelope() throws {
        let path = try url(), first = revision()
        let store = try SwiftDataJournalStore(url: path)
        let op = operation(first)
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: op), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        let bytes = Data("{\"client_revision_id\":\"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA\",\"amount\":\"1.000000\"}".utf8)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation,
            status: .sending, envelope: bytes))
        let second = revision(product: first.localProductID)
        try store.saveCustomProduct(CustomProductSave(revision: second, expectedLocalRevision: first.revisionID, publication: operation(second)), now: now)
        XCTAssertTrue(try store.dueProductOperations(ownerID: owner, now: now).isEmpty)
        store.close()
        let reopened = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try reopened.dueProductOperations(ownerID: owner, now: now).first?.envelope, bytes)
        XCTAssertThrowsError(try reopened.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("changed".utf8))))
        let server = UUID().uuidString.lowercased()
        try reopened.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation,
            status: .acknowledged, serverProductID: server, acknowledgedRevision: "1", currentRevision: "1", currentState: .active))
        let due = try XCTUnwrap(try reopened.dueProductOperations(ownerID: owner, now: now).first)
        XCTAssertEqual(due.clientRevisionID, second.revisionID)
        XCTAssertEqual(due.serverProductID, server)
        XCTAssertEqual(due.expectedServerRevision, "1")
    }
    func testCancellationRetainsAttemptedEnvelopeAndEraseRejectsStaleCallback() throws {
        let store = try SwiftDataJournalStore(url: url()), revision = revision()
        let op = operation(revision)
        try store.saveCustomProduct(CustomProductSave(revision: revision, publication: op), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        let bytes = Data("immutable".utf8)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: bytes))
        try store.cancelProductPublications(ownerID: owner)
        XCTAssertEqual(try store.productOperations(ownerID: owner).first?.envelope, bytes)
        XCTAssertTrue(try store.dueProductOperations(ownerID: owner, now: now).isEmpty)
        try store.eraseAll()
        XCTAssertThrowsError(try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .acknowledged, serverProductID: UUID().uuidString, acknowledgedRevision: "1", currentRevision: "1", currentState: .active)))
        XCTAssertTrue(try store.customProducts().isEmpty)
        XCTAssertTrue(try store.productOperations(ownerID: owner).isEmpty)
    }
    func testNeverAttemptedEditsCoalesceWithoutInventingDependency() throws {
        let store = try SwiftDataJournalStore(url: url()), first = revision()
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: operation(first)), now: now)
        let second = revision(product: first.localProductID)
        try store.saveCustomProduct(CustomProductSave(revision: second, expectedLocalRevision: first.revisionID, publication: operation(second)), now: now)
        let due = try store.dueProductOperations(ownerID: owner, now: now)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.clientRevisionID, second.revisionID)
        XCTAssertNil(due.first?.predecessorOperationID)
    }
    func testConcurrentEditsHaveExactlyOneWinner() throws {
        let store = try SwiftDataJournalStore(url: url()), first = revision()
        try store.saveCustomProduct(CustomProductSave(revision: first), now: now)
        let commands = [revision(product: first.localProductID, name: "One"), revision(product: first.localProductID, name: "Two")]
            .map { CustomProductSave(revision: $0, expectedLocalRevision: first.revisionID) }
        let results = ConcurrentProductResults(), date = now
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do { try store.saveCustomProduct(commands[index], now: date); results.record(success: true) }
            catch { results.record(success: false) }
        }
        XCTAssertEqual(results.successes, 1)
        XCTAssertEqual(results.failures, 1)
        XCTAssertEqual(try store.customProducts().count, 1)
    }

    func testResumeIsOwnerAndEpochScopedAndNeverRevivesCancelledWork() throws {
        let store = try SwiftDataJournalStore(url: url()), first = revision()
        let firstOperation = operation(first)
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: firstOperation), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        let bytes = Data("exact attempted body 0.000000".utf8)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: firstOperation.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: bytes))
        try store.pauseProductOperations(ownerID: owner)
        let newEpoch = UUID()
        XCTAssertThrowsError(try store.resumeProductOperations(ownerID: UUID(), fromEpoch: epoch, toEpoch: newEpoch))
        XCTAssertThrowsError(try store.resumeProductOperations(ownerID: owner, fromEpoch: UUID(), toEpoch: newEpoch))
        try store.resumeProductOperations(ownerID: owner, fromEpoch: epoch, toEpoch: newEpoch)
        let resumed = try XCTUnwrap(try store.dueProductOperations(ownerID: owner, now: now).first)
        XCTAssertEqual(resumed.envelope, bytes)
        XCTAssertEqual(resumed.storeEpoch, generation)
        XCTAssertEqual(resumed.epoch, newEpoch)
        XCTAssertThrowsError(try store.recordProductDelivery(ProductDeliveryUpdate(operationID: firstOperation.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .pending)))
        try store.cancelProductPublications(ownerID: owner)
        try store.pauseProductOperations(ownerID: owner)
        try store.resumeProductOperations(ownerID: owner, fromEpoch: newEpoch, toEpoch: UUID())
        XCTAssertTrue(try store.dueProductOperations(ownerID: owner, now: now).isEmpty)
        XCTAssertEqual(try store.productOperations(ownerID: owner).first?.envelope, bytes)
        try store.eraseAll()
        XCTAssertThrowsError(try store.resumeProductOperations(ownerID: owner, fromEpoch: newEpoch, toEpoch: UUID()))
    }

    func testWrongOwnerAndStoreEpochCannotPrepareOrAcknowledge() throws {
        let store = try SwiftDataJournalStore(url: url()), revision = revision()
        let op = operation(revision)
        try store.saveCustomProduct(CustomProductSave(revision: revision, publication: op), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        for (wrongOwner, wrongGeneration) in [(UUID(), generation), (owner, UUID())] {
            XCTAssertThrowsError(try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: wrongOwner, epoch: epoch, storeEpoch: wrongGeneration, status: .sending, envelope: Data("body".utf8))))
        }
        XCTAssertEqual(try store.productOperations(ownerID: owner).first?.attempts, 0)
        try store.removeProductAccountState(ownerID: owner)
        XCTAssertEqual(try store.customProducts(), [revision])
        XCTAssertTrue(try store.productOperations(ownerID: owner).isEmpty)
        XCTAssertThrowsError(try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .pending)))
    }

    func testNilBarcodeBindingIsImmutableAfterAttempt() throws {
        let store = try SwiftDataJournalStore(url: url()), first = revision()
        let op = operation(first)
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: op), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("body".utf8)))
        let changed = CustomProductRevision(localProductID: first.localProductID, revisionID: UUID(), content: CustomProductContent(name: "Changed", barcode: "0012345678905", kind: .food, basis: .per100g))
        XCTAssertThrowsError(try store.saveCustomProduct(CustomProductSave(revision: changed, expectedLocalRevision: first.revisionID), now: now))
        XCTAssertEqual(try store.customProducts(), [first])
    }

    func testReplayAheadOfAcknowledgmentRequiresReviewWithoutRebasingSuccessor() throws {
        let store = try SwiftDataJournalStore(url: url()), first = revision()
        let op = operation(first)
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: op), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("body".utf8)))
        let second = revision(product: first.localProductID)
        try store.saveCustomProduct(CustomProductSave(revision: second, expectedLocalRevision: first.revisionID, publication: operation(second)), now: now)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: op.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .acknowledged, serverProductID: UUID().uuidString, acknowledgedRevision: "1", currentRevision: "3", currentState: .withdrawn))
        XCTAssertTrue(try store.dueProductOperations(ownerID: owner, now: now).isEmpty)
        let successor = try XCTUnwrap(try store.productOperations(ownerID: owner).last)
        XCTAssertEqual(successor.status, .needsReview)
        XCTAssertEqual(successor.predecessorOperationID, op.operationID)
        XCTAssertNil(successor.expectedServerRevision)
    }

}

private final class ConcurrentProductResults: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (success: 0, failure: 0)
    func record(success: Bool) { lock.withLock { if success { counts.success += 1 } else { counts.failure += 1 } } }
    var successes: Int { lock.withLock { counts.success } }
    var failures: Int { lock.withLock { counts.failure } }
}
