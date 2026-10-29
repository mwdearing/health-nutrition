import Foundation
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

/// #775: a failed product-operation read must never present as a guess; sharing pauses instead.
final class ProductShareReadFailureTests: XCTestCase {
    @MainActor func testFailedReadPausesCoordinatorStatusAndSetsTheReadFlag() {
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

    /// #775: a read-failure pause raised during a send stops the next send. The read is failed only for the
    /// duration of the raise, so the loop's own next read works and only the pause can stop it.
    @MainActor func testPauseRaisedMidRunStopsTheNextSend() async {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort()
        let service = PauseDuringFirstPublishService(store: store, owner: owner)
        var first = ProductShareOperation(ownerID: owner, localProductID: UUID(), operationID: UUID(), clientRevisionID: UUID(),
            kind: .publish, content: CustomProductContent(name: "Synthetic first", kind: .food, basis: .per100g), consentGeneration: "1", epoch: epoch)
        first.storeEpoch = UUID()
        var second = ProductShareOperation(ownerID: owner, localProductID: UUID(), operationID: UUID(), clientRevisionID: UUID(),
            kind: .publish, content: CustomProductContent(name: "Synthetic second", kind: .food, basis: .per100g), consentGeneration: "1", epoch: epoch)
        second.storeEpoch = UUID()
        store.operations = [first, second]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        await service.attach(coordinator)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))

        await coordinator.runDueOperations(now: Date())

        let publishCalls = await service.publishCalls
        XCTAssertEqual(publishCalls, 1, "the pause raised during the first publish stops the second send")
        XCTAssertEqual(store.operations[0].status, .acknowledged, "the send under way still records its reply")
        XCTAssertEqual(store.operations[1].status, .pending)
        XCTAssertTrue(coordinator.operationsReadFailed)
    }

    /// The status is worked out from one read: a read that fails and then works within the same status call
    /// still reads as paused, not as a status guessed from the later read (a product with unshared local
    /// changes must never read as shared).
    @MainActor func testOneFailedReadInAStatusCallIsPausedEvenIfTheNextReadWorks() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic read", kind: .food, basis: .perServing))
        store.products = [item]
        store.operations = [ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(),
            clientRevisionID: UUID(), kind: .publish, content: item.content, epoch: epoch)]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        XCTAssertEqual(model.status(item), .localChanges)

        store.failOnlyReadCall = store.readCalls + 1
        XCTAssertEqual(model.status(item), .paused)
    }

    /// Retry is worked out from one read: a review blocker is never missed because a later read failed.
    @MainActor func testRetryIsDecidedFromOneReadSoABlockerIsNotMissed() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic read", kind: .food, basis: .perServing))
        store.products = [item]
        var blocked = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(),
            clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)
        blocked.status = .needsReview
        store.operations = [blocked, ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(),
            clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        // Retry reads once; a failure on a later read can't hide the blocker it already saw.
        store.failOnlyReadCall = store.readCalls + 3
        XCTAssertFalse(model.canRetry(item))
    }

    /// A pause raised by one failed read and lifted by the next refreshes the view, even though the operations
    /// didn't change, so "Sharing paused" doesn't linger.
    @MainActor func testARefreshAfterTheReadRecoversRedrawsEvenWithTheSameOperations() {
        let owner = UUID(), epoch = UUID(), store = FailableReadStorePort(), service = ProductSearchServicePort()
        let item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic read", kind: .food, basis: .perServing))
        store.products = [item]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        _ = model.refreshFromStore()

        store.failReads = true
        XCTAssertEqual(model.status(item), .paused)
        store.failReads = false
        XCTAssertTrue(model.refreshFromStore(), "the lifted pause redraws the view")
        XCTAssertNotEqual(model.status(item), .paused)
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
    /// Only this call to productOperations (counted from 1) throws, when set.
    var failOnlyReadCall: Int?
    private(set) var readCalls = 0
    func productOperations(ownerID: UUID) throws -> [ProductShareOperation] {
        readCalls += 1
        if failReads || failOnlyReadCall == readCalls { throw CustomProductStoreError.invalidOperation }
        return operations.filter { $0.ownerID == ownerID }
    }
    func dueProductOperations(ownerID: UUID, now: Date) throws -> [ProductShareOperation] {
        try productOperations(ownerID: ownerID).filter { $0.status == .pending && $0.predecessorOperationID == nil && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now) }
    }
    // The methods below are unused by these tests; they satisfy the protocol.
    func recordProductDelivery(_ update: ProductDeliveryUpdate) throws {
        guard let index = operations.firstIndex(where: { $0.operationID == update.operationID && $0.ownerID == update.ownerID && $0.epoch == update.epoch && $0.storeEpoch == update.storeEpoch }),
              [.pending, .sending].contains(operations[index].status) else { throw CustomProductStoreError.obsoleteOperation }
        if update.status == .sending {
            operations[index].envelope = update.envelope; operations[index].attempts += 1
        }
        operations[index].status = update.status; operations[index].nextAttemptAt = update.nextAttemptAt
        operations[index].reason = update.reason; operations[index].currentState = update.currentState
        operations[index].currentRevision = update.currentRevision
    }
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

/// Counts publish calls. During the first publish it raises the read-failure pause, then lets reads work again.
private actor PauseDuringFirstPublishService: CommunityProductServicing {
    private let store: FailableReadStorePort
    private let owner: UUID
    private var coordinator: ProductShareCoordinator?
    private(set) var publishCalls = 0
    init(store: FailableReadStorePort, owner: UUID) { self.store = store; self.owner = owner }
    func attach(_ coordinator: ProductShareCoordinator) { self.coordinator = coordinator }
    func publish(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt {
        publishCalls += 1
        guard let operationID = UUID(uuidString: request.operationID) else { throw ProductAPIError.invalidRequest(field: nil) }
        if publishCalls == 1 {
            let store = self.store, owner = self.owner, coordinator = self.coordinator
            await MainActor.run {
                store.failReads = true
                _ = coordinator?.operations(ownerID: owner)
                store.failReads = false
            }
        }
        return ProductDeliveryReceipt(operationID: operationID, productID: UUID(),
            acknowledgedRevision: "1", currentRevision: "1", currentState: .active, replayed: false)
    }
    func resolvePublishForWithdrawal(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductPublishResolution { throw ProductAPIError.unavailable }
    func withdraw(_ request: ProductWithdrawRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt { throw ProductAPIError.unavailable }
    func searchProducts(query: String, kind: ProductKind?, cursor: String?) async throws -> CommunityProductPage { throw ProductAPIError.unavailable }
    func product(id: UUID) async throws -> CommunityProduct { throw ProductAPIError.unavailable }
    func capabilities() async throws -> ProductCatalogCapabilities {
        ProductCatalogCapabilities(supportedVersion: 2, enabled: true,
            limits: ProductCatalogLimits(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20), currentConsentVersion: 2,
            callerAcknowledgment: ProductConsentAcknowledgment(version: 2, generation: "1"), consentGeneration: "1",
            sharingPermission: true, publishResolutionVersion: 1, boundedPublicationVersion: 1)
    }
    func acknowledgeConsent(version: Int, expectedOwnerID: UUID) async throws -> ProductConsentState { throw ProductAPIError.unavailable }
    func contribution(productID: UUID, expectedOwnerID: UUID) async throws -> ProductContributionState { throw ProductAPIError.unavailable }
}
