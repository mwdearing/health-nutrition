import Foundation
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

final class ProductShareCoordinatorTests: XCTestCase {
    func testFullJitterAndBoundedRetryAfter() {
        XCTAssertEqual(ProductShareDeliveryWorker.retryDelay(attempt: 1, retryAfter: nil, jitter: { 1 }), 2)
        XCTAssertEqual(ProductShareDeliveryWorker.retryDelay(attempt: 2, retryAfter: nil, jitter: { 0.5 }), 2)
        XCTAssertEqual(ProductShareDeliveryWorker.retryDelay(attempt: 100, retryAfter: nil, jitter: { 1 }), 3600)
        XCTAssertEqual(ProductShareDeliveryWorker.retryDelay(attempt: 1, retryAfter: "999999999999999999999999999", jitter: { 0 }), 86400)
        XCTAssertGreaterThan(ProductShareDeliveryWorker.retryDelay(attempt: 1, retryAfter: "0", jitter: { 0 }), 0)
    }
}

// A bounded in-memory port for coordinator admission tests. Real reopen/rollback is tested separately
// in CustomProductStoreTests with SwiftData; this double establishes no persistence guarantees.
private final class DeliveryStorePort: CustomProductStore, @unchecked Sendable {
    var operations: [ProductShareOperation] = []
    var updates: [ProductDeliveryUpdate] = []
    var withdrawalEnqueue: ((ProductShareOperation, UUID) throws -> ProductShareOperation)?
    func saveCustomProduct(_ command: CustomProductSave, now: Date) throws -> CustomProductRevision { command.revision }
    func enqueueProductOperation(_ operation: ProductShareOperation) throws { operations.append(operation) }
    func customProducts() throws -> [CustomProductRevision] { [] }
    func productAccountEpoch(ownerID: UUID) throws -> UUID? { operations.last(where: { $0.ownerID == ownerID && $0.status != .cancelled })?.epoch ?? operations.last(where: { $0.ownerID == ownerID })?.epoch }
    func productOperations(ownerID: UUID) throws -> [ProductShareOperation] { operations.filter { $0.ownerID == ownerID } }
    func dueProductOperations(ownerID: UUID, now: Date) throws -> [ProductShareOperation] {
        try productOperations(ownerID: ownerID).filter { $0.status == .pending && $0.predecessorOperationID == nil && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now) }
    }
    func recordProductDelivery(_ update: ProductDeliveryUpdate) throws {
        guard let index = operations.firstIndex(where: { $0.operationID == update.operationID && $0.ownerID == update.ownerID && $0.epoch == update.epoch && $0.storeEpoch == update.storeEpoch }),
              [.pending, .sending].contains(operations[index].status) else { throw CustomProductStoreError.obsoleteOperation }
        updates.append(update)
        if update.status == .sending {
            if let old = operations[index].envelope, old != update.envelope { throw CustomProductStoreError.immutableEnvelope }
            operations[index].envelope = update.envelope; operations[index].attempts += 1
        }
        operations[index].status = update.status; operations[index].nextAttemptAt = update.nextAttemptAt
        operations[index].reason = update.reason; operations[index].currentState = update.currentState
        operations[index].currentRevision = update.currentRevision
    }
    func pauseProductOperations(ownerID: UUID) throws {
        for index in operations.indices where operations[index].ownerID == ownerID && [.pending, .sending].contains(operations[index].status) { operations[index].status = .paused }
    }
    func resumeProductOperations(ownerID: UUID, fromEpoch: UUID, toEpoch: UUID) throws {
        for index in operations.indices where operations[index].ownerID == ownerID && operations[index].epoch == fromEpoch && operations[index].status == .paused {
            operations[index].epoch = toEpoch; operations[index].status = .pending
        }
    }
    func cancelProductPublications(ownerID: UUID) throws {
        for index in operations.indices where operations[index].ownerID == ownerID && operations[index].kind == .publish && operations[index].status != .acknowledged { operations[index].status = .cancelled }
    }
    func removeProductAccountState(ownerID: UUID) throws { operations.removeAll { $0.ownerID == ownerID } }
    func enqueueProductWithdrawal(_ operation: ProductShareOperation, expectedStoreEpoch: UUID) throws -> ProductShareOperation {
        guard let withdrawalEnqueue else { throw CustomProductStoreError.invalidOperation }
        return try withdrawalEnqueue(operation, expectedStoreEpoch)
    }
    func recordProductWithdrawalPreparation(_ update: ProductWithdrawalPreparationUpdate) throws -> ProductShareOperation { throw CustomProductStoreError.invalidOperation }
}

