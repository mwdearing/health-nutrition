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
    private func removal(_ revision: CustomProductRevision, epoch: UUID? = nil) -> ProductShareOperation {
        ProductShareOperation(ownerID: owner, localProductID: revision.localProductID, operationID: UUID(),
            clientRevisionID: revision.revisionID, kind: .withdraw, epoch: epoch ?? self.epoch)
    }
    func testWithdrawalPreparationReopensAndPreservesHistoricalCanceledEnvelope() throws {
        let path = try url(), revision = revision(), publication = operation(revision)
        var store = try SwiftDataJournalStore(url: path)
        try store.saveCustomProduct(CustomProductSave(revision: revision, publication: publication), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        let body = Data("synthetic immutable request".utf8)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner,
            epoch: epoch, storeEpoch: generation, status: .sending, envelope: body))
        let withdrawal = try store.enqueueProductWithdrawal(removal(revision), expectedStoreEpoch: generation)
        try store.pauseProductOperations(ownerID: owner)
        let resumedEpoch = UUID()
        try store.resumeProductOperations(ownerID: owner, fromEpoch: epoch, toEpoch: resumedEpoch)
        store.close(); store = try SwiftDataJournalStore(url: path)
        let server = UUID().uuidString
        func update(_ currentEpoch: UUID) -> ProductWithdrawalPreparationUpdate {
            ProductWithdrawalPreparationUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: currentEpoch,
                storeEpoch: generation, sourceOperationID: publication.operationID, sourceEpoch: epoch,
                event: .resolvedPublication(.committed(productID: server, acknowledgedRevision: "1", currentRevision: "1", currentState: .active)))
        }
        XCTAssertThrowsError(try store.recordProductWithdrawalPreparation(update(epoch)))
        let prepared = try store.recordProductWithdrawalPreparation(update(resumedEpoch))
        XCTAssertNil(prepared.predecessorOperationID)
        XCTAssertEqual(prepared.expectedServerRevision, "1")
        XCTAssertEqual(prepared.serverProductID, server)
        XCTAssertNil(prepared.acknowledgedRevision)
        XCTAssertEqual(try store.recordProductWithdrawalPreparation(update(resumedEpoch)), prepared)
        store.close(); store = try SwiftDataJournalStore(url: path)
        let source = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
        XCTAssertEqual(source.status, .cancelled)
        XCTAssertEqual(source.epoch, epoch)
        XCTAssertEqual(source.envelope, body)
        XCTAssertEqual(source.attempts, 1)
        XCTAssertEqual(source.publicationResolution, .committed)
        try store.eraseAll()
        XCTAssertThrowsError(try store.recordProductWithdrawalPreparation(update(resumedEpoch)))
        XCTAssertTrue(try store.productOperations(ownerID: owner).isEmpty)
    }
    func testWithdrawalCancellationIsAtomicAndNoCommitSatisfiesWithoutFakeReceipt() throws {
        let path = try url(), revision = revision(), publication = operation(revision)
        var store = try SwiftDataJournalStore(url: path)
        try store.saveCustomProduct(CustomProductSave(revision: revision, publication: publication), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        let intent = removal(revision)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.enqueueProductWithdrawal(intent, expectedStoreEpoch: generation))
        XCTAssertEqual(try store.productOperations(ownerID: owner).map(\.status), [.pending])
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner,
            epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("immutable".utf8)))
        let withdrawal = try store.enqueueProductWithdrawal(intent, expectedStoreEpoch: generation)
        let update = ProductWithdrawalPreparationUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, sourceOperationID: publication.operationID, sourceEpoch: epoch, event: .resolvedPublication(.canceledBeforeCommit))
        let result = try store.recordProductWithdrawalPreparation(update)
        XCTAssertEqual(result.status, .satisfied)
        XCTAssertEqual(result.currentState, ProductAccountState.none)
        XCTAssertNil(result.serverProductID)
        XCTAssertNil(result.acknowledgedRevision)
        store.close(); store = try SwiftDataJournalStore(url: path)
        try store.enqueueProductOperation(operation(revision))
        let due = try store.dueProductOperations(ownerID: owner, now: now)
        XCTAssertEqual(due.count, 1)
        XCTAssertNil(due.first?.predecessorOperationID)
        XCTAssertNotEqual(due.first?.operationID, publication.operationID)
    }
    func testPreparationBackoffPersistsSeparatelyFromTransportAttempts() throws {
        let path = try url(), revision = revision(), publication = operation(revision)
        var store = try SwiftDataJournalStore(url: path)
        try store.saveCustomProduct(CustomProductSave(revision: revision, publication: publication), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner,
            epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("immutable".utf8)))
        let withdrawal = try store.enqueueProductWithdrawal(removal(revision), expectedStoreEpoch: generation)
        func update(_ event: ProductWithdrawalPreparationEvent) -> ProductWithdrawalPreparationUpdate {
            ProductWithdrawalPreparationUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: epoch,
                storeEpoch: generation, sourceOperationID: publication.operationID, sourceEpoch: epoch, event: event)
        }
        _ = try store.recordProductWithdrawalPreparation(update(.beginAttempt))
        _ = try store.recordProductWithdrawalPreparation(update(.retry(reason: .network, nextAttemptAt: now.addingTimeInterval(10))))
        store.close(); store = try SwiftDataJournalStore(url: path)
        let saved = try XCTUnwrap(try store.productOperations(ownerID: owner).last)
        XCTAssertEqual(saved.preparationAttempts, 1)
        XCTAssertEqual(saved.attempts, 0)
        XCTAssertNil(saved.envelope)
        XCTAssertEqual(saved.nextAttemptAt, now.addingTimeInterval(10))
        XCTAssertTrue(try store.dueProductOperations(ownerID: owner, now: now.addingTimeInterval(20)).isEmpty)
    }
    func testCanceledUpdateRequiresOwnStateAndAllowsOnlyIntendedRejectedRevision() throws {
        for (state, revisionNumber, expectedStatus) in [
            (ProductAccountState.active, Optional("1"), ProductOperationStatus.pending),
            (.rejected, "1", .pending), (.rejected, "2", .needsReview), (.active, "2", .needsReview),
            (.none, nil, .satisfied), (.withdrawn, "2", .satisfied)
        ] {
            let path = try url(), first = revision(), initial = operation(first), server = UUID().uuidString
            var store = try SwiftDataJournalStore(url: path)
            try store.saveCustomProduct(CustomProductSave(revision: first, publication: initial), now: now)
            let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
            try store.recordProductDelivery(ProductDeliveryUpdate(operationID: initial.operationID, ownerID: owner, epoch: epoch,
                storeEpoch: generation, status: .sending, envelope: Data("first".utf8)))
            try store.recordProductDelivery(ProductDeliveryUpdate(operationID: initial.operationID, ownerID: owner, epoch: epoch,
                storeEpoch: generation, status: .acknowledged, serverProductID: server, acknowledgedRevision: "1", currentRevision: "1", currentState: .active))
            let edited = revision(product: first.localProductID, name: "Edited"), update = operation(edited)
            try store.saveCustomProduct(CustomProductSave(revision: edited, expectedLocalRevision: first.revisionID, publication: update), now: now)
            try store.recordProductDelivery(ProductDeliveryUpdate(operationID: update.operationID, ownerID: owner, epoch: epoch,
                storeEpoch: generation, status: .sending, envelope: Data("update".utf8)))
            let withdrawal = try store.enqueueProductWithdrawal(removal(edited), expectedStoreEpoch: generation)
            func event(_ value: ProductWithdrawalPreparationEvent) -> ProductWithdrawalPreparationUpdate {
                ProductWithdrawalPreparationUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation,
                    sourceOperationID: update.operationID, sourceEpoch: epoch, event: value)
            }
            let canceled = try store.recordProductWithdrawalPreparation(event(.resolvedPublication(.canceledBeforeCommit)))
            XCTAssertEqual(canceled.status, .pending)
            XCTAssertEqual(canceled.predecessorOperationID, update.operationID)
            store.close(); store = try SwiftDataJournalStore(url: path)
            let observed = try store.recordProductWithdrawalPreparation(event(.observedOwnContribution(productID: server, currentRevision: revisionNumber, currentState: state)))
            XCTAssertEqual(observed.status, expectedStatus)
            XCTAssertEqual(observed.currentState, state)
            XCTAssertEqual(observed.currentRevision, revisionNumber)
            XCTAssertNil(observed.acknowledgedRevision)
            let source = try XCTUnwrap(try store.productOperations(ownerID: owner).first(where: { $0.operationID == update.operationID }))
            XCTAssertEqual(source.expectedServerRevision, "1")
            XCTAssertEqual(source.envelope, Data("update".utf8))
            XCTAssertEqual(source.status, .cancelled)
        }
    }
    func testRemovalCancelsOnlyItsProductAndKeepsAttemptedAncestorBehindUnattemptedEdit() throws {
        let store = try SwiftDataJournalStore(url: url()), first = revision(), other = revision()
        let publication = operation(first), otherPublication = operation(other)
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: publication), now: now)
        try store.saveCustomProduct(CustomProductSave(revision: other, publication: otherPublication), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, status: .sending, envelope: Data("first".utf8)))
        let edit = revision(product: first.localProductID), successor = operation(edit)
        try store.saveCustomProduct(CustomProductSave(revision: edit, expectedLocalRevision: first.revisionID, publication: successor), now: now)
        let intent = removal(edit)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.enqueueProductWithdrawal(intent, expectedStoreEpoch: generation))
        XCTAssertEqual(try store.productOperations(ownerID: owner).map(\.status), [.sending, .pending, .pending])
        let withdrawal = try store.enqueueProductWithdrawal(intent, expectedStoreEpoch: generation)
        XCTAssertEqual(withdrawal.predecessorOperationID, publication.operationID)
        XCTAssertEqual(try store.enqueueProductWithdrawal(intent, expectedStoreEpoch: generation), withdrawal)
        XCTAssertThrowsError(try store.enqueueProductWithdrawal(removal(edit), expectedStoreEpoch: generation))
        XCTAssertEqual(try store.dueProductOperations(ownerID: owner, now: now).map(\.operationID), [otherPublication.operationID])
        XCTAssertEqual(try store.productOperations(ownerID: owner).first(where: { $0.operationID == successor.operationID })?.status, .cancelled)
    }
    func testContradictoryMalformedAndLatePreparationCannotChangePreparedWithdrawal() throws {
        let store = try SwiftDataJournalStore(url: url()), revision = revision(), server = UUID().uuidString
        let publication = operation(revision)
        try store.saveCustomProduct(CustomProductSave(revision: revision, publication: publication), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, status: .sending, envelope: Data("original".utf8)))
        let withdrawal = try store.enqueueProductWithdrawal(removal(revision), expectedStoreEpoch: generation)
        func event(_ facts: ProductPublicationResolutionFacts) -> ProductWithdrawalPreparationUpdate {
            ProductWithdrawalPreparationUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation,
                sourceOperationID: publication.operationID, sourceEpoch: epoch, event: .resolvedPublication(facts))
        }
        XCTAssertThrowsError(try store.recordProductWithdrawalPreparation(event(.committed(productID: server, acknowledgedRevision: "1", currentRevision: "invalid", currentState: .active))))
        let facts = ProductPublicationResolutionFacts.committed(productID: server, acknowledgedRevision: "1", currentRevision: "1", currentState: .active)
        let prepared = try store.recordProductWithdrawalPreparation(event(facts))
        XCTAssertThrowsError(try store.recordProductWithdrawalPreparation(event(.canceledBeforeCommit)))
        XCTAssertThrowsError(try store.recordProductWithdrawalPreparation(event(.committed(productID: UUID().uuidString, acknowledgedRevision: "1", currentRevision: "1", currentState: .active))))
        XCTAssertEqual(try store.productOperations(ownerID: owner).last, prepared)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, status: .sending, envelope: Data("withdraw".utf8)))
        _ = try store.recordProductWithdrawalPreparation(event(facts))
        XCTAssertEqual(try store.productOperations(ownerID: owner).last?.envelope, Data("withdraw".utf8))
        XCTAssertEqual(try store.productOperations(ownerID: owner).last?.status, .sending)
    }
    func testPermanentLocalRefusalNeverPretendsToSendOrAcceptsReceiptFields() throws {
        let store = try SwiftDataJournalStore(url: url()), revision = revision(), publication = operation(revision)
        try store.saveCustomProduct(CustomProductSave(revision: revision, publication: publication), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        XCTAssertThrowsError(try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner,
            epoch: epoch, storeEpoch: generation, status: .failed, serverProductID: UUID().uuidString, reason: .invalidInput)))
        XCTAssertThrowsError(try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner,
            epoch: epoch, storeEpoch: generation, status: .acknowledged, serverProductID: UUID().uuidString, acknowledgedRevision: "1", currentRevision: "1", currentState: .active)))
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner,
            epoch: epoch, storeEpoch: generation, status: .needsReview, reason: .consent))
        let saved = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
        XCTAssertEqual(saved.status, .needsReview)
        XCTAssertEqual(saved.attempts, 0)
        XCTAssertNil(saved.envelope)
        XCTAssertNil(saved.acknowledgedRevision)
        XCTAssertThrowsError(try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner,
            epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("bad revival".utf8))))
    }
    func testOldOperationPayloadDecodesWithoutPreparationFields() throws {
        let original = operation(revision())
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "publicationResolution"); json.removeValue(forKey: "preparationAttempts")
        let decoded = try JSONDecoder().decode(ProductShareOperation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.publicationResolution)
        XCTAssertNil(decoded.preparationAttempts)
        XCTAssertEqual(decoded, original)
    }
    func testMappingEpochSurvivesTerminalOnlyResumeAndReopen() throws {
        let path = try url(), first = revision(), publication = operation(first)
        var store = try SwiftDataJournalStore(url: path)
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: publication), now: now)
        try store.cancelProductPublications(ownerID: owner)
        let secondEpoch = UUID(), thirdEpoch = UUID()
        try store.resumeProductOperations(ownerID: owner, fromEpoch: epoch, toEpoch: secondEpoch)
        XCTAssertEqual(try store.productAccountEpoch(ownerID: owner), secondEpoch)
        XCTAssertEqual(try store.productOperations(ownerID: owner).first?.epoch, epoch)
        store.close(); store = try SwiftDataJournalStore(url: path)
        try store.resumeProductOperations(ownerID: owner, fromEpoch: XCTUnwrap(store.productAccountEpoch(ownerID: owner)), toEpoch: thirdEpoch)
        let next = ProductShareOperation(ownerID: owner, localProductID: first.localProductID, operationID: UUID(), clientRevisionID: first.revisionID,
            kind: .publish, content: first.content, consentGeneration: "2", epoch: thirdEpoch)
        try store.enqueueProductOperation(next)
        XCTAssertEqual(try store.dueProductOperations(ownerID: owner, now: now).map(\.operationID), [next.operationID])
        let different = revision()
        try store.saveCustomProduct(CustomProductSave(revision: different, publication: operation(different)), now: now)
        XCTAssertThrowsError(try store.productAccountEpoch(ownerID: owner))
    }
    func testOrdinaryReceiptNeverRewritesCanceledSuccessor() throws {
        let store = try SwiftDataJournalStore(url: url()), first = revision(), server = UUID().uuidString
        let publication = operation(first)
        try store.saveCustomProduct(CustomProductSave(revision: first, publication: publication), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, status: .sending, envelope: Data("first".utf8)))
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: publication.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, status: .acknowledged, serverProductID: server, acknowledgedRevision: "1", currentRevision: "1", currentState: .active))
        let withdrawal = try store.enqueueProductWithdrawal(removal(first), expectedStoreEpoch: generation)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, status: .sending, envelope: Data("withdraw".utf8)))
        let successor = operation(first)
        try store.enqueueProductOperation(successor)
        try store.cancelProductPublications(ownerID: owner)
        let before = try XCTUnwrap(try store.productOperations(ownerID: owner).last)
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: withdrawal.operationID, ownerID: owner, epoch: epoch,
            storeEpoch: generation, status: .acknowledged, serverProductID: server, acknowledgedRevision: "2", currentRevision: "3", currentState: .active))
        XCTAssertEqual(try store.productOperations(ownerID: owner).last, before)
        XCTAssertEqual(try store.productOperations(ownerID: owner).first(where: { $0.operationID == withdrawal.operationID })?.currentState, .active)
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

