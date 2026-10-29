import Foundation
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

/// #775: a failed product-operation read must never present as a guess; sharing pauses instead.
final class ProductShareReadFailureTests: XCTestCase {
    @MainActor func testFailedReadPausesCoordinatorStatusAndSetsStorageFailed() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic read", kind: .food, basis: .perServing))
        store.operations = [ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(),
            clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))

        store.failReads = true
        XCTAssertEqual(coordinator.status(localProductID: item.localProductID), .paused)
        XCTAssertTrue(coordinator.operationsReadFailed)
        XCTAssertTrue(coordinator.sharingBlocked)
        XCTAssertNil(coordinator.operations(ownerID: owner))
    }

    @MainActor func testWorkingReadKeepsOnThisPhoneWithoutOperation() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let localProductID = UUID()
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))

        XCTAssertEqual(coordinator.status(localProductID: localProductID), .onThisPhone)
        XCTAssertFalse(coordinator.sharingBlocked)
        XCTAssertEqual(coordinator.operations(ownerID: owner)?.count, 0)
    }

    @MainActor func testFailedReadShowsSharingPausedAndBlocksShareRetryAndWithdraw() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic read", kind: .food, basis: .perServing))
        store.products = [item]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)

        store.failReads = true
        XCTAssertEqual(model.status(item), .paused)
        XCTAssertFalse(model.canShare)
        XCTAssertFalse(model.canRetry(item))
        XCTAssertFalse(model.canWithdraw(item))
    }

    /// A read that works again lifts the pause, so one transient error doesn't stop sharing for the session.
    @MainActor func testAReadThatWorksAgainLiftsThePause() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic read", kind: .food, basis: .perServing))
        store.operations = [ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(),
            clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))

        store.failReads = true
        XCTAssertEqual(coordinator.status(localProductID: item.localProductID), .paused)
        store.failReads = false
        XCTAssertNotEqual(coordinator.status(localProductID: item.localProductID), .paused)
        XCTAssertFalse(coordinator.sharingBlocked)
    }

    /// While the pause holds, a withdrawal is refused even though the operation in hand looks valid.
    @MainActor func testAWithdrawalIsRefusedWhileTheReadFailed() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic read", kind: .food, basis: .perServing))
        let operation = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(),
            clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)
        store.operations = [operation]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))

        store.failReads = true
        XCTAssertNil(coordinator.operations(ownerID: owner))
        XCTAssertThrowsError(try coordinator.requestWithdrawal(operation, expectedStoreEpoch: epoch))
        XCTAssertEqual(store.withdrawalCalls, 0, "refused before the store is asked to withdraw")
    }

    /// Delivery retries the read itself, so a pause from a failed read lifts without a screen reading first.
    @MainActor func testDeliveryRetriesTheReadAndLiftsThePause() async {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        store.failReads = true
        XCTAssertNil(coordinator.operations(ownerID: owner))
        XCTAssertTrue(coordinator.sharingBlocked)
        store.failReads = false
        await coordinator.runDueOperations(now: Date())
        XCTAssertFalse(coordinator.sharingBlocked)
    }
}

// A store double whose operation reads can be made to throw. Establishes no persistence guarantees.
private final class FailableReadStorePort: CustomProductStore, @unchecked Sendable {
    var products: [CustomProductRevision] = []
    var operations: [ProductShareOperation] = []
    var failReads = false
    func saveCustomProduct(_ command: CustomProductSave, now: Date) throws -> CustomProductRevision { command.revision }
    func enqueueProductOperation(_ operation: ProductShareOperation) throws { operations.append(operation) }
    func customProducts() throws -> [CustomProductRevision] { products }
    func productAccountEpoch(ownerID: UUID) throws -> UUID? { operations.last(where: { $0.ownerID == ownerID })?.epoch }
    func productOperations(ownerID: UUID) throws -> [ProductShareOperation] {
        if failReads { throw CustomProductStoreError.invalidOperation }
        return operations.filter { $0.ownerID == ownerID }
    }
    func dueProductOperations(ownerID: UUID, now: Date) throws -> [ProductShareOperation] {
        try productOperations(ownerID: ownerID).filter { $0.status == .pending && $0.predecessorOperationID == nil && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now) }
    }
    // The methods below are unused by these tests; they satisfy the protocol.
    func recordProductDelivery(_ update: ProductDeliveryUpdate) throws { throw CustomProductStoreError.invalidOperation }
    func pauseProductOperations(ownerID: UUID) throws {}
    func resumeProductOperations(ownerID: UUID, fromEpoch: UUID, toEpoch: UUID) throws {}
    func cancelProductPublications(ownerID: UUID) throws {}
    func removeProductAccountState(ownerID: UUID) throws {}
    private(set) var withdrawalCalls = 0
    func enqueueProductWithdrawal(_ operation: ProductShareOperation, expectedStoreEpoch: UUID) throws -> ProductShareOperation {
        withdrawalCalls += 1
        throw CustomProductStoreError.invalidOperation
    }
    func recordProductWithdrawalPreparation(_ update: ProductWithdrawalPreparationUpdate) throws -> ProductShareOperation { throw CustomProductStoreError.invalidOperation }
}