private actor SuspendedProductService: CommunityProductServicing {
    var caps = ProductCatalogCapabilities(supportedVersion: 2, enabled: true,
        limits: ProductCatalogLimits(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20), currentConsentVersion: 2,
        callerAcknowledgment: ProductConsentAcknowledgment(version: 2, generation: "1"), consentGeneration: "1", sharingPermission: true, publishResolutionVersion: 1, boundedPublicationVersion: 1)
    private(set) var bodies: [Data] = []
    private(set) var owners: [UUID] = []
    private var replies: [CheckedContinuation<ProductDeliveryReceipt, Error>] = []
    private(set) var resolutionBodies: [Data] = []
    private var resolutionReplies: [CheckedContinuation<ProductPublishResolution, Error>] = []
    private var resolutionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func waitForResolutions(_ count: Int) async {
        if resolutionBodies.count >= count { return }
        await withCheckedContinuation { resolutionWaiters.append((count, $0)) }
    }
    func finishResolution(_ index: Int, _ result: Result<ProductPublishResolution, Error>) { resolutionReplies[index].resume(with: result) }
    var consentCalls: [UUID] = []
    var holdConsent = false
    private var consentReply: CheckedContinuation<ProductConsentState, Error>?
    private var consentArrival: CheckedContinuation<Void, Never>?
    func holdNextConsent() { holdConsent = true }
    func waitForConsent() async {
        if !consentCalls.isEmpty { return }
        await withCheckedContinuation { consentArrival = $0 }
    }
    func finishConsent(_ state: ProductConsentState) { consentReply?.resume(returning: state) }
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    func setCapabilities(_ value: ProductCatalogCapabilities) { caps = value }
    /// When set, `capabilities()` throws it instead of answering.
    var capabilitiesError: Error?
    private var holdCapabilities = false
    private var capabilitiesReply: CheckedContinuation<ProductCatalogCapabilities, Error>?
    private var capabilitiesArrival: CheckedContinuation<Void, Never>?
    func setCapabilitiesError(_ value: Error?) { capabilitiesError = value }
    func holdNextCapabilities() { holdCapabilities = true }
    func waitForCapabilities() async {
        if capabilitiesReply != nil { return }
        await withCheckedContinuation { capabilitiesArrival = $0 }
    }
    func finishCapabilities() { capabilitiesReply?.resume(returning: caps); capabilitiesReply = nil }
    func capabilities() async throws -> ProductCatalogCapabilities {
        if holdCapabilities {
            holdCapabilities = false
            return try await withCheckedThrowingContinuation {
                capabilitiesReply = $0
                capabilitiesArrival?.resume(); capabilitiesArrival = nil
            }
        }
        if let capabilitiesError { throw capabilitiesError }
        return caps
    }
    func waitForRequests(_ count: Int) async {
        if bodies.count >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
    func finish(_ index: Int, _ result: Result<ProductDeliveryReceipt, Error>) { replies[index].resume(with: result) }
    private func suspend(body: Data, owner: UUID) async throws -> ProductDeliveryReceipt {
        try await withCheckedThrowingContinuation { continuation in
            bodies.append(body); owners.append(owner); replies.append(continuation)
            let ready = arrivals.filter { $0.0 <= bodies.count }; arrivals.removeAll { $0.0 <= bodies.count }
            for waiter in ready { waiter.1.resume() }
        }
    }
    func publish(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt {
        try await suspend(body: request.canonicalBody(), owner: expectedOwnerID)
    }
    func withdraw(_ request: ProductWithdrawRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt {
        try await suspend(body: request.canonicalBody(), owner: expectedOwnerID)
    }
    func resolvePublishForWithdrawal(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductPublishResolution {
        let body = try request.canonicalBody()
        return try await withCheckedThrowingContinuation { continuation in
            resolutionBodies.append(body); resolutionReplies.append(continuation)
            let ready = resolutionWaiters.filter { $0.0 <= resolutionBodies.count }
            resolutionWaiters.removeAll { $0.0 <= resolutionBodies.count }
            for waiter in ready { waiter.1.resume() }
        }
    }
    func contribution(productID: UUID, expectedOwnerID: UUID) async throws -> ProductContributionState { throw ProductAPIError.unavailable }
    func acknowledgeConsent(version: Int, expectedOwnerID: UUID) async throws -> ProductConsentState {
        consentCalls.append(expectedOwnerID)
        consentArrival?.resume(); consentArrival = nil
        if holdConsent { return try await withCheckedThrowingContinuation { consentReply = $0 } }
        return ProductConsentState(version: version, generation: caps.consentGeneration, acknowledged: true)
    }
    func searchProducts(query: String, kind: ProductKind?, cursor: String?) async throws -> CommunityProductPage { throw ProductAPIError.unavailable }
    func product(id: UUID) async throws -> CommunityProduct { throw ProductAPIError.unavailable }
}

extension ProductShareCoordinatorTests {
    private func queued(owner: UUID, epoch: UUID, kind: ProductOperationKind = .publish) -> ProductShareOperation {
        var op = ProductShareOperation(ownerID: owner, localProductID: UUID(), operationID: UUID(), clientRevisionID: UUID(),
            kind: kind, content: kind == .publish ? CustomProductContent(name: "Synthetic", kind: .food, basis: .per100g) : nil,
            serverProductID: kind == .withdraw ? UUID().uuidString.lowercased() : nil,
            expectedServerRevision: kind == .withdraw ? "1" : nil, consentGeneration: "1", epoch: epoch)
        op.storeEpoch = UUID(); return op
    }
    private func context(_ owner: UUID, _ epoch: UUID, sharing: Bool = true, generation: String = "1") -> ProductShareAccountContext {
        ProductShareAccountContext(ownerID: owner, profileReady: true, sharingAllowed: sharing, consentVersion: 2,
            serverGeneration: generation, localSessionEpoch: epoch, backendSupported: true)
    }
    private func receipt(_ operation: ProductShareOperation, state: ProductContributionStatus = .active, current: String = "1") -> ProductDeliveryReceipt {
        ProductDeliveryReceipt(operationID: operation.operationID, productID: operation.serverProductID.flatMap(UUID.init(uuidString:)) ?? UUID(),
            acknowledgedRevision: "1", currentRevision: current, currentState: state, replayed: false)
    }
    @MainActor func testAccountSwitchDropsSuspendedReplyAndHidesOtherOwnerStatus() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let op = queued(owner: owner, epoch: epoch); store.operations = [op]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch))
        let run = Task { await coordinator.runDueOperations(now: Date()) }
        await service.waitForRequests(1)
        coordinator.updateAccountContext(context(UUID(), UUID()))
        await service.finish(0, .success(receipt(op)))
        await run.value
        XCTAssertEqual(store.operations.first?.status, .paused)
        XCTAssertFalse(store.updates.contains { $0.status == .acknowledged })
        XCTAssertEqual(coordinator.status(localProductID: op.localProductID), .onThisPhone)
    }
    @MainActor func testEraseDropsReplyWithoutRecreatingRows() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let op = queued(owner: owner, epoch: epoch); store.operations = [op]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch))
        let run = Task { await coordinator.runDueOperations(now: Date()) }; await service.waitForRequests(1)
        coordinator.closeGate(reason: .erase)
        store.operations.removeAll()
        await service.finish(0, .success(receipt(op))); await run.value
        coordinator.updateAccountContext(context(owner, UUID()))
        await coordinator.runDueOperations(now: Date())
        XCTAssertTrue(store.operations.isEmpty)
        let count = await service.bodies.count; XCTAssertEqual(count, 1)
    }
    @MainActor func testOffOnNeverRevivesCanceledPublicationOrSchedulesItsNetworkFailure() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let op = queued(owner: owner, epoch: epoch); store.operations = [op]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch))
        let run = Task { await coordinator.runDueOperations(now: Date()) }; await service.waitForRequests(1)
        coordinator.closeGate(reason: .sharingDisabled)
        coordinator.updateAccountContext(context(owner, UUID(), sharing: false))
        await service.finish(0, .failure(ProductAPIError.unavailable)); await run.value
        coordinator.updateAccountContext(context(owner, UUID()))
        await coordinator.runDueOperations(now: Date())
        XCTAssertEqual(store.operations.first?.status, .cancelled)
        XCTAssertNil(store.operations.first?.nextAttemptAt)
        let count = await service.bodies.count; XCTAssertEqual(count, 1)
    }
    @MainActor func testResponseLossRetryRetainsExactEnvelopeAndUUIDAfterNewCoordinator() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let op = queued(owner: owner, epoch: epoch); store.operations = [op]
        let now = Date(timeIntervalSince1970: 1000)
        let first = ProductShareCoordinator(store: store, service: service, clock: { now }, jitter: { 1 })
        first.updateAccountContext(context(owner, epoch))
        let run = Task { await first.runDueOperations(now: now) }; await service.waitForRequests(1)
        await service.finish(0, .failure(ProductAPIError.unavailable)); await run.value
        XCTAssertEqual(store.operations.first?.nextAttemptAt, now.addingTimeInterval(2))
        let retained = try XCTUnwrap(store.operations.first?.envelope)
        let second = ProductShareCoordinator(store: store, service: service, clock: { now.addingTimeInterval(2) }, jitter: { 1 })
        second.updateAccountContext(context(owner, UUID()))
        let retry = Task { await second.runDueOperations(now: now.addingTimeInterval(2)) }; await service.waitForRequests(2)
        await service.finish(1, .success(receipt(op, state: .withdrawn, current: "2"))); await retry.value
        let bodies = await service.bodies
        XCTAssertEqual(bodies, [retained, retained])
        XCTAssertEqual(second.status(localProductID: op.localProductID), .removed)
    }
    @MainActor func testWithdrawalWhileOffUsesCurrentReceiptAfterRepublish() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let op = queued(owner: owner, epoch: epoch, kind: .withdraw); store.operations = [op]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch, sharing: false))
        let run = Task { await coordinator.runDueOperations(now: Date()) }; await service.waitForRequests(1)
        await service.finish(0, .success(receipt(op, state: .active, current: "3"))); await run.value
        XCTAssertEqual(coordinator.status(localProductID: op.localProductID), .shared)
        XCTAssertEqual(store.operations.first?.currentRevision, "3")
    }
    @MainActor func testRateLimitAndPermanentConflict() async throws {
        for failure in [ProductAPIError.rateLimited(retryAfterSeconds: "120"), .revisionConflict(currentRevision: "4", currentState: .active)] {
            let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
            let op = queued(owner: owner, epoch: epoch); store.operations = [op]
            let now = Date(timeIntervalSince1970: 1000)
            let coordinator = ProductShareCoordinator(store: store, service: service, clock: { now }, jitter: { 1 })
            coordinator.updateAccountContext(context(owner, epoch))
            let run = Task { await coordinator.runDueOperations(now: now) }; await service.waitForRequests(1)
            await service.finish(0, .failure(failure)); await run.value
            if case .rateLimited = failure {
                XCTAssertEqual(store.operations.first?.nextAttemptAt, now.addingTimeInterval(120))
            } else { XCTAssertEqual(store.operations.first?.status, .needsReview) }
            await coordinator.retry(operationID: op.operationID)
            let count = await service.bodies.count; XCTAssertEqual(count, 1)
        }
    }
    @MainActor func testDeletionPauseSurvivesAutomaticRefresh() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let op = queued(owner: owner, epoch: epoch); store.operations = [op]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch)); coordinator.closeGate(reason: .accountDeletion)
        coordinator.updateAccountContext(context(owner, UUID()))
        await coordinator.runDueOperations(now: Date())
        let count = await service.bodies.count; XCTAssertEqual(count, 0)
        XCTAssertEqual(store.operations.first?.status, .paused)
        coordinator.recoverAfterLifecyclePause(context(owner, UUID()))
        let run = Task { await coordinator.runDueOperations(now: Date()) }; await service.waitForRequests(1)
        await service.finish(0, .success(receipt(op))); await run.value
        XCTAssertEqual(coordinator.status(localProductID: op.localProductID), .shared)
    }
    @MainActor func testOldClientGenerationCannotPublishAndCorruptRetainedBytesNeverSend() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        var op = queued(owner: owner, epoch: epoch); store.operations = [op]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch, generation: "0"))
        await coordinator.runDueOperations(now: Date())
        var count = await service.bodies.count; XCTAssertEqual(count, 0)
        op.envelope = Data("{}".utf8); op.attempts = 1; store.operations = [op]
        coordinator.updateAccountContext(context(owner, UUID()))
        await coordinator.runDueOperations(now: Date())
        count = await service.bodies.count; XCTAssertEqual(count, 0)
        XCTAssertEqual(store.operations.first?.status, .failed)
    }
}