extension CustomProductStoreTests {
    func testExplicitReviewReopensPreservesFailedEnvelopeAndEnqueuesCurrentCASAtomically() throws {
        let path = try url(), item = revision(), remote = UUID().uuidString.lowercased()
        let first = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote, consentGeneration: "1", epoch: epoch)
        var store = try SwiftDataJournalStore(url: path)
        try store.saveCustomProduct(.init(revision: item, publication: first), now: now)
        let epochID = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        let body = Data("synthetic attempted envelope".utf8)
        try store.recordProductDelivery(.init(operationID: first.operationID, ownerID: owner, epoch: epoch, storeEpoch: epochID, status: .sending, envelope: body, serverProductID: remote))
        try store.recordProductDelivery(.init(operationID: first.operationID, ownerID: owner, epoch: epoch, storeEpoch: epochID, status: .needsReview, reason: .conflict))
        let blocker = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
        let review = ProductContributionReview(ownerID: owner, localProductID: item.localProductID, epoch: epoch, storeEpoch: epochID, blockingOperation: blocker, localRevisionID: item.revisionID, serverProductID: remote, currentRevision: "7", currentState: .active)
        let next = operation(item)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: next))
        XCTAssertEqual(try store.productOperations(ownerID: owner), [blocker])
        try store.reconcileProductContribution(review, publication: next)
        store.close(); store = try SwiftDataJournalStore(url: path)
        let rows = try store.productOperations(ownerID: owner)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].status, .needsReview); XCTAssertEqual(rows[0].reason, .conflict)
        XCTAssertEqual(rows[0].envelope, body); XCTAssertEqual(rows[0].attempts, 1)
        XCTAssertEqual(rows[0].expectedServerRevision, blocker.expectedServerRevision)
        XCTAssertEqual(rows[0].epoch, blocker.epoch)
        XCTAssertEqual(rows[0].reviewSettlementID, review.id)
        XCTAssertNil(rows[0].publicationResolution)
        XCTAssertNil(rows[1].predecessorOperationID)
        XCTAssertEqual(rows[1].expectedServerRevision, "7")
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: operation(item)))
        let removal = try store.enqueueProductWithdrawal(removal(item), expectedStoreEpoch: epochID)
        XCTAssertNil(removal.predecessorOperationID)
        XCTAssertEqual(removal.expectedServerRevision, "7")
    }
}

