import Foundation
import NutritionDomain
import SwiftData

public protocol CustomProductStore: AnyObject, Sendable {
    @discardableResult func saveCustomProduct(_ command: CustomProductSave, now: Date) throws -> CustomProductRevision
    func enqueueProductOperation(_ operation: ProductShareOperation) throws
    func customProducts() throws -> [CustomProductRevision]
    func dueProductOperations(ownerID: UUID, now: Date) throws -> [ProductShareOperation]
    /// Includes canceled attempted envelopes for deliberate reconciliation; never an automatic retry list.
    func productOperations(ownerID: UUID) throws -> [ProductShareOperation]
    func recordProductDelivery(_ update: ProductDeliveryUpdate) throws
    func pauseProductOperations(ownerID: UUID) throws
    func resumeProductOperations(ownerID: UUID, fromEpoch: UUID, toEpoch: UUID) throws
    func cancelProductPublications(ownerID: UUID) throws
    func removeProductAccountState(ownerID: UUID) throws
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
            } else if previous.status != .acknowledged && (previous.attempts > 0 || previous.status != .cancelled) {
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
            guard operation.epoch == update.epoch, operation.storeEpoch == update.storeEpoch, ![.cancelled, .acknowledged].contains(operation.status) else { throw CustomProductStoreError.obsoleteOperation }
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
            } else {
                guard update.envelope == nil, operation.attempts > 0,
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
                    guard successor.ownerID == operation.ownerID, successor.predecessorOperationID == operation.operationID else { continue }
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
            if operation.kind == .publish && operation.status != .acknowledged { operation.status = .cancelled }
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
