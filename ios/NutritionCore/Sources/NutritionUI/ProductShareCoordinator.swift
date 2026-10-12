import Foundation
import NutritionJournal
import NutritionProviders

public struct ProductShareAccountContext: Equatable, Sendable {
    public let ownerID: UUID
    public let profileReady: Bool
    public let sharingAllowed: Bool
    public let consentVersion: Int
    public let serverGeneration: String
    public let localSessionEpoch: UUID
    public let backendSupported: Bool
    public init(ownerID: UUID, profileReady: Bool, sharingAllowed: Bool, consentVersion: Int,
                serverGeneration: String, localSessionEpoch: UUID, backendSupported: Bool) {
        self.ownerID = ownerID; self.profileReady = profileReady; self.sharingAllowed = sharingAllowed
        self.consentVersion = consentVersion; self.serverGeneration = serverGeneration
        self.localSessionEpoch = localSessionEpoch; self.backendSupported = backendSupported
    }
}
public enum ProductSharePauseReason: String, Sendable { case signOut, accountDeletion, erase, accountChanged, sharingDisabled, authentication, consent, unavailable }
public enum ProductShareStatus: String, Sendable {
    case onThisPhone = "On this phone", waiting = "Waiting to share", paused = "Sharing paused"
    case shared = "Shared", failed = "Couldn't share", removalPending = "Removal pending", removed = "My contribution removed"
}

/// One serial task owns delivery. Cancellation is complemented by session, row and store-generation checks.
@MainActor public final class ProductShareCoordinator {
    public private(set) var accountContext: ProductShareAccountContext?
    public private(set) var pauseReason: ProductSharePauseReason?
    public private(set) var storageFailed = false
    private let store: any CustomProductStore
    private let service: any CommunityProductServicing
    private let clock: () -> Date
    private let jitter: () -> Double
    private var generation = UUID()
    private var running: Task<Void, Never>?
    private var rerunRequested = false
    private var lifecycleBlocked = false
    private var lifecycleOwnerID: UUID?

    public init(store: any CustomProductStore, service: any CommunityProductServicing,
                clock: @escaping () -> Date = Date.init, jitter: @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.store = store; self.service = service; self.clock = clock; self.jitter = jitter
    }

    public func closeGate(reason: ProductSharePauseReason) {
        generation = UUID(); running?.cancel()
        if !lifecycleBlocked { pauseReason = reason }
        if reason == .accountDeletion || reason == .erase {
            lifecycleBlocked = true; lifecycleOwnerID = accountContext?.ownerID
        }
        guard let context = accountContext else { return }
        do {
            try store.pauseProductOperations(ownerID: context.ownerID)
            if reason == .sharingDisabled { try store.cancelProductPublications(ownerID: context.ownerID) }
        } catch { storageFailed = true }
    }

    /// Automatic account/profile refresh cannot undo a failed deletion or erase pause.
    public func updateAccountContext(_ context: ProductShareAccountContext?) {
        if context == accountContext { return }
        closeGate(reason: context?.ownerID == accountContext?.ownerID ? .accountChanged : .signOut)
        accountContext = context
        guard let context else { return }
        if lifecycleBlocked, let owner = lifecycleOwnerID, owner != context.ownerID { lifecycleBlocked = false; lifecycleOwnerID = nil }
        if lifecycleBlocked && lifecycleOwnerID == nil { lifecycleOwnerID = context.ownerID }
        do {
            if !context.sharingAllowed { try store.cancelProductPublications(ownerID: context.ownerID) }
            guard !lifecycleBlocked, context.profileReady, context.backendSupported else { return }
            // Terminal operations deliberately retain historical epochs; mappings own the current epoch.
            if let epoch = try store.productAccountEpoch(ownerID: context.ownerID),
               epoch != context.localSessionEpoch {
                try store.pauseProductOperations(ownerID: context.ownerID)
                try store.resumeProductOperations(ownerID: context.ownerID, fromEpoch: epoch, toEpoch: context.localSessionEpoch)
            }
            storageFailed = false; pauseReason = nil
        } catch { storageFailed = true; pauseReason = .unavailable }
    }

    /// Called only after explicit recovery revalidated the live owner, profile and backend capability.
    public func recoverAfterLifecyclePause(_ context: ProductShareAccountContext) {
        lifecycleBlocked = false
        accountContext = nil
        updateAccountContext(context)
    }