extension CustomProductStoreTests {
    private func reviewFixture() throws -> (SwiftDataJournalStore, CustomProductRevision, ProductShareOperation, ProductContributionReview) {
        let store = try SwiftDataJournalStore(url: url()), item = revision(), remote = UUID().uuidString.lowercased()
        let operation = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote, consentGeneration: "1", epoch: epoch)
        try store.saveCustomProduct(.init(revision: item, publication: operation), now: now)
        let stored = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
        try store.recordProductDelivery(.init(operationID: stored.operationID, ownerID: owner, epoch: epoch, storeEpoch: try XCTUnwrap(stored.storeEpoch), status: .needsReview, reason: .conflict))
        let blocked = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
        let review = ProductContributionReview(ownerID: owner, localProductID: item.localProductID, epoch: epoch, storeEpoch: try XCTUnwrap(blocked.storeEpoch), blockingOperation: blocked, localRevisionID: item.revisionID, serverProductID: remote, currentRevision: "7", currentState: .active)
        return (store, item, blocked, review)
    }
    func testExplicitReviewRejectsStaleOwnerEpochMappingProductAndLocalRevision() throws {
        for variant in 0..<6 {
            let (store, item, blocked, valid) = try reviewFixture()
            let invalid = ProductContributionReview(ownerID: variant == 0 ? UUID() : owner, localProductID: variant == 1 ? UUID() : item.localProductID, epoch: variant == 2 ? UUID() : epoch, storeEpoch: variant == 3 ? UUID() : valid.storeEpoch, blockingOperation: blocked, localRevisionID: variant == 4 ? UUID() : item.revisionID, serverProductID: variant == 5 ? UUID().uuidString : valid.serverProductID, currentRevision: "7", currentState: .active)
            XCTAssertThrowsError(try store.reconcileProductContribution(invalid, publication: operation(item)))
            XCTAssertEqual(try store.productOperations(ownerID: owner), [blocked])
        }
        let (store, item, blocked, review) = try reviewFixture()
        let edited = revision(product: item.localProductID, name: "Synthetic edited")
        try store.saveCustomProduct(.init(revision: edited, expectedLocalRevision: item.revisionID), now: now)
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: operation(item)))
        XCTAssertEqual(try store.productOperations(ownerID: owner), [blocked])
        try store.removeProductAccountState(ownerID: owner)
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: nil))
        XCTAssertTrue(try store.productOperations(ownerID: owner).isEmpty)
    }
    func testRejectedReviewCannotPublishButCanKeepThenWithdrawExactRevisionWithoutResolvingOldFailure() throws {
        let (store, item, blocked, valid) = try reviewFixture()
        let review = ProductContributionReview(ownerID: owner, localProductID: item.localProductID, epoch: epoch, storeEpoch: valid.storeEpoch, blockingOperation: blocked, localRevisionID: item.revisionID, serverProductID: valid.serverProductID, currentRevision: "7", currentState: .rejected)
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: operation(item)))
        try store.reconcileProductContribution(review, publication: nil)
        let withdrawal = try store.enqueueProductWithdrawal(removal(item), expectedStoreEpoch: review.storeEpoch)
        XCTAssertNil(withdrawal.predecessorOperationID)
        XCTAssertEqual(withdrawal.expectedServerRevision, "7")
        XCTAssertEqual(withdrawal.serverProductID, review.serverProductID)
        let historical = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
        XCTAssertEqual(historical.status, blocked.status); XCTAssertEqual(historical.reason, blocked.reason)
        XCTAssertEqual(historical.reviewedCurrentState, .rejected)
        XCTAssertNil(historical.publicationResolution)
    }
    func testExplicitReviewLeavesOtherProductSendingUntouched() throws {
        let (store, item, _, review) = try reviewFixture()
        let other = revision(), otherOperation = operation(other)
        try store.saveCustomProduct(.init(revision: other, publication: otherOperation), now: now)
        let queued = try XCTUnwrap(try store.productOperations(ownerID: owner).last)
        try store.recordProductDelivery(.init(operationID: queued.operationID, ownerID: owner, epoch: epoch, storeEpoch: try XCTUnwrap(queued.storeEpoch), status: .sending, envelope: Data("other synthetic request".utf8)))
        let before = try XCTUnwrap(try store.productOperations(ownerID: owner).last)
        try store.reconcileProductContribution(review, publication: operation(item))
        XCTAssertEqual(try store.productOperations(ownerID: owner).first { $0.operationID == before.operationID }, before)
    }
    func testExplicitReviewRefusesUnresolvedSendingAncestor() throws {
        let store = try SwiftDataJournalStore(url: url()), item = revision(), remote = UUID().uuidString.lowercased()
        let first = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote, consentGeneration: "1", epoch: epoch)
        try store.saveCustomProduct(.init(revision: item, publication: first), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(.init(operationID: first.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("unresolved request".utf8)))
        let second = operation(item); try store.enqueueProductOperation(second)
        try store.recordProductDelivery(.init(operationID: second.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .needsReview, reason: .conflict))
        let before = try store.productOperations(ownerID: owner), blocked = try XCTUnwrap(before.last)
        let review = ProductContributionReview(ownerID: owner, localProductID: item.localProductID, epoch: epoch, storeEpoch: generation, blockingOperation: blocked, localRevisionID: item.revisionID, serverProductID: remote, currentRevision: "7", currentState: .active, expectedOperationIDs: before.map(\.operationID))
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: operation(item)))
        XCTAssertEqual(try store.productOperations(ownerID: owner), before)
    }
}