extension ProductShareCoordinatorTests {
    @MainActor func testProductionConsentRPCDoesNotTogglePermissionAndSyncLegacyCallCannotBypassIt() async throws {
        let session = AccountTestSupport.session, accountService = FakeAccountService(session: AccountTestSupport.session)
        accountService.profileValue = CommunityProfile(displayName: nil, shareLabels: false)
        let products = SuspendedProductService(), preferences = InMemoryDisplayPreferences()
        let account = AccountViewModel(service: accountService, preferences: preferences, productService: products)
        await account.load()
        account.acknowledgeDisclosure()
        XCTAssertTrue(account.needsDisclosure)
        XCTAssertFalse(preferences.hasSeenCommunityDisclosure(for: session.userID))
        await account.acknowledgeProductDisclosure()
        XCTAssertFalse(account.needsDisclosure)
        XCTAssertFalse(account.shareLabels)
        XCTAssertFalse(account.sharingAllowed)
        XCTAssertTrue(accountService.updates.isEmpty)
        let owners = await products.consentCalls
        XCTAssertEqual(owners, [UUID(uuidString: session.userID)!])
    }
    @MainActor func testDisclosureBecomesDueOnlyWhenTheProfileHasLoaded() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        service.profileError = CommunityError.network
        let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products)
        await account.load()
        XCTAssertTrue(account.needsDisclosure)
        XCTAssertFalse(account.profileReady)
        XCTAssertFalse(account.disclosureDue)
        service.profileError = nil
        await account.retryProfile()
        XCTAssertTrue(account.profileReady)
        XCTAssertTrue(account.disclosureDue)
        await account.acknowledgeProductDisclosure()
        XCTAssertFalse(account.needsDisclosure)
        XCTAssertFalse(account.disclosureDue)
    }
    @MainActor func testAlreadyAcknowledgedSignInIsNotDueWhileCapabilitiesLoad() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let preferences = InMemoryDisplayPreferences()
        preferences.setHasSeenCommunityDisclosure(true, for: AccountTestSupport.session.userID)
        let account = AccountViewModel(service: service, preferences: preferences, productService: products)
        await products.holdNextCapabilities()
        let loading = Task { await account.load() }
        await products.waitForCapabilities()
        // The window: signed in, profile read, capabilities not yet, so `needsDisclosure` is only a guess.
        XCTAssertTrue(account.profileReady)
        XCTAssertTrue(account.needsDisclosure)
        XCTAssertFalse(account.disclosureReady)
        XCTAssertFalse(account.disclosureDue)
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 0)
        await products.finishCapabilities()
        await loading.value
        XCTAssertFalse(account.needsDisclosure)
        XCTAssertFalse(account.disclosureDue)
    }
    @MainActor func testDisclosureDueWhileSignInSheetIsUpIsPendingUntilItsDismissal() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products)
        account.presentingSignIn = true
        await account.load()
        // Signed in and unacknowledged, but the sign-in sheet has not been reported gone.
        XCTAssertTrue(account.disclosureReady)
        XCTAssertTrue(account.needsDisclosure)
        XCTAssertTrue(account.disclosurePending)
        XCTAssertFalse(account.disclosureDue)
        // The binding turning false is only the start of the dismissal: still pending.
        account.presentingSignIn = false
        XCTAssertTrue(account.disclosurePending)
        XCTAssertFalse(account.disclosureDue)
        // The sheet's onDismiss reports it gone: now it is due and no longer pending.
        account.signInSheetDidDismiss()
        XCTAssertFalse(account.disclosurePending)
        XCTAssertTrue(account.disclosureDue)
    }
    @MainActor func testDismissalReportIsIgnoredWhileTheSignInSheetIsStillRequested() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products)
        account.presentingSignIn = true
        await account.load()
        account.signInSheetDidDismiss()
        XCTAssertTrue(account.signInSheetActive)
        XCTAssertFalse(account.disclosureDue)
    }
    @MainActor func testFailedCapabilityReadNeverOffersTheDisclosureToAnAcknowledgedAccount() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        await products.setCapabilitiesError(ProductAPIError.unavailable)
        let preferences = InMemoryDisplayPreferences()
        preferences.setHasSeenCommunityDisclosure(true, for: AccountTestSupport.session.userID)
        let account = AccountViewModel(service: service, preferences: preferences, productService: products)
        await account.load()
        XCTAssertTrue(account.needsDisclosure)
        XCTAssertFalse(account.disclosureReady)
        XCTAssertFalse(account.disclosureDue)
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 0)
    }
    @MainActor func testDisclosureReviewRequestOnlyCountsWhenReadySignedInAndUnacknowledged() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products)
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 0)
        // Profile read, capabilities not yet: needsDisclosure is only a guess, so a request is refused.
        await products.holdNextCapabilities()
        let loading = Task { await account.load() }
        await products.waitForCapabilities()
        XCTAssertTrue(account.needsDisclosure)
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 0)
        await products.finishCapabilities()
        await loading.value
        XCTAssertTrue(account.needsDisclosure)
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 1)
        await account.acknowledgeProductDisclosure()
        XCTAssertFalse(account.needsDisclosure)
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 1)
    }
    @MainActor func testDisclosureReviewRequestIsRefusedWhileTheSignInSheetIsStillActive() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products)
        account.presentingSignIn = true
        await account.load()
        account.presentingSignIn = false
        XCTAssertTrue(account.disclosureReady)
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 0)
        account.signInSheetDidDismiss()
        account.requestDisclosureReview()
        XCTAssertEqual(account.disclosureReviewRequests, 1)
    }
    @MainActor func testSettingsAppearingFreesASignInSheetThatNeverReportedItsDismissal() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products)
        account.presentingSignIn = true
        await account.load()
        // Signed in, but the sheet's dismissal was never reported (the form was torn down with it up).
        XCTAssertEqual(account.phase, .signedIn)
        XCTAssertTrue(account.presentingSignIn)
        XCTAssertFalse(account.disclosureDue)
        account.settingsDidAppear()
        XCTAssertFalse(account.presentingSignIn)
        XCTAssertFalse(account.signInSheetActive)
        XCTAssertTrue(account.disclosureDue)
    }
    @MainActor func testSettingsAppearingKeepsARequestedSignInSheetWhileSignedOut() async throws {
        let service = FakeAccountService(session: nil), products = SuspendedProductService()
        let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products)
        account.presentingSignIn = true
        account.settingsDidAppear()
        XCTAssertTrue(account.presentingSignIn)
        XCTAssertTrue(account.signInSheetActive)
    }
    @MainActor func testSignInSheetFlagCannotStayStuckAfterAMissedDismissal() async throws {
        // A request whose dismissal was never reported, signed out: Settings opening (load) frees it.
        let signedOut = FakeAccountService(session: AccountTestSupport.session)
        signedOut.restored = nil
        let first = AccountViewModel(service: signedOut, preferences: InMemoryDisplayPreferences(), productService: SuspendedProductService())
        first.presentingSignIn = true
        first.presentingSignIn = false
        XCTAssertTrue(first.signInSheetActive)
        await first.load()
        XCTAssertFalse(first.signInSheetActive)
        // Signed in with the dismissal never reported: signing out frees it.
        let service = FakeAccountService(session: AccountTestSupport.session)
        let second = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: SuspendedProductService())
        second.presentingSignIn = true
        await second.load()
        second.presentingSignIn = false
        XCTAssertTrue(second.signInSheetActive)
        await second.signOut()
        XCTAssertFalse(second.signInSheetActive)
    }
    @MainActor func testRefusedAcknowledgmentSaysSoInsteadOfDoingNothing() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        // The server never reports the caller's acknowledgment back, so Continue cannot complete.
        await products.setCapabilities(ProductCatalogCapabilities(supportedVersion: 2, enabled: true,
            limits: ProductCatalogLimits(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20), currentConsentVersion: 2,
            callerAcknowledgment: nil, consentGeneration: "1", sharingPermission: true, publishResolutionVersion: 1, boundedPublicationVersion: 1))
        let preferences = InMemoryDisplayPreferences()
        let account = AccountViewModel(service: service, preferences: preferences, productService: products)
        await account.load()
        XCTAssertTrue(account.needsDisclosure)
        XCTAssertNil(account.message)
        await account.acknowledgeProductDisclosure()
        XCTAssertTrue(account.needsDisclosure)
        XCTAssertEqual(account.message, AccountViewModel.genericMessage)
        XCTAssertFalse(account.isBusy)
        // The server catches up: the retry succeeds and the earlier error is gone.
        await products.setCapabilities(ProductCatalogCapabilities(supportedVersion: 2, enabled: true,
            limits: ProductCatalogLimits(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20), currentConsentVersion: 2,
            callerAcknowledgment: ProductConsentAcknowledgment(version: 2, generation: "1"), consentGeneration: "1", sharingPermission: true, publishResolutionVersion: 1, boundedPublicationVersion: 1))
        await account.acknowledgeProductDisclosure()
        XCTAssertFalse(account.needsDisclosure)
        XCTAssertNil(account.message)
    }
    @MainActor func testConsentReplyAfterSignOutCannotAcknowledgeOldOwner() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let preferences = InMemoryDisplayPreferences()
        let account = AccountViewModel(service: service, preferences: preferences, productService: products)
        await account.load(); await products.holdNextConsent()
        let acknowledgment = Task { await account.acknowledgeProductDisclosure() }
        await products.waitForConsent()
        await account.signOut()
        await products.finishConsent(ProductConsentState(version: 2, generation: "1", acknowledged: true))
        await acknowledgment.value
        XCTAssertFalse(preferences.hasSeenCommunityDisclosure(for: AccountTestSupport.session.userID))
        XCTAssertEqual(account.phase, .signedOut)
    }
    @MainActor func testConsentReplyAfterEraseCannotReacknowledgeOrReopenGate() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
        let preferences = InMemoryDisplayPreferences()
        let account = AccountViewModel(service: service, preferences: preferences, productService: products)
        await account.load(); await products.holdNextConsent()
        let acknowledgment = Task { await account.acknowledgeProductDisclosure() }
        await products.waitForConsent()
        account.pauseSharingForErase(); preferences.resetToDefaults()
        await products.finishConsent(ProductConsentState(version: 2, generation: "1", acknowledged: true))
        await acknowledgment.value
        XCTAssertFalse(preferences.hasSeenCommunityDisclosure(for: AccountTestSupport.session.userID))
        XCTAssertTrue(account.productDeliveryPausedAfterDeletion)
    }
    @MainActor func testAccountClosesGateBeforeSuspendedSignOutAndFailedDeletion() async throws {
        for deleting in [false, true] {
            let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService()
            let coordinator = ProductShareCoordinator(store: DeliveryStorePort(), service: products)
            let account = AccountViewModel(service: service, preferences: InMemoryDisplayPreferences(), productService: products, productSharing: coordinator)
            await account.load()
            let gate = CallGate()
            if deleting { service.deleteGate = gate; service.deleteError = CommunityError.network }
            else { service.signOutGate = gate }
            let work = Task { if deleting { await account.deleteAccount() } else { await account.signOut() } }
            for _ in 0..<1000 { if gate.entered { break }; await Task.yield() }
            XCTAssertTrue(gate.entered)
            XCTAssertNotNil(coordinator.pauseReason)
            gate.open(); await work.value
            if deleting {
                XCTAssertTrue(account.productDeliveryPausedAfterDeletion)
                await account.refreshProductSharing()
                XCTAssertEqual(coordinator.pauseReason, .accountDeletion)
            } else { XCTAssertNil(coordinator.accountContext) }
        }
    }
    @MainActor func testStaleUnattemptedConsentPersistsRefusalWithoutSending() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let op = queued(owner: owner, epoch: epoch); store.operations = [op]
        await service.setCapabilities(ProductCatalogCapabilities(supportedVersion: 2, enabled: true,
            limits: ProductCatalogLimits(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20), currentConsentVersion: 2,
            callerAcknowledgment: ProductConsentAcknowledgment(version: 2, generation: "2"), consentGeneration: "2", sharingPermission: true, boundedPublicationVersion: 1))
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch, generation: "2"))
        await coordinator.runDueOperations(now: Date())
        XCTAssertEqual(store.operations.first?.status, .needsReview)
        XCTAssertEqual(store.operations.first?.attempts, 0)
        XCTAssertNil(store.operations.first?.envelope)
        let count = await service.bodies.count; XCTAssertEqual(count, 0)
    }
}