    public func accountWasDeleted(ownerID: UUID) {
        if accountContext?.ownerID == ownerID { closeGate(reason: .accountDeletion) }
        do { try store.removeProductAccountState(ownerID: ownerID) }
        catch { storageFailed = true }
        if accountContext?.ownerID == ownerID { accountContext = nil }
        if lifecycleOwnerID == ownerID { lifecycleBlocked = false; lifecycleOwnerID = nil }
    }

    public func status(localProductID: UUID) -> ProductShareStatus {
        guard let context = accountContext,
              let operation = try? store.productOperations(ownerID: context.ownerID).last(where: { $0.localProductID == localProductID }) else { return .onThisPhone }
        if operation.status == .failed || operation.status == .needsReview { return .failed }
        if operation.kind == .withdraw && ![.acknowledged, .satisfied].contains(operation.status) { return .removalPending }
        if operation.status == .acknowledged || operation.status == .satisfied {
            if operation.currentState == .active { return .shared }
            if operation.currentState == .withdrawn || operation.status == .satisfied { return .removed }
            return .failed
        }
        if pauseReason != nil || operation.status == .paused || operation.status == .cancelled { return .paused }
        return .waiting
    }

    @discardableResult public func requestWithdrawal(_ operation: ProductShareOperation, expectedStoreEpoch: UUID) throws -> ProductShareOperation {
        guard let context = accountContext, operation.ownerID == context.ownerID,
              operation.epoch == context.localSessionEpoch, !lifecycleBlocked else { throw CustomProductStoreError.obsoleteOperation }
        // Invalidates even transports that ignore cancellation, before the atomic durable intent.
        generation = UUID(); running?.cancel()
        return try store.enqueueProductWithdrawal(operation, expectedStoreEpoch: expectedStoreEpoch)
    }

    public func retry(operationID: UUID) async {
        guard let context = accountContext,
              let operation = try? store.productOperations(ownerID: context.ownerID).first(where: { $0.operationID == operationID }),
              operation.status == .pending else { return }
        // A manual retry still honors server Retry-After and never revives permanent or canceled work.
        await runDueOperations(now: clock())
    }

    public func runDueOperations(now: Date) async {
        if let running { rerunRequested = true; await running.value; return }
        guard let context = accountContext, pauseReason == nil, !lifecycleBlocked, !storageFailed,
              context.profileReady, context.backendSupported else { return }
        let token = generation
        let task = Task<Void, Never> { [weak self] in await self?.deliver(context: context, token: token, now: now) }
        running = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        running = nil
        if rerunRequested {
            rerunRequested = false
            await runDueOperations(now: clock())
        }
    }