extension CustomProductStoreTests {
    func testExplicitReviewDoesNotCancelANewerIntentCreatedAfterThePreview() throws {
        let (store, item, _, review) = try reviewFixture()
        try store.enqueueProductOperation(operation(item))
        let before = try store.productOperations(ownerID: owner)
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: operation(item)))
        XCTAssertEqual(try store.productOperations(ownerID: owner), before)
    }
}

extension CustomProductStoreTests {
    private func acknowledgedWithdrawalFixture() throws -> (SwiftDataJournalStore, URL, CustomProductRevision, [ProductShareOperation], ProductContributionReview) {
        let path = try url(), store = try SwiftDataJournalStore(url: path), item = revision(), remote = UUID().uuidString.lowercased()
        let first = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote, consentGeneration: "1", epoch: epoch)
        try store.saveCustomProduct(.init(revision: item, publication: first), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(.init(operationID: first.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("synthetic publication".utf8)))
        try store.recordProductDelivery(.init(operationID: first.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .acknowledged, serverProductID: remote, acknowledgedRevision: "1", currentRevision: "1", currentState: .active))
        let removal = try store.enqueueProductWithdrawal(removal(item), expectedStoreEpoch: generation)
        try store.recordProductDelivery(.init(operationID: removal.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("synthetic withdrawal".utf8)))
        try store.recordProductDelivery(.init(operationID: removal.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .acknowledged, serverProductID: remote, acknowledgedRevision: "2", currentRevision: "2", currentState: .withdrawn))
        let before = try store.productOperations(ownerID: owner), anchor = try XCTUnwrap(before.last)
        let review = ProductContributionReview(ownerID: owner, localProductID: item.localProductID, epoch: epoch, storeEpoch: generation, blockingOperation: anchor, localRevisionID: item.revisionID, serverProductID: remote, currentRevision: "3", currentState: .active, expectedOperationIDs: before.map(\.operationID))
        return (store, path, item, before, review)
    }
    func testAcknowledgedWithdrawalReviewRollsBackReopensAndPreservesOriginalReceipt() throws {
        var (store, path, item, before, review) = try acknowledgedWithdrawalFixture()
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: nil))
        XCTAssertEqual(try store.productOperations(ownerID: owner), before)
        try store.reconcileProductContribution(review, publication: nil)
        store.close(); store = try SwiftDataJournalStore(url: path)
        var expected = before
        expected[1].reviewSettlementID = review.id; expected[1].reviewedCurrentState = .active; expected[1].reviewedCurrentRevision = "3"
        XCTAssertEqual(try store.productOperations(ownerID: owner), expected, "All request and receipt fields remain unchanged")
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: operation(item)))
        let newer = ProductContributionReview(ownerID: owner, localProductID: item.localProductID, epoch: epoch, storeEpoch: review.storeEpoch, blockingOperation: expected[1], localRevisionID: item.revisionID, serverProductID: review.serverProductID, currentRevision: "4", currentState: .active, expectedOperationIDs: expected.map(\.operationID))
        try store.reconcileProductContribution(newer, publication: operation(item))
        let queued = try XCTUnwrap(try store.productOperations(ownerID: owner).last)
        XCTAssertEqual(queued.expectedServerRevision, "4"); XCTAssertNil(queued.predecessorOperationID)
        XCTAssertNil(queued.envelope); XCTAssertEqual(queued.attempts, 0)
        XCTAssertEqual(try store.productOperations(ownerID: owner)[1].acknowledgedRevision, "2")
    }
    func testAcknowledgedAuthorityReviewRejectsStaleIdentityLocalEditAndAccountRemoval() throws {
        let (store, _, item, before, review) = try acknowledgedWithdrawalFixture()
        for variant in 0..<6 {
            let invalid = ProductContributionReview(ownerID: variant == 0 ? UUID() : owner, localProductID: variant == 1 ? UUID() : item.localProductID, epoch: variant == 2 ? UUID() : epoch, storeEpoch: variant == 3 ? UUID() : review.storeEpoch, blockingOperation: review.blockingOperation, localRevisionID: variant == 4 ? UUID() : item.revisionID, serverProductID: variant == 5 ? UUID().uuidString : review.serverProductID, currentRevision: "3", currentState: .active, expectedOperationIDs: review.expectedOperationIDs)
            XCTAssertThrowsError(try store.reconcileProductContribution(invalid, publication: operation(item)))
            XCTAssertEqual(try store.productOperations(ownerID: owner), before)
        }
        try store.saveCustomProduct(.init(revision: revision(product: item.localProductID, name: "Synthetic newer"), expectedLocalRevision: item.revisionID), now: now)
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: nil))
        try store.removeProductAccountState(ownerID: owner)
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: nil))
    }
    func testPersistedConflictAncestorAndUnboundPendingDescendantReconcileAtomically() throws {
        let path = try url(), item = revision(), remote = UUID().uuidString.lowercased()
        var store = try SwiftDataJournalStore(url: path)
        let first = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote, consentGeneration: "1", epoch: epoch)
        try store.saveCustomProduct(.init(revision: item, publication: first), now: now)
        let generation = try XCTUnwrap(try store.productOperations(ownerID: owner).first?.storeEpoch)
        try store.recordProductDelivery(.init(operationID: first.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .sending, envelope: Data("synthetic immutable conflict".utf8)))
        try store.recordProductDelivery(.init(operationID: first.operationID, ownerID: owner, epoch: epoch, storeEpoch: generation, status: .needsReview, reason: .conflict))
        try store.enqueueProductOperation(operation(item))
        let before = try store.productOperations(ownerID: owner)
        XCTAssertEqual(before[1].predecessorOperationID, first.operationID)
        XCTAssertNil(before[1].serverProductID); XCTAssertNil(before[1].expectedServerRevision); XCTAssertNil(before[1].envelope)
        let review = ProductContributionReview(ownerID: owner, localProductID: item.localProductID, epoch: epoch, storeEpoch: generation, blockingOperation: before[0], localRevisionID: item.revisionID, serverProductID: remote, currentRevision: "3", currentState: .active, expectedOperationIDs: before.map(\.operationID))
        let next = operation(item)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: next))
        XCTAssertEqual(try store.productOperations(ownerID: owner), before)
        try store.reconcileProductContribution(review, publication: next)
        store.close(); store = try SwiftDataJournalStore(url: path)
        let after = try store.productOperations(ownerID: owner)
        var expected = before
        for index in expected.indices {
            expected[index].reviewSettlementID = review.id; expected[index].reviewedCurrentRevision = "3"; expected[index].reviewedCurrentState = .active
        }
        expected[1].status = .cancelled
        XCTAssertEqual(Array(after.prefix(2)), expected)
        XCTAssertEqual(after.last?.expectedServerRevision, "3"); XCTAssertNil(after.last?.predecessorOperationID)
        XCTAssertThrowsError(try store.reconcileProductContribution(review, publication: operation(item)))
    }
}