#if canImport(SwiftData)
extension ProductShareCoordinatorTests {
    @MainActor func testRealStoreOfflineEditLostReplyReopenReplaysPredecessorBeforeBindingSuccessor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.store"), owner = UUID(), epoch = UUID()
        var store = try SwiftDataJournalStore(url: path)
        let service = SuspendedProductService(), now = Date(timeIntervalSince1970: 1000)
        let v1 = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic v1", kind: .food, basis: .per100g))
        let first = ProductShareOperation(ownerID: owner, localProductID: v1.localProductID, operationID: UUID(), clientRevisionID: v1.revisionID,
            kind: .publish, content: v1.content, consentGeneration: "1", epoch: epoch)
        let snapshot = ProductDefinition(snapshotID: v1.revisionID.uuidString, productID: v1.localProductID.uuidString, name: v1.content.name, labelBasis: "per 100 g", catalogOrigin: "custom", catalogVersion: v1.revisionID.uuidString)
        let intake = ProductIntakeDraft(intake: Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "portion", name: "Synthetic", amount: 1, unit: .g)], snapshot: snapshot)
        try store.saveCustomProduct(CustomProductSave(revision: v1, intake: intake, publication: first), now: now)
        let coordinator = ProductShareCoordinator(store: store, service: service, clock: { now }, jitter: { 1 })
        coordinator.updateAccountContext(context(owner, epoch))
        let firstRun = Task { await coordinator.runDueOperations(now: now) }; await service.waitForRequests(1)
        let v2 = CustomProductRevision(localProductID: v1.localProductID, revisionID: UUID(), content: CustomProductContent(name: "Synthetic v2", kind: .food, basis: .per100g))
        let second = ProductShareOperation(ownerID: owner, localProductID: v2.localProductID, operationID: UUID(), clientRevisionID: v2.revisionID,
            kind: .publish, content: v2.content, consentGeneration: "1", epoch: epoch)
        try store.saveCustomProduct(CustomProductSave(revision: v2, expectedLocalRevision: v1.revisionID, publication: second), now: now)
        await service.finish(0, .failure(ProductAPIError.unavailable)); await firstRun.value
        store.close(); store = try SwiftDataJournalStore(url: path)
        let resumed = ProductShareCoordinator(store: store, service: service, clock: { now.addingTimeInterval(2) }, jitter: { 1 })
        resumed.updateAccountContext(context(owner, UUID()))
        let replay = Task { await resumed.runDueOperations(now: now.addingTimeInterval(2)) }; await service.waitForRequests(2)
        let serverID = UUID()
        await service.finish(1, .success(ProductDeliveryReceipt(operationID: first.operationID, productID: serverID,
            acknowledgedRevision: "1", currentRevision: "1", currentState: .active, replayed: true)))
        await service.waitForRequests(3)
        let bodies = await service.bodies
        XCTAssertEqual(bodies[0], bodies[1])
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: bodies[2])
        XCTAssertEqual(request.productID, serverID.uuidString.lowercased())
        XCTAssertEqual(request.expectedServerRevision, "1")
        XCTAssertEqual(request.product.name, "Synthetic v2")
        await service.finish(2, .success(ProductDeliveryReceipt(operationID: second.operationID, productID: serverID,
            acknowledgedRevision: "2", currentRevision: "2", currentState: .active, replayed: false)))
        await replay.value
        XCTAssertEqual(try store.customProducts(), [v2])
        XCTAssertEqual(try store.product(snapshotID: snapshot.snapshotID), snapshot)
        XCTAssertEqual(Set(try store.productOperations(ownerID: owner).compactMap(\.acknowledgedProductID)).count, 1)
        XCTAssertEqual(resumed.status(localProductID: v1.localProductID), .shared)
    }
}

