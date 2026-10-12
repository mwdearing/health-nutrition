import Foundation
import NutritionDomain
import SwiftData

public protocol CustomProductStore: AnyObject, Sendable {
    @discardableResult func saveCustomProduct(_ command: CustomProductSave, now: Date) throws -> CustomProductRevision
    func reconcileProductContribution(_ review: ProductContributionReview, publication: ProductShareOperation?) throws
    func enqueueProductOperation(_ operation: ProductShareOperation) throws
    @discardableResult func enqueueProductWithdrawal(_ operation: ProductShareOperation, expectedStoreEpoch: UUID) throws -> ProductShareOperation
    @discardableResult func recordProductWithdrawalPreparation(_ update: ProductWithdrawalPreparationUpdate) throws -> ProductShareOperation
    func customProducts() throws -> [CustomProductRevision]
    func dueProductOperations(ownerID: UUID, now: Date) throws -> [ProductShareOperation]
    /// Includes canceled attempted envelopes for deliberate reconciliation; never an automatic retry list.
    func productOperations(ownerID: UUID) throws -> [ProductShareOperation]
    func productAccountEpoch(ownerID: UUID) throws -> UUID?
    func recordProductDelivery(_ update: ProductDeliveryUpdate) throws
    func pauseProductOperations(ownerID: UUID) throws
    func resumeProductOperations(ownerID: UUID, fromEpoch: UUID, toEpoch: UUID) throws
    func cancelProductPublications(ownerID: UUID) throws
    func removeProductAccountState(ownerID: UUID) throws
}

public extension CustomProductStore {
    // Compatibility for hosts that do not provide durable contribution review.
    func reconcileProductContribution(_ review: ProductContributionReview, publication: ProductShareOperation?) throws {
        throw CustomProductStoreError.invalidOperation
    }
}

/// Existing journal entities retain their V6 model identities. V7 adds only standalone entities.
enum JournalSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }
    static var models: [any PersistentModel.Type] {
        JournalSchemaV6.models + [CustomProductRecord.self, CustomRevisionRecord.self, ProductAccountRecord.self, ProductOperationRecord.self]
    }
    @Model final class CustomProductRecord {
        var localProductID: UUID
        var currentRevisionID: UUID
        init(_ revision: CustomProductRevision) { localProductID = revision.localProductID; currentRevisionID = revision.revisionID }
    }
    @Model final class CustomRevisionRecord {
        var revisionID: UUID
        var payload: Data
        var createdAt: Date
        init(_ revision: CustomProductRevision, payload: Data, now: Date) {
            revisionID = revision.revisionID; self.payload = payload; createdAt = now
        }
    }
    @Model final class ProductAccountRecord {
        var ownerID: UUID
        var localProductID: UUID
        var epoch: UUID
        var storeEpoch: UUID
        var serverProductID: String?
        var currentRevision: String?
        var currentState: String
        var hasBarcodeBinding: Bool
        var barcode: String?
        init(_ operation: ProductShareOperation) {
            ownerID = operation.ownerID; localProductID = operation.localProductID; epoch = operation.epoch; storeEpoch = UUID()
            serverProductID = operation.serverProductID; currentRevision = operation.expectedServerRevision
            currentState = ProductAccountState.none.rawValue; hasBarcodeBinding = false
        }
    }
    @Model final class ProductOperationRecord {
        var operationID: UUID
        var ownerID: UUID
        var sequence: Int
        var payload: Data
        init(_ operation: ProductShareOperation, sequence: Int, payload: Data) {
            operationID = operation.operationID; ownerID = operation.ownerID; self.sequence = sequence; self.payload = payload
        }
    }
}