    private func valid(_ context: ProductShareAccountContext, _ token: UUID) -> Bool {
        !Task.isCancelled && generation == token && accountContext == context && pauseReason == nil && !lifecycleBlocked && !storageFailed
    }
    private func current(_ operation: ProductShareOperation, context: ProductShareAccountContext, token: UUID) throws -> ProductShareOperation {
        guard valid(context, token), let saved = try store.productOperations(ownerID: context.ownerID).first(where: { $0.operationID == operation.operationID }),
              saved.epoch == context.localSessionEpoch, saved.storeEpoch == operation.storeEpoch,
              [.pending, .sending].contains(saved.status) else { throw CancellationError() }
        return saved
    }
    private func deliver(context: ProductShareAccountContext, token: UUID, now: Date) async {
        do {
            let capabilities = try await service.capabilities()
            guard valid(context, token), capabilities.supportedVersion == 2 else { return }
            if !capabilities.sharingPermission { try store.cancelProductPublications(ownerID: context.ownerID) }
            let publicationEligible = context.sharingAllowed && capabilities.enabled && capabilities.sharingPermission &&
                context.consentVersion == 2 && capabilities.currentConsentVersion == 2 &&
                capabilities.consentGeneration == context.serverGeneration &&
                capabilities.callerAcknowledgment?.generation == capabilities.consentGeneration && capabilities.callerAcknowledgment?.version == 2
            var processed = Set<UUID>()
            while valid(context, token) {
                let operations = try store.productOperations(ownerID: context.ownerID)
                guard let candidate = operations.first(where: {
                    $0.epoch == context.localSessionEpoch && $0.status == .pending && !processed.contains($0.operationID) &&
                    ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now) &&
                    ($0.kind == .withdraw || (publicationEligible && $0.predecessorOperationID == nil))
                }) else { break }
                processed.insert(candidate.operationID)
                var operation = candidate
                if operation.kind == .publish && operation.attempts == 0 && operation.consentGeneration != capabilities.consentGeneration {
                    try record(operation, status: .needsReview, reason: .consent)
                    continue
                }
                if operation.kind == .withdraw, operation.predecessorOperationID != nil {
                    guard capabilities.supportsPublishResolution else { continue }
                    guard let prepared = await prepare(operation, context: context, token: token) else { continue }
                    operation = prepared
                    if operation.status != .pending || operation.predecessorOperationID != nil { continue }
                }
                await send(operation, context: context, token: token)
            }
        } catch is CancellationError { }
        catch {
            if valid(context, token), let failure = error as? ProductAPIError,
               failure == .unauthorized || failure == .ownerMismatch { closeGate(reason: .authentication) }
        }
    }

    private func prepare(_ operation: ProductShareOperation, context: ProductShareAccountContext, token: UUID) async -> ProductShareOperation? {
        var active = operation
        var source: ProductShareOperation?
        do {
            active = try current(operation, context: context, token: token)
            guard let predecessor = active.predecessorOperationID,
                  let found = try store.productOperations(ownerID: context.ownerID).first(where: { $0.operationID == predecessor }),
                  found.kind == .publish, found.status == .cancelled, found.attempts > 0 else { return nil }
            source = found
            active = try preparation(active, source: found, event: .beginAttempt)
            if found.publicationResolution == .canceledBeforeCommit {
                guard let product = found.serverProductID.flatMap(UUID.init(uuidString:)) else { return nil }
                let state = try await service.contribution(productID: product, expectedOwnerID: context.ownerID)
                _ = try current(active, context: context, token: token)
                guard state.productID == product else { throw ProductAPIError.operationConflict }
                return try preparation(active, source: found, event: .observedOwnContribution(productID: state.productID.uuidString.lowercased(), currentRevision: state.currentRevision, currentState: Self.state(state.currentState)))
            }
            let request = try ProductShareDeliveryWorker.publishRequest(found)
            let result = try await service.resolvePublishForWithdrawal(request, expectedOwnerID: context.ownerID)
            _ = try current(active, context: context, token: token)
            let facts: ProductPublicationResolutionFacts
            switch result {
            case .committed(let receipt):
                guard receipt.operationID == found.operationID else { throw ProductAPIError.operationConflict }
                facts = .committed(productID: receipt.productID.uuidString.lowercased(), acknowledgedRevision: receipt.acknowledgedRevision,
                    currentRevision: receipt.currentRevision, currentState: Self.state(receipt.currentState))
            case .canceledBeforeCommit(let id, _):
                guard id == found.operationID else { throw ProductAPIError.operationConflict }
                facts = .canceledBeforeCommit
            }
            active = try preparation(active, source: found, event: .resolvedPublication(facts))
            // A canceled update still needs the authenticated state of the earlier contribution.
            if active.status == .pending, active.predecessorOperationID == found.operationID,
               case .canceledBeforeCommit = facts, let product = found.serverProductID.flatMap(UUID.init(uuidString:)) {
                let state = try await service.contribution(productID: product, expectedOwnerID: context.ownerID)
                _ = try current(active, context: context, token: token)
                guard state.productID == product else { throw ProductAPIError.operationConflict }
                active = try preparation(active, source: found, event: .observedOwnContribution(productID: state.productID.uuidString.lowercased(), currentRevision: state.currentRevision, currentState: Self.state(state.currentState)))
            }
            return active
        } catch is CancellationError { return nil }
        catch {
            guard valid(context, token), let source else { return nil }
            handle(error, operation: active, preparationSource: source, context: context, token: token)
            return nil
        }
    }
    private func preparation(_ operation: ProductShareOperation, source: ProductShareOperation, event: ProductWithdrawalPreparationEvent) throws -> ProductShareOperation {
        guard let epoch = operation.storeEpoch else { throw CustomProductStoreError.obsoleteOperation }
        return try store.recordProductWithdrawalPreparation(ProductWithdrawalPreparationUpdate(operationID: operation.operationID,
            ownerID: operation.ownerID, epoch: operation.epoch, storeEpoch: epoch, sourceOperationID: source.operationID, sourceEpoch: source.epoch, event: event))
    }
    private func send(_ operation: ProductShareOperation, context: ProductShareAccountContext, token: UUID) async {
        var active = operation
        do {
            _ = try current(active, context: context, token: token)
            let receipt: ProductDeliveryReceipt
            if active.kind == .publish {
                let request = try ProductShareDeliveryWorker.publishRequest(active)
                try record(active, status: .sending, envelope: try request.canonicalBody())
                active = try current(active, context: context, token: token)
                receipt = try await service.publish(request, expectedOwnerID: context.ownerID)
            } else {
                let request = try ProductShareDeliveryWorker.withdrawalRequest(active)
                try record(active, status: .sending, envelope: try request.canonicalBody())
                active = try current(active, context: context, token: token)
                receipt = try await service.withdraw(request, expectedOwnerID: context.ownerID)
            }
            _ = try current(active, context: context, token: token)
            guard receipt.operationID == active.operationID else { throw ProductAPIError.operationConflict }
            guard let epoch = active.storeEpoch else { throw CustomProductStoreError.obsoleteOperation }
            try store.recordProductDelivery(ProductDeliveryUpdate(operationID: active.operationID, ownerID: active.ownerID,
                epoch: active.epoch, storeEpoch: epoch, status: .acknowledged, serverProductID: receipt.productID.uuidString.lowercased(),
                acknowledgedRevision: receipt.acknowledgedRevision, currentRevision: receipt.currentRevision, currentState: Self.state(receipt.currentState)))
        } catch is CancellationError {
            if generation == token && accountContext == context { closeGate(reason: .unavailable) }
        }
        catch { handle(error, operation: active, preparationSource: nil, context: context, token: token) }
    }
    private func handle(_ error: Error, operation: ProductShareOperation, preparationSource: ProductShareOperation?, context: ProductShareAccountContext, token: UUID) {
        guard valid(context, token), (try? current(operation, context: context, token: token)) != nil else { return }
        let reason: ProductDeliveryReason
        var permanent = false
        var retryAfter: String?
        switch error as? ProductAPIError {
        case .unauthorized?, .ownerMismatch?: closeGate(reason: .authentication); return
        case .consentRequired?: reason = .consent; permanent = true
        case .invalidRequest?: reason = .invalidInput; permanent = true
        case .revisionConflict?, .operationConflict?: reason = .conflict; permanent = true
        case .rejected?: reason = .rejected; permanent = true
        case .unsupportedBackend?: closeGate(reason: .unavailable); return
        case .rateLimited(let value)?: reason = .rateLimited; retryAfter = value
        default:
            if error is CustomProductStoreError || error is DecodingError { reason = .invalidInput; permanent = true }
            else { reason = .network }
        }
        let attempt = preparationSource == nil ? operation.attempts : (operation.preparationAttempts ?? 1)
        let next = clock().addingTimeInterval(ProductShareDeliveryWorker.retryDelay(attempt: attempt, retryAfter: retryAfter, jitter: jitter))
        do {
            if let source = preparationSource {
                _ = try preparation(operation, source: source, event: permanent ? .stop(reason: reason) : .retry(reason: reason, nextAttemptAt: next))
            } else if operation.attempts > 0 || permanent {
                try record(operation, status: permanent ? ([ProductDeliveryReason.conflict, .rejected, .consent].contains(reason) ? .needsReview : .failed) : .pending,
                    reason: reason, next: permanent ? nil : next)
            } else { closeGate(reason: .unavailable) }
        } catch { storageFailed = true; closeGate(reason: .unavailable) }
    }
    private func record(_ operation: ProductShareOperation, status: ProductOperationStatus, envelope: Data? = nil,
                        reason: ProductDeliveryReason? = nil, next: Date? = nil) throws {
        guard let epoch = operation.storeEpoch else { throw CustomProductStoreError.obsoleteOperation }
        try store.recordProductDelivery(ProductDeliveryUpdate(operationID: operation.operationID, ownerID: operation.ownerID,
            epoch: operation.epoch, storeEpoch: epoch, status: status, envelope: envelope, reason: reason, nextAttemptAt: next))
    }
    private static func state(_ state: ProductContributionStatus) -> ProductAccountState { ProductAccountState(rawValue: state.rawValue)! }
}