extension ProductShareCoordinatorTests {
    @MainActor func testRealStoreLostFirstReplyOffReopenResolvesOrCancelsAndEraseRejectsLateResolver() async throws {
        for outcome in 0..<3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("synthetic.store"), owner = UUID(), epoch = UUID(), now = Date()
            var store = try SwiftDataJournalStore(url: path)
            let service = SuspendedProductService()
            let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic", kind: .food, basis: .per100g))
            let publication = ProductShareOperation(ownerID: owner, localProductID: revision.localProductID, operationID: UUID(), clientRevisionID: revision.revisionID,
                kind: .publish, content: revision.content, consentGeneration: "1", epoch: epoch)
            try store.saveCustomProduct(CustomProductSave(revision: revision, publication: publication), now: now)
            let first = ProductShareCoordinator(store: store, service: service)
            first.updateAccountContext(context(owner, epoch))
            let send = Task { await first.runDueOperations(now: now) }; await service.waitForRequests(1)
            first.closeGate(reason: .sharingDisabled)
            first.updateAccountContext(context(owner, UUID(), sharing: false))
            await service.finish(0, .failure(ProductAPIError.unavailable)); await send.value
            let source = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
            let currentEpoch = try XCTUnwrap(first.accountContext?.localSessionEpoch)
            let intent = ProductShareOperation(ownerID: owner, localProductID: revision.localProductID, operationID: UUID(), clientRevisionID: revision.revisionID,
                kind: .withdraw, epoch: currentEpoch)
            _ = try first.requestWithdrawal(intent, expectedStoreEpoch: XCTUnwrap(source.storeEpoch))
            store.close(); store = try SwiftDataJournalStore(url: path)
            let resumed = ProductShareCoordinator(store: store, service: service)
            resumed.updateAccountContext(context(owner, UUID(), sharing: false))
            let resolving = Task { await resumed.runDueOperations(now: now) }; await service.waitForResolutions(1)
            if outcome == 2 { resumed.closeGate(reason: .erase); try store.eraseAll() }
            let server = UUID()
            if outcome == 0 {
                await service.finishResolution(0, .success(.committed(ProductDeliveryReceipt(operationID: publication.operationID, productID: server,
                    acknowledgedRevision: "1", currentRevision: "1", currentState: .active, replayed: true))))
                await service.waitForRequests(2)
                let bodies = await service.bodies
                let request = try JSONDecoder().decode(ProductWithdrawRequest.self, from: bodies[1])
                XCTAssertEqual(request.expectedServerRevision, "1")
                XCTAssertEqual(request.productID, server.uuidString.lowercased())
                await service.finish(1, .success(ProductDeliveryReceipt(operationID: intent.operationID, productID: server,
                    acknowledgedRevision: "2", currentRevision: "2", currentState: .withdrawn, replayed: false)))
            } else { await service.finishResolution(0, .success(.canceledBeforeCommit(operationID: publication.operationID, replayed: false))) }
            await resolving.value
            let resolverBodies = await service.resolutionBodies
            XCTAssertEqual(resolverBodies, [source.envelope!])
            let rows = try store.productOperations(ownerID: owner)
            if outcome == 2 { XCTAssertTrue(rows.isEmpty) }
            else {
                XCTAssertEqual(rows.first?.status, .cancelled)
                XCTAssertEqual(rows.first?.epoch, epoch)
                XCTAssertEqual(rows.first?.envelope, source.envelope)
                XCTAssertEqual(rows.last?.attempts, outcome == 0 ? 1 : 0)
                XCTAssertEqual(rows.last?.preparationAttempts, 1)
                XCTAssertEqual(resumed.status(localProductID: revision.localProductID), .removed)
                if outcome == 1 {
                    XCTAssertEqual(rows.last?.status, .satisfied)
                    XCTAssertNil(rows.last?.serverProductID)
                    XCTAssertNil(rows.last?.acknowledgedRevision)
                }
            }
        }
    }
}