extension SwiftDataJournalStore: CustomProductStore {
    @discardableResult public func saveCustomProduct(_ command: CustomProductSave, now: Date) throws -> CustomProductRevision {
        try CustomProductValidation.validate(command.revision.content)
        return try commit { context in
            let revision = command.revision
            let products = try context.fetch(FetchDescriptor<JournalSchemaV7.CustomProductRecord>())
            let existing = products.first { $0.localProductID == revision.localProductID }
            guard existing?.currentRevisionID == command.expectedLocalRevision else { throw CustomProductStoreError.localRevisionConflict }
            guard try !context.fetch(FetchDescriptor<JournalSchemaV7.CustomRevisionRecord>()).contains(where: { $0.revisionID == revision.revisionID }) else {
                throw CustomProductStoreError.localRevisionConflict
            }
            let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>())
            for mapping in mappings where mapping.localProductID == revision.localProductID && mapping.hasBarcodeBinding {
                guard mapping.barcode == revision.content.barcode else { throw CustomProductStoreError.barcodeBindingRequiresReview }
            }
            if let existing { existing.currentRevisionID = revision.revisionID }
            else { context.insert(JournalSchemaV7.CustomProductRecord(revision)) }
            context.insert(JournalSchemaV7.CustomRevisionRecord(revision, payload: try JSONEncoder().encode(revision), now: now))
            if let draft = command.intake {
                guard UUID(uuidString: draft.snapshot.snapshotID) == revision.revisionID,
                      UUID(uuidString: draft.snapshot.productID) == revision.localProductID else { throw CustomProductStoreError.invalidOperation }
                _ = try insertIntake(draft.intake, components: draft.components, product: draft.snapshot, now: now, context: context)
            }
            if let publication = command.publication {
                guard publication.kind == .publish, publication.localProductID == revision.localProductID,
                      publication.clientRevisionID == revision.revisionID, publication.content == revision.content else { throw CustomProductStoreError.invalidOperation }
                try Self.enqueue(publication, in: context)
            }
            return revision
        }
    }

    public func customProducts() throws -> [CustomProductRevision] {
        let context = ModelContext(try openContainer())
        let products = try context.fetch(FetchDescriptor<JournalSchemaV7.CustomProductRecord>())
        let revisions = try context.fetch(FetchDescriptor<JournalSchemaV7.CustomRevisionRecord>())
        return try products.map { product in
            guard let row = revisions.first(where: { $0.revisionID == product.currentRevisionID }) else { throw JournalError.corruptRecord("custom revision") }
            return try JSONDecoder().decode(CustomProductRevision.self, from: row.payload)
        }.sorted { $0.localProductID.uuidString < $1.localProductID.uuidString }
    }

    public func reconcileProductContribution(_ review: ProductContributionReview, publication: ProductShareOperation?) throws {
        try commit { context in
            guard let productID = UUID(uuidString: review.serverProductID),
                  review.currentRevision == nil || Self.revisionNumber(review.currentRevision!),
                  (review.currentState == .none) == (review.currentRevision == nil) else { throw CustomProductStoreError.invalidOperation }
            let products = try context.fetch(FetchDescriptor<JournalSchemaV7.CustomProductRecord>())
            guard products.contains(where: { $0.localProductID == review.localProductID && $0.currentRevisionID == review.localRevisionID }) else { throw CustomProductStoreError.localRevisionConflict }
            let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>())
            guard let mapping = mappings.first(where: { $0.ownerID == review.ownerID && $0.localProductID == review.localProductID && $0.epoch == review.epoch && $0.storeEpoch == review.storeEpoch }),
                  mapping.serverProductID.flatMap(UUID.init(uuidString:)) == productID else { throw CustomProductStoreError.obsoleteOperation }
            if let known = mapping.currentRevision {
                guard let current = review.currentRevision, !Self.revisionAhead(known, current) else { throw CustomProductStoreError.obsoleteOperation }
            }
            let rows = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>()).filter { $0.ownerID == review.ownerID }.sorted { $0.sequence < $1.sequence }
            let reviewedChain = try rows.map(Self.operation).filter { $0.localProductID == review.localProductID && $0.storeEpoch == review.storeEpoch }
            guard reviewedChain.map(\.operationID) == review.expectedOperationIDs else { throw CustomProductStoreError.obsoleteOperation }
            guard let blocker = rows.first(where: { $0.operationID == review.blockingOperation.operationID }),
                  try Self.operation(blocker) == review.blockingOperation,
                  review.blockingOperation.localProductID == review.localProductID,
                  review.blockingOperation.storeEpoch == review.storeEpoch,
                  (Self.settled(review.blockingOperation) || [.failed, .needsReview].contains(review.blockingOperation.status)) else { throw CustomProductStoreError.obsoleteOperation }
            if Self.settled(review.blockingOperation) {
                guard reviewedChain.allSatisfy(Self.settled) else { throw CustomProductStoreError.obsoleteOperation }
            }
            if let publication {
                guard review.currentState != .rejected, publication.kind == .publish,
                      publication.ownerID == review.ownerID, publication.localProductID == review.localProductID,
                      publication.epoch == review.epoch, publication.clientRevisionID == review.localRevisionID else { throw CustomProductStoreError.invalidOperation }
            }
            for row in rows {
                var operation = try Self.operation(row)
                guard operation.localProductID == review.localProductID, operation.storeEpoch == review.storeEpoch,
                      !Self.settled(operation) else { continue }
                guard [.failed, .needsReview].contains(operation.status) ||
                      (operation.kind == .publish && operation.attempts == 0 && operation.envelope == nil &&
                       operation.serverProductID == nil && operation.expectedServerRevision == nil &&
                       operation.predecessorOperationID != nil && [.pending, .paused, .cancelled].contains(operation.status)) else { throw CustomProductStoreError.obsoleteOperation }
                operation.reviewSettlementID = review.id
                operation.reviewedCurrentState = review.currentState; operation.reviewedCurrentRevision = review.currentRevision
                if [.pending, .paused].contains(operation.status) { operation.status = .cancelled }
                row.payload = try JSONEncoder().encode(operation)
            }
            // Even a settled receipt can anchor an explicit review of newer server authority.
            // Only review metadata changes; the original receipt and request remain historical facts.
            var anchor = try Self.operation(blocker)
            anchor.reviewSettlementID = review.id
            anchor.reviewedCurrentState = review.currentState; anchor.reviewedCurrentRevision = review.currentRevision
            blocker.payload = try JSONEncoder().encode(anchor)
            mapping.currentRevision = review.currentRevision; mapping.currentState = review.currentState.rawValue
            if let publication { try Self.enqueue(publication, in: context) }
        }
    }

    public func enqueueProductOperation(_ operation: ProductShareOperation) throws {
        try commit { try Self.enqueue(operation, in: $0) }
    }

    private static func enqueue(_ input: ProductShareOperation, in context: ModelContext) throws {
        guard input.status == .pending, input.attempts == 0, input.envelope == nil,
              (input.kind == .publish) == (input.content != nil) else { throw CustomProductStoreError.invalidOperation }
        if let content = input.content {
            try CustomProductValidation.validate(content)
            guard input.consentVersion == 2, !input.consentGeneration.isEmpty,
                  input.consentGeneration.utf8.allSatisfy({ (48...57).contains($0) }) else { throw CustomProductStoreError.invalidOperation }
        }
        if let id = input.serverProductID, UUID(uuidString: id) == nil { throw CustomProductStoreError.invalidOperation }
        if let revision = input.expectedServerRevision, revision.isEmpty || !revision.utf8.allSatisfy({ (48...57).contains($0) }) { throw CustomProductStoreError.invalidOperation }
        let revisions = try context.fetch(FetchDescriptor<JournalSchemaV7.CustomRevisionRecord>())
        guard let revisionRow = revisions.first(where: { $0.revisionID == input.clientRevisionID }) else { throw CustomProductStoreError.invalidOperation }
        let revision = try JSONDecoder().decode(CustomProductRevision.self, from: revisionRow.payload)
        guard revision.localProductID == input.localProductID, input.content == nil || input.content == revision.content else { throw CustomProductStoreError.invalidOperation }
        let rows = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>()).sorted { $0.sequence < $1.sequence }
        guard !rows.contains(where: { $0.operationID == input.operationID }) else { throw CustomProductStoreError.invalidOperation }
        let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>())
        let mapping: JournalSchemaV7.ProductAccountRecord
        if let existing = mappings.first(where: { $0.ownerID == input.ownerID && $0.localProductID == input.localProductID }) {
            guard existing.epoch == input.epoch else { throw CustomProductStoreError.obsoleteOperation }
            if let requestedID = input.serverProductID, let boundID = existing.serverProductID,
               UUID(uuidString: requestedID) != UUID(uuidString: boundID) { throw CustomProductStoreError.invalidOperation }
            mapping = existing
        } else { mapping = JournalSchemaV7.ProductAccountRecord(input); context.insert(mapping) }
        if mapping.hasBarcodeBinding, let content = input.content, content.barcode != mapping.barcode { throw CustomProductStoreError.barcodeBindingRequiresReview }
        var operation = input
        operation.storeEpoch = mapping.storeEpoch
        var predecessor: ProductShareOperation?
        for row in rows where row.ownerID == input.ownerID {
            var previous = try Self.operation(row)
            guard previous.localProductID == input.localProductID else { continue }
            if previous.attempts == 0 && previous.kind == .publish && [.pending, .paused].contains(previous.status) && input.kind == .publish {
                previous.status = .cancelled
                row.payload = try JSONEncoder().encode(previous)
            } else if !Self.settled(previous) && (previous.attempts > 0 || previous.status != .cancelled) {
                predecessor = previous
            }
        }
        operation.predecessorOperationID = predecessor?.operationID
        if predecessor == nil {
            operation.serverProductID = mapping.serverProductID
            operation.expectedServerRevision = mapping.currentRevision
        } else {
            operation.serverProductID = nil; operation.expectedServerRevision = nil
        }
        context.insert(JournalSchemaV7.ProductOperationRecord(operation, sequence: (rows.last?.sequence ?? 0) + 1, payload: try JSONEncoder().encode(operation)))
    }

    private static func settled(_ operation: ProductShareOperation) -> Bool {
        operation.reviewSettlementID != nil || operation.status == .acknowledged || operation.status == .satisfied ||
            (operation.status == .cancelled && (operation.publicationResolution != nil ||
                (operation.kind == .publish && operation.attempts == 0 && operation.envelope == nil)))
    }

    /// Records explicit removal and cancels this product's publications in the same transaction.
    @discardableResult public func enqueueProductWithdrawal(_ input: ProductShareOperation, expectedStoreEpoch: UUID) throws -> ProductShareOperation {
        try commit { context in
            guard input.kind == .withdraw, input.content == nil, input.attempts == 0, input.envelope == nil,
                  input.status == .pending else { throw CustomProductStoreError.invalidOperation }
            let products = try context.fetch(FetchDescriptor<JournalSchemaV7.CustomProductRecord>())
            guard products.contains(where: { $0.localProductID == input.localProductID }) else { throw CustomProductStoreError.obsoleteOperation }
            let revisions = try context.fetch(FetchDescriptor<JournalSchemaV7.CustomRevisionRecord>())
            guard let revision = revisions.first(where: { $0.revisionID == input.clientRevisionID }),
                  try JSONDecoder().decode(CustomProductRevision.self, from: revision.payload).localProductID == input.localProductID else { throw CustomProductStoreError.invalidOperation }
            let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>())
            guard let mapping = mappings.first(where: { $0.ownerID == input.ownerID && $0.localProductID == input.localProductID && $0.epoch == input.epoch && $0.storeEpoch == expectedStoreEpoch }) else { throw CustomProductStoreError.obsoleteOperation }
            let rows = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>()).sorted { $0.sequence < $1.sequence }
            if let existing = rows.first(where: { $0.operationID == input.operationID }) {
                let saved = try Self.operation(existing)
                guard saved.ownerID == input.ownerID, saved.localProductID == input.localProductID,
                      saved.clientRevisionID == input.clientRevisionID, saved.kind == .withdraw,
                      saved.epoch == input.epoch, saved.storeEpoch == expectedStoreEpoch,
                      saved.consentVersion == input.consentVersion, saved.consentGeneration == input.consentGeneration,
                      input.serverProductID == nil || input.serverProductID == saved.serverProductID,
                      input.expectedServerRevision == nil || input.expectedServerRevision == saved.expectedServerRevision else { throw CustomProductStoreError.invalidOperation }
                return saved
            }
            var source: ProductShareOperation?
            for row in rows where row.ownerID == input.ownerID {
                var previous = try Self.operation(row)
                guard previous.localProductID == input.localProductID, previous.storeEpoch == expectedStoreEpoch else { continue }
                if previous.kind == .withdraw && !Self.settled(previous) { throw CustomProductStoreError.invalidOperation }
                if previous.kind == .publish && !Self.settled(previous) {
                    previous.status = .cancelled
                    row.payload = try JSONEncoder().encode(previous)
                    if previous.attempts > 0 && previous.publicationResolution == nil { source = previous }
                }
            }
            if let product = input.serverProductID {
                guard let id = UUID(uuidString: product), id == mapping.serverProductID.flatMap(UUID.init(uuidString:)) else { throw CustomProductStoreError.invalidOperation }
            }
            if let revision = input.expectedServerRevision, !Self.revisionNumber(revision) { throw CustomProductStoreError.invalidOperation }
            var withdrawal = input
            withdrawal.storeEpoch = expectedStoreEpoch
            withdrawal.predecessorOperationID = source?.operationID
            if source == nil {
                withdrawal.serverProductID = mapping.serverProductID
                withdrawal.expectedServerRevision = mapping.currentRevision
                withdrawal.currentRevision = mapping.currentRevision
                withdrawal.currentState = ProductAccountState(rawValue: mapping.currentState)
                if mapping.currentState == ProductAccountState.none.rawValue || mapping.currentState == ProductAccountState.withdrawn.rawValue {
                    withdrawal.status = .satisfied
                } else if let intended = input.expectedServerRevision, intended != mapping.currentRevision {
                    withdrawal.status = .needsReview; withdrawal.reason = .conflict
                }
            } else { withdrawal.serverProductID = nil; withdrawal.expectedServerRevision = nil }
            context.insert(JournalSchemaV7.ProductOperationRecord(withdrawal, sequence: (rows.last?.sequence ?? 0) + 1, payload: try JSONEncoder().encode(withdrawal)))
            return withdrawal
        }
    }

    /// Current intent/mapping grants mutation authority; its canceled source keeps its historical epoch.
    @discardableResult public func recordProductWithdrawalPreparation(_ update: ProductWithdrawalPreparationUpdate) throws -> ProductShareOperation {
        try commit { context in
            let rows = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>())
            guard let row = rows.first(where: { $0.operationID == update.operationID && $0.ownerID == update.ownerID }),
                  let sourceRow = rows.first(where: { $0.operationID == update.sourceOperationID && $0.ownerID == update.ownerID }) else { throw CustomProductStoreError.obsoleteOperation }
            var withdrawal = try Self.operation(row), source = try Self.operation(sourceRow)
            let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>())
            guard withdrawal.kind == .withdraw, withdrawal.epoch == update.epoch, withdrawal.storeEpoch == update.storeEpoch,
                  let mapping = mappings.first(where: { $0.ownerID == update.ownerID && $0.localProductID == withdrawal.localProductID && $0.epoch == update.epoch && $0.storeEpoch == update.storeEpoch }),
                  source.kind == .publish, source.status == .cancelled, source.attempts > 0,
                  source.envelope?.isEmpty == false, source.localProductID == withdrawal.localProductID,
                  source.storeEpoch == update.storeEpoch, source.epoch == update.sourceEpoch else { throw CustomProductStoreError.obsoleteOperation }
            // An exact duplicate resolution is harmless even after preparation has advanced. It never writes.
            if withdrawal.predecessorOperationID != source.operationID {
                switch update.event {
                case .resolvedPublication(.canceledBeforeCommit) where source.publicationResolution == .canceledBeforeCommit:
                    return withdrawal
                case .resolvedPublication(.committed(let product, let acknowledged, let current, let state))
                    where source.publicationResolution == .committed && source.acknowledgedProductID == product && source.acknowledgedRevision == acknowledged && source.currentRevision == current && source.currentState == state:
                    return withdrawal
                default: throw CustomProductStoreError.obsoleteOperation
                }
            }
            guard withdrawal.status == .pending, withdrawal.attempts == 0, withdrawal.envelope == nil else { throw CustomProductStoreError.obsoleteOperation }
            switch update.event {
            case .beginAttempt:
                withdrawal.preparationAttempts = (withdrawal.preparationAttempts ?? 0) + 1
                withdrawal.nextAttemptAt = nil
            case .retry(let reason, let date):
                guard [.network, .rateLimited, .unavailable].contains(reason) else { throw CustomProductStoreError.invalidOperation }
                withdrawal.reason = reason; withdrawal.nextAttemptAt = date
            case .stop(let reason):
                withdrawal.status = [.conflict, .rejected, .consent].contains(reason) ? .needsReview : .failed
                withdrawal.reason = reason; withdrawal.nextAttemptAt = nil
            case .resolvedPublication(.committed(let product, let acknowledged, let current, let state)):
                guard source.publicationResolution == nil || source.publicationResolution == .committed,
                      Self.revisionNumber(acknowledged), Self.revisionNumber(current), !Self.revisionAhead(acknowledged, current), state != .none,
                      source.serverProductID == nil || UUID(uuidString: source.serverProductID!) == UUID(uuidString: product),
                      source.acknowledgedRevision == nil || source.acknowledgedRevision == acknowledged,
                      source.acknowledgedProductID == nil || source.acknowledgedProductID == product else { throw CustomProductStoreError.invalidOperation }
                try Self.applyWithdrawalFacts(product: product, current: current, state: state, intended: acknowledged, withdrawal: &withdrawal, mapping: mapping)
                source.publicationResolution = .committed; source.acknowledgedProductID = product
                source.acknowledgedRevision = acknowledged; source.currentRevision = current; source.currentState = state
            case .resolvedPublication(.canceledBeforeCommit):
                guard source.publicationResolution == nil || source.publicationResolution == .canceledBeforeCommit else { throw CustomProductStoreError.invalidOperation }
                source.publicationResolution = .canceledBeforeCommit
                if source.serverProductID == nil {
                    // Walk the retained lineage: an unattempted edit is not proof that no older send happened.
                    var predecessor = source.predecessorOperationID
                    var visited = Set<UUID>()
                    var unresolved: ProductShareOperation?
                    while let id = predecessor {
                        guard visited.insert(id).inserted, let ancestorRow = rows.first(where: { $0.operationID == id }) else { throw CustomProductStoreError.invalidOperation }
                        let ancestor = try Self.operation(ancestorRow)
                        guard ancestor.ownerID == source.ownerID, ancestor.localProductID == source.localProductID, ancestor.storeEpoch == source.storeEpoch else { throw CustomProductStoreError.invalidOperation }
                        if ancestor.kind == .publish && ancestor.attempts > 0 && ancestor.publicationResolution == nil && !Self.settled(ancestor) { unresolved = ancestor; break }
                        predecessor = ancestor.predecessorOperationID
                    }
                    if let unresolved { withdrawal.predecessorOperationID = unresolved.operationID }
                    else if mapping.currentState == ProductAccountState.none.rawValue {
                        withdrawal.status = .satisfied; withdrawal.currentState = ProductAccountState.none
                        withdrawal.predecessorOperationID = nil; withdrawal.nextAttemptAt = nil; withdrawal.reason = nil
                    } else { withdrawal.status = .needsReview; withdrawal.reason = .conflict }
                }
            case .observedOwnContribution(let product, let current, let state):
                guard source.publicationResolution == .canceledBeforeCommit, source.serverProductID != nil,
                      UUID(uuidString: source.serverProductID!) == UUID(uuidString: product) else { throw CustomProductStoreError.invalidOperation }
                try Self.applyWithdrawalFacts(product: product, current: current, state: state, intended: source.expectedServerRevision, withdrawal: &withdrawal, mapping: mapping)
            }
            sourceRow.payload = try JSONEncoder().encode(source)
            row.payload = try JSONEncoder().encode(withdrawal)
            if withdrawal.status == .satisfied {
                for successorRow in rows {
                    var successor = try Self.operation(successorRow)
                    guard successor.ownerID == withdrawal.ownerID, successor.localProductID == withdrawal.localProductID,
                          successor.predecessorOperationID == withdrawal.operationID, successor.attempts == 0,
                          successor.envelope == nil, [.pending, .paused].contains(successor.status) else { continue }
                    successor.predecessorOperationID = nil; successor.serverProductID = mapping.serverProductID
                    successor.expectedServerRevision = mapping.currentRevision
                    successorRow.payload = try JSONEncoder().encode(successor)
                }
            }
            return withdrawal
        }
    }

    private static func revisionNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && value.first != "0"
    }
    private static func revisionAhead(_ first: String, _ second: String) -> Bool {
        first.utf8.count != second.utf8.count ? first.utf8.count > second.utf8.count : first > second
    }
    private static func applyWithdrawalFacts(product: String, current: String?, state: ProductAccountState,
                                            intended: String?, withdrawal: inout ProductShareOperation,
                                            mapping: JournalSchemaV7.ProductAccountRecord) throws {
        guard UUID(uuidString: product) != nil, (state == .none) == (current == nil),
              current == nil || revisionNumber(current!),
              mapping.serverProductID == nil || UUID(uuidString: mapping.serverProductID!) == UUID(uuidString: product) else { throw CustomProductStoreError.invalidOperation }
        if let known = mapping.currentRevision, let current, revisionAhead(known, current) {
            withdrawal.currentRevision = known; withdrawal.currentState = ProductAccountState(rawValue: mapping.currentState)
            withdrawal.status = .needsReview; withdrawal.reason = .conflict
            return
        }
        mapping.serverProductID = product; mapping.currentRevision = current; mapping.currentState = state.rawValue
        withdrawal.serverProductID = product; withdrawal.currentRevision = current; withdrawal.currentState = state
        withdrawal.nextAttemptAt = nil; withdrawal.reason = nil
        if state == .none || state == .withdrawn {
            withdrawal.status = .satisfied; withdrawal.predecessorOperationID = nil
        } else if current == intended {
            // Rejected is still an own contribution: explicit removal at the intended revision is allowed.
            withdrawal.expectedServerRevision = current; withdrawal.predecessorOperationID = nil
        } else { withdrawal.status = .needsReview; withdrawal.reason = .conflict }
    }

    public func productAccountEpoch(ownerID: UUID) throws -> UUID? {
        let context = ModelContext(try openContainer())
        let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>()).filter { $0.ownerID == ownerID }
        guard let epoch = mappings.first?.epoch else { return nil }
        guard mappings.allSatisfy({ $0.epoch == epoch }) else { throw CustomProductStoreError.obsoleteOperation }
        return epoch
    }

    public func productOperations(ownerID: UUID) throws -> [ProductShareOperation] {
        let context = ModelContext(try openContainer())
        return try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>()).filter { $0.ownerID == ownerID }
            .sorted { $0.sequence < $1.sequence }.map(Self.operation)
    }

    public func dueProductOperations(ownerID: UUID, now: Date) throws -> [ProductShareOperation] {
        try productOperations(ownerID: ownerID).filter {
            $0.status == .pending && $0.predecessorOperationID == nil && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
        }
    }

    public func recordProductDelivery(_ update: ProductDeliveryUpdate) throws {
        try commit { context in
            let rows = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>())
            guard let row = rows.first(where: { $0.operationID == update.operationID && $0.ownerID == update.ownerID }) else { throw CustomProductStoreError.obsoleteOperation }
            var operation = try Self.operation(row)
            guard operation.epoch == update.epoch, operation.storeEpoch == update.storeEpoch, ![.cancelled, .acknowledged, .satisfied, .failed, .needsReview].contains(operation.status) else { throw CustomProductStoreError.obsoleteOperation }
            let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>())
            guard let mapping = mappings.first(where: { $0.ownerID == update.ownerID && $0.localProductID == operation.localProductID && $0.epoch == update.epoch && $0.storeEpoch == update.storeEpoch }) else { throw CustomProductStoreError.obsoleteOperation }
            if update.status == .sending {
                guard operation.status == .pending, operation.predecessorOperationID == nil,
                      let envelope = update.envelope, !envelope.isEmpty, envelope.count <= 16_384 else { throw CustomProductStoreError.invalidOperation }
                if let old = operation.envelope, old != envelope { throw CustomProductStoreError.immutableEnvelope }
                if let id = update.serverProductID, id != operation.serverProductID { throw CustomProductStoreError.immutableEnvelope }
                if let cas = update.expectedServerRevision, cas != operation.expectedServerRevision { throw CustomProductStoreError.immutableEnvelope }
                if operation.kind == .withdraw && (operation.serverProductID == nil || operation.expectedServerRevision == nil) { throw CustomProductStoreError.invalidOperation }
                operation.envelope = envelope; operation.attempts += 1
                if let content = operation.content { mapping.hasBarcodeBinding = true; mapping.barcode = content.barcode }
            } else if operation.attempts == 0 {
                guard operation.status == .pending, operation.envelope == nil,
                      [.failed, .needsReview].contains(update.status),
                      let reason = update.reason, [.invalidInput, .consent, .conflict, .rejected].contains(reason),
                      update.envelope == nil, update.serverProductID == nil, update.expectedServerRevision == nil,
                      update.acknowledgedRevision == nil, update.currentRevision == nil, update.currentState == nil,
                      update.nextAttemptAt == nil else { throw CustomProductStoreError.invalidOperation }
            } else {
                guard update.envelope == nil,
                      operation.status == .sending || operation.status == .pending else { throw CustomProductStoreError.obsoleteOperation }
            }
            if update.status == .acknowledged {
                guard let productID = update.serverProductID, UUID(uuidString: productID) != nil,
                      let acknowledged = update.acknowledgedRevision, let current = update.currentRevision,
                      let state = update.currentState,
                      operation.serverProductID == nil || UUID(uuidString: operation.serverProductID!) == UUID(uuidString: productID) else { throw CustomProductStoreError.invalidOperation }
                mapping.serverProductID = productID; mapping.currentRevision = current; mapping.currentState = state.rawValue
                if let content = operation.content { mapping.hasBarcodeBinding = true; mapping.barcode = content.barcode }
                operation.acknowledgedProductID = productID; operation.acknowledgedRevision = acknowledged; operation.currentRevision = current; operation.currentState = state
                // Current state may be ahead after a replay. Never automatically rebase an offline edit.
                for successorRow in rows {
                    var successor = try Self.operation(successorRow)
                    guard successor.ownerID == operation.ownerID, successor.predecessorOperationID == operation.operationID,
                          successor.attempts == 0, successor.envelope == nil, [.pending, .paused].contains(successor.status) else { continue }
                    if current != acknowledged || state == .rejected { successor.status = .needsReview; successor.reason = .conflict }
                    else {
                        successor.predecessorOperationID = nil; successor.serverProductID = productID; successor.expectedServerRevision = current
                    }
                    successorRow.payload = try JSONEncoder().encode(successor)
                }
            }
            operation.status = update.status; operation.reason = update.reason; operation.nextAttemptAt = update.nextAttemptAt
            row.payload = try JSONEncoder().encode(operation)
        }
    }

    public func pauseProductOperations(ownerID: UUID) throws {
        try mutateProductOperations(ownerID: ownerID) { operation in
            if [.pending, .sending].contains(operation.status) { operation.status = .paused }
        }
    }
    /// A sign-in controller must validate the live owner before calling. Both generations are checked
    /// on persisted rows; a stale resume after account removal or erase cannot recreate anything.
    public func resumeProductOperations(ownerID: UUID, fromEpoch: UUID, toEpoch: UUID) throws {
        guard fromEpoch != toEpoch else { throw CustomProductStoreError.obsoleteOperation }
        try commit { context in
            let mappings = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>()).filter { $0.ownerID == ownerID }
            guard !mappings.isEmpty, mappings.allSatisfy({ $0.epoch == fromEpoch }) else { throw CustomProductStoreError.obsoleteOperation }
            let rows = try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>())
            for row in rows where row.ownerID == ownerID {
                var operation = try Self.operation(row)
                guard operation.epoch == fromEpoch, operation.status == .paused,
                      let mapping = mappings.first(where: { $0.localProductID == operation.localProductID }),
                      operation.storeEpoch == mapping.storeEpoch else { continue }
                operation.epoch = toEpoch; operation.status = .pending
                row.payload = try JSONEncoder().encode(operation)
            }
            for mapping in mappings { mapping.epoch = toEpoch }
        }
    }
    public func cancelProductPublications(ownerID: UUID) throws {
        try mutateProductOperations(ownerID: ownerID) { operation in
            if operation.kind == .publish && !Self.settled(operation) { operation.status = .cancelled }
        }
    }
    private func mutateProductOperations(ownerID: UUID, _ body: (inout ProductShareOperation) -> Void) throws {
        try commit { context in
            for row in try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>()) where row.ownerID == ownerID {
                var operation = try Self.operation(row); body(&operation); row.payload = try JSONEncoder().encode(operation)
            }
        }
    }
    public func removeProductAccountState(ownerID: UUID) throws {
        try commit { context in
            for row in try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>()) where row.ownerID == ownerID { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<JournalSchemaV7.ProductAccountRecord>()) where row.ownerID == ownerID { context.delete(row) }
        }
    }
    func recoverProductOperations() throws {
        try commit { context in
            for row in try context.fetch(FetchDescriptor<JournalSchemaV7.ProductOperationRecord>()) {
                var operation = try Self.operation(row)
                if operation.status == .sending { operation.status = .pending; row.payload = try JSONEncoder().encode(operation) }
            }
        }
    }
    private static func operation(_ row: JournalSchemaV7.ProductOperationRecord) throws -> ProductShareOperation {
        try JSONDecoder().decode(ProductShareOperation.self, from: row.payload)
    }
}