#endif

extension ProductShareCoordinatorTests {
    @MainActor func testCancellationPausesWithoutNetworkRetry() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let operation = queued(owner: owner, epoch: epoch); store.operations = [operation]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch))
        let run = Task { await coordinator.runDueOperations(now: Date()) }; await service.waitForRequests(1)
        await service.finish(0, .failure(CancellationError())); await run.value
        XCTAssertEqual(store.operations.first?.status, .paused)
        XCTAssertNil(store.operations.first?.nextAttemptAt)
        XCTAssertFalse(store.updates.contains { $0.reason == .network })
    }
    @MainActor func testConcurrentTriggerWaitsForOldOwnerAndThenRunsNewOwnerSerially() async throws {
        let a = UUID(), b = UUID(), firstEpoch = UUID(), secondEpoch = UUID()
        let store = DeliveryStorePort(), service = SuspendedProductService()
        let first = queued(owner: a, epoch: firstEpoch), second = queued(owner: b, epoch: secondEpoch)
        store.operations = [first, second]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(a, firstEpoch))
        let running = Task { await coordinator.runDueOperations(now: Date()) }; await service.waitForRequests(1)
        coordinator.updateAccountContext(context(b, secondEpoch))
        let trigger = Task { await coordinator.runDueOperations(now: Date()) }
        await Task.yield()
        var count = await service.bodies.count; XCTAssertEqual(count, 1)
        await service.finish(0, .success(receipt(first)))
        await service.waitForRequests(2)
        count = await service.bodies.count; XCTAssertEqual(count, 2)
        await service.finish(1, .success(receipt(second)))
        await trigger.value; await running.value
        let owners = await service.owners; XCTAssertEqual(owners, [a, b])
        XCTAssertEqual(store.operations.first?.status, .paused)
        XCTAssertEqual(coordinator.status(localProductID: second.localProductID), .shared)
    }
}


extension ProductShareCoordinatorTests {
    @MainActor func testSuspendedSignOutRefusesFreshForegroundRefreshAndRestore() async throws {
        let service = FakeAccountService(session: AccountTestSupport.session), products = SuspendedProductService(), store = DeliveryStorePort()
        let preferences = InMemoryDisplayPreferences()
        preferences.setHasSeenCommunityDisclosure(true, for: AccountTestSupport.session.userID)
        let coordinator = ProductShareCoordinator(store: store, service: products)
        let account = AccountViewModel(service: service, preferences: preferences, productService: products, productSharing: coordinator)
        await account.load()
        let context = try XCTUnwrap(coordinator.accountContext)
        let operation = queued(owner: context.ownerID, epoch: context.localSessionEpoch)
        store.operations = [operation]
        let gate = CallGate(); service.signOutGate = gate
        let logout = Task { await account.signOut() }
        for _ in 0..<1000 { if gate.entered { break }; await Task.yield() }
        XCTAssertTrue(gate.entered)
        await account.refreshProductSharing()
        XCTAssertFalse(account.sharingAllowed)
        XCTAssertNotNil(coordinator.pauseReason)
        var deliveryFinished = false
        let delivery = Task { await coordinator.runDueOperations(now: Date()); deliveryFinished = true }
        for _ in 0..<1000 {
            let count = await products.bodies.count
            if deliveryFinished || count > 0 { break }
            await Task.yield()
        }
        let calls = await products.bodies.count
        XCTAssertEqual(calls, 0)
        if calls > 0 { await products.finish(0, .success(receipt(operation))) }
        await delivery.value
        // A restore started after logout admission must not re-admit the still-valid stored session.
        await account.load()
        XCTAssertEqual(account.phase, .signedOut)
        gate.open(); await logout.value
        await account.refreshProductSharing(); await account.load()
        XCTAssertEqual(account.phase, .signedOut)
        XCTAssertNil(coordinator.accountContext)
        // Only a fresh, deliberate sign-in may re-establish eligibility.
        await account.signInWithApple(idToken: "synthetic", nonce: "synthetic")
        XCTAssertEqual(account.phase, .signedIn)
    }

    @MainActor func testUnrelatedWithdrawalAndEnqueueFailureLeaveActiveSendRecoverableInSameContext() async throws {
        for enqueueFails in [false, true] {
            let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
            let first = queued(owner: owner, epoch: epoch), removal = queued(owner: owner, epoch: epoch, kind: .withdraw)
            store.operations = [first]
            store.withdrawalEnqueue = { [unowned store] operation, expectedEpoch in
                if enqueueFails { throw CustomProductStoreError.invalidOperation }
                var saved = operation; saved.storeEpoch = expectedEpoch
                // Keep the test focused on A's recovery. The real-store variant below also delivers B.
                saved.nextAttemptAt = Date.distantFuture
                store.operations.append(saved)
                return saved
            }
            let now = Date(timeIntervalSince1970: 1000)
            let coordinator = ProductShareCoordinator(store: store, service: service, clock: { now }, jitter: { 1 })
            let initialContext = context(owner, epoch)
            coordinator.updateAccountContext(initialContext)
            let sending = Task { await coordinator.runDueOperations(now: now) }; await service.waitForRequests(1)
            if enqueueFails { XCTAssertThrowsError(try coordinator.requestWithdrawal(removal, expectedStoreEpoch: removal.storeEpoch!)) }
            else { _ = try coordinator.requestWithdrawal(removal, expectedStoreEpoch: removal.storeEpoch!) }
            await service.finish(0, .failure(ProductAPIError.unavailable)); await sending.value
            let saved = try XCTUnwrap(store.operations.first)
            XCTAssertEqual(coordinator.accountContext, initialContext)
            XCTAssertEqual(saved.status, .pending)
            XCTAssertEqual(saved.nextAttemptAt, now.addingTimeInterval(2))
            XCTAssertEqual(saved.operationID, first.operationID)
            XCTAssertEqual(saved.attempts, 1)
            // Avoid hanging a failing implementation whose row is stranded in .sending.
            if saved.status == .pending {
                let replay = Task { await coordinator.runDueOperations(now: now.addingTimeInterval(2)) }; await service.waitForRequests(2)
                await service.finish(1, .success(receipt(first))); await replay.value
                let bodies = await service.bodies
                XCTAssertEqual(bodies[0], bodies[1])
                XCTAssertEqual(store.operations.first?.status, .acknowledged)
            }
        }
    }
}

extension ProductShareCoordinatorTests {
    @MainActor func testSameProductWithdrawalDropsCanceledReplyWithoutClosingOtherWork() async throws {
        let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
        let source = queued(owner: owner, epoch: epoch)
        store.operations = [source]
        store.withdrawalEnqueue = { [unowned store] operation, expectedEpoch in
            store.operations[0].status = .cancelled
            var saved = operation; saved.storeEpoch = expectedEpoch; saved.nextAttemptAt = Date.distantFuture
            store.operations.append(saved)
            return saved
        }
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(context(owner, epoch))
        let run = Task { await coordinator.runDueOperations(now: Date()) }; await service.waitForRequests(1)
        let intent = ProductShareOperation(ownerID: owner, localProductID: source.localProductID, operationID: UUID(),
            clientRevisionID: source.clientRevisionID, kind: .withdraw, epoch: epoch)
        _ = try coordinator.requestWithdrawal(intent, expectedStoreEpoch: source.storeEpoch!)
        await service.finish(0, .success(receipt(source))); await run.value
        XCTAssertEqual(store.operations.first?.status, .cancelled)
        XCTAssertNil(coordinator.pauseReason)
        XCTAssertFalse(store.updates.contains { $0.status == .acknowledged })
    }
}

#if canImport(SwiftData)
extension ProductShareCoordinatorTests {
    @MainActor func testRealStoreUnrelatedWithdrawalSuccessOrRollbackPreservesSameContextReplayAndRemoval() async throws {
        for enqueueFails in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("synthetic.store"))
            let owner = UUID(), epoch = UUID(), now = Date(timeIntervalSince1970: 1000), remoteB = UUID()
            let service = SuspendedProductService()
            let b = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic B", kind: .food, basis: .per100g))
            let bPublication = ProductShareOperation(ownerID: owner, localProductID: b.localProductID, operationID: UUID(),
                clientRevisionID: b.revisionID, kind: .publish, content: b.content, consentGeneration: "1", epoch: epoch)
            try store.saveCustomProduct(CustomProductSave(revision: b, publication: bPublication), now: now)
            let bStored = try XCTUnwrap(try store.productOperations(ownerID: owner).first), bStoreEpoch = try XCTUnwrap(bStored.storeEpoch)
            try store.recordProductDelivery(ProductDeliveryUpdate(operationID: bPublication.operationID, ownerID: owner, epoch: epoch,
                storeEpoch: bStoreEpoch, status: .sending, envelope: ProductShareDeliveryWorker.publishRequest(bStored).canonicalBody()))
            try store.recordProductDelivery(ProductDeliveryUpdate(operationID: bPublication.operationID, ownerID: owner, epoch: epoch,
                storeEpoch: bStoreEpoch, status: .acknowledged, serverProductID: remoteB.uuidString.lowercased(), acknowledgedRevision: "1", currentRevision: "1", currentState: .active))
            let a = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic A", kind: .food, basis: .per100g))
            let aPublication = ProductShareOperation(ownerID: owner, localProductID: a.localProductID, operationID: UUID(),
                clientRevisionID: a.revisionID, kind: .publish, content: a.content, consentGeneration: "1", epoch: epoch)
            try store.saveCustomProduct(CustomProductSave(revision: a, publication: aPublication), now: now)
            let coordinator = ProductShareCoordinator(store: store, service: service, clock: { now }, jitter: { 1 })
            let initialContext = context(owner, epoch)
            coordinator.updateAccountContext(initialContext)
            let firstRun = Task { await coordinator.runDueOperations(now: now) }; await service.waitForRequests(1)
            let original = try XCTUnwrap(try store.productOperations(ownerID: owner).first(where: { $0.operationID == aPublication.operationID }))
            let removal = ProductShareOperation(ownerID: owner, localProductID: b.localProductID, operationID: UUID(),
                clientRevisionID: b.revisionID, kind: .withdraw, epoch: epoch)
            if enqueueFails {
                store.failNextSaveForTesting = true
                XCTAssertThrowsError(try coordinator.requestWithdrawal(removal, expectedStoreEpoch: bStoreEpoch))
                XCTAssertFalse(try store.productOperations(ownerID: owner).contains { $0.operationID == removal.operationID })
            } else { _ = try coordinator.requestWithdrawal(removal, expectedStoreEpoch: bStoreEpoch) }
            await service.finish(0, .failure(ProductAPIError.unavailable))
            let removalReceipt = ProductDeliveryReceipt(operationID: removal.operationID, productID: remoteB,
                acknowledgedRevision: "2", currentRevision: "2", currentState: .withdrawn, replayed: false)
            if !enqueueFails {
                await service.waitForRequests(2)
                await service.finish(1, .success(removalReceipt))
            }
            await firstRun.value
            let pending = try XCTUnwrap(try store.productOperations(ownerID: owner).first(where: { $0.operationID == aPublication.operationID }))
            XCTAssertEqual(pending.status, .pending)
            XCTAssertEqual(pending.envelope, original.envelope)
            XCTAssertEqual(pending.operationID, original.operationID)
            XCTAssertEqual(pending.nextAttemptAt, now.addingTimeInterval(2))
            XCTAssertEqual(coordinator.accountContext, initialContext)
            if enqueueFails { _ = try coordinator.requestWithdrawal(removal, expectedStoreEpoch: bStoreEpoch) }
            let retry = Task { await coordinator.runDueOperations(now: now.addingTimeInterval(2)) }
            let replayIndex = enqueueFails ? 1 : 2
            await service.waitForRequests(replayIndex + 1)
            await service.finish(replayIndex, .success(receipt(aPublication)))
            if enqueueFails {
                await service.waitForRequests(3)
                await service.finish(2, .success(removalReceipt))
            }
            await retry.value
            let bodies = await service.bodies
            XCTAssertEqual(bodies[0], bodies[replayIndex])
            let final = try store.productOperations(ownerID: owner)
            XCTAssertEqual(final.first(where: { $0.operationID == aPublication.operationID })?.status, .acknowledged)
            XCTAssertEqual(final.first(where: { $0.operationID == aPublication.operationID })?.attempts, 2)
            XCTAssertEqual(final.first(where: { $0.operationID == removal.operationID })?.status, .acknowledged)
            XCTAssertEqual(coordinator.status(localProductID: b.localProductID), .removed)
            XCTAssertEqual(coordinator.accountContext, initialContext)
        }
    }
}
#endif

extension ProductShareCoordinatorTests {
    @MainActor func testMissingBoundedVersionOrDisabledPublicationStillAllowsExactAttemptReplayAndWithdrawal() async throws {
        for enabled in [true, false] {
            let owner = UUID(), epoch = UUID(), store = DeliveryStorePort(), service = SuspendedProductService()
            var attempted = queued(owner: owner, epoch: epoch)
            attempted.envelope = try ProductShareDeliveryWorker.publishRequest(attempted).canonicalBody()
            attempted.attempts = 1
            let fresh = queued(owner: owner, epoch: epoch), removal = queued(owner: owner, epoch: epoch, kind: .withdraw)
            store.operations = [fresh, attempted, removal]
            await service.setCapabilities(.init(supportedVersion: 2, enabled: enabled, limits: .init(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20), currentConsentVersion: 2, callerAcknowledgment: .init(version: 2, generation: "1"), consentGeneration: "1", sharingPermission: true, publishResolutionVersion: 1, boundedPublicationVersion: nil))
            let coordinator = ProductShareCoordinator(store: store, service: service)
            coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true, freshPublicationSupported: false))
            let run = Task { await coordinator.runDueOperations(now: Date()) }
            await service.waitForRequests(1); await service.finish(0, .success(receipt(attempted)))
            await service.waitForRequests(2); await service.finish(1, .success(receipt(removal, state: .withdrawn)))
            await run.value
            let bodies = await service.bodies
            XCTAssertEqual(bodies.first, attempted.envelope)
            XCTAssertEqual(store.operations[0].attempts, 0)
            XCTAssertEqual(store.operations[1].status, .acknowledged)
            XCTAssertEqual(store.operations[2].status, .acknowledged)
        }
    }
}
