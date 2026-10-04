import Foundation
import NutritionDomain
import SwiftData

enum JournalSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
        }
    }

    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
        }
    }
}

/// The nutrient values a product snapshot carries, added as one optional column. V1 above is kept
/// exactly as the first build wrote it, so a store that build created still has a schema SwiftData can
/// migrate from; a row that has no nutrient payload reads back as a product that states none.
enum JournalSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
        }
    }

    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String
        /// JSON of the nutrient values the product states, sorted by id.
        var nutrientsJSON: String?

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String, nutrientsJSON: String? = nil
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
            self.nutrientsJSON = nutrientsJSON
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
        }
    }
}

/// The store is written with V2. The stage is lightweight because the only change is one optional column,
/// so an existing file is migrated in place and its rows keep their values.
enum JournalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [JournalSchemaV1.self, JournalSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: JournalSchemaV1.self, toVersion: JournalSchemaV2.self)]
    }
}

typealias IntakeRecord = JournalSchemaV2.IntakeRecord
typealias RevisionRecord = JournalSchemaV2.RevisionRecord
typealias ProductRecord = JournalSchemaV2.ProductRecord
typealias ProjectionRecord = JournalSchemaV2.ProjectionRecord
typealias OutboxRecord = JournalSchemaV2.OutboxRecord

private struct StoredComponent: Codable {
    var componentID: String
    var name: String
    var amountText: String
    var unitSymbol: String
}

/// One stored nutrient value: the state, plus the amount and unit of a known value. Every decimal is
/// POSIX text, so a value survives a round trip exactly. A state this build does not know is stored
/// as written and reads back as unknown, never as zero.
private struct StoredNutrient: Codable {
    var id: String
    var state: String
    var valueText: String?
    var unitSymbol: String?
}

public final class SwiftDataJournalStore: JournalOutboxDelivery, JournalSnapshotSource,
    JournalTombstoneSource, JournalRestoreTarget, JournalErasing, @unchecked Sendable
{
    private let lock = NSLock()
    /// Serializes whole writes so two edits never read the same current revision. Separate from `lock`.
    private let writeLock = NSLock()
    private var failFlag = false
    private var container: ModelContainer?
    private let enabledDestinations: Set<JournalDestination>

    public var failNextSaveForTesting: Bool {
        get { lock.withLock { failFlag } }
        set { lock.withLock { failFlag = newValue } }
    }

    /// Opens or creates the store file at `url`. Destinations not in `enabledDestinations` get a
    /// disabled projection and no outbox operation.
    public init(url: URL, enabledDestinations: Set<JournalDestination> = [.healthKit, .relay]) throws {
        self.enabledDestinations = enabledDestinations
        let schema = Schema(versionedSchema: JournalSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(
            for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    public func close() {
        lock.withLock { container = nil }
    }

    /// Opens a store with the first released schema, so a test can write a file the current one has to
    /// migrate. Nothing in the app opens a store this way.
    static func legacyStoreForTesting(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: JournalSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    /// Writes one revision with the V1 model, exactly as the first build did, and commits it.
    static func writeLegacyRevisionForTesting(
        url: URL, intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws {
        let context = ModelContext(try legacyStoreForTesting(url: url))
        context.autosaveEnabled = false
        let componentsJSON = try encode(components)
        context.insert(JournalSchemaV1.IntakeRecord(
            intakeID: intake.id, category: intake.category, occurredAt: intake.occurredAt,
            timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
            lifecycleRaw: intake.lifecycle.rawValue, currentRevision: 1))
        if let product {
            context.insert(JournalSchemaV1.ProductRecord(
                snapshotID: product.snapshotID, productID: product.productID, name: product.name,
                brand: product.brand, barcode: product.barcode, labelBasis: product.labelBasis,
                catalogOrigin: product.catalogOrigin, catalogVersion: product.catalogVersion))
        }
        context.insert(JournalSchemaV1.RevisionRecord(
            intakeID: intake.id, number: 1, componentsJSON: componentsJSON,
            productSnapshotID: product?.snapshotID, changeReason: "created", createdAt: now))
        try context.save()
    }

    /// Drops a stored snapshot's nutrient values, leaving the row as a store written before the column
    /// existed would have it.
    func clearNutrientsOnSnapshotForTesting(snapshotID: String) throws {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID }))
        guard let row = rows.first else { throw JournalError.corruptRecord(snapshotID) }
        row.nutrientsJSON = nil
        try context.save()
    }

    private func openContainer() throws -> ModelContainer {
        try lock.withLock {
            guard let container else { throw JournalError.closed }
            return container
        }
    }

    private func takeInjectedFailure() -> Bool {
        lock.withLock {
            let flag = failFlag
            failFlag = false
            return flag
        }
    }

    /// Runs `body` on a fresh context and saves once. Any failure rolls the context back.
    private func commit<T>(_ body: (ModelContext) throws -> T) throws -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        context.autosaveEnabled = false
        do {
            let result = try body(context)
            if takeInjectedFailure() {
                throw JournalError.injectedSaveFailure
            }
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: Writes

    @discardableResult
    public func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision {
        guard JournalValidation.isValidIntakeID(intake.id) else { throw JournalError.invalidIntakeID(intake.id) }
        let json = try Self.encode(components)
        return try commit { context in
            if try Self.intakeRecord(intake.id, in: context) != nil {
                throw JournalError.intakeAlreadyExists(intake.id)
            }
            context.insert(IntakeRecord(
                intakeID: intake.id, category: intake.category, occurredAt: intake.occurredAt,
                timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
                lifecycleRaw: IntakeLifecycle.active.rawValue, currentRevision: 1))
            return try appendRevision(
                intakeID: intake.id, number: 1, componentsJSON: json, components: components,
                product: product, changeReason: "created", now: now, context: context)
        }
    }

    @discardableResult
    public func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String, now: Date
    ) throws -> IntakeRevision {
        let json = try Self.encode(components)
        return try commit { context in
            guard let record = try Self.intakeRecord(intakeID, in: context) else {
                throw JournalError.unknownIntake(intakeID)
            }
            guard record.lifecycleRaw == IntakeLifecycle.active.rawValue else {
                throw JournalError.intakeDeleted(intakeID)
            }
            let number = record.currentRevision + 1
            record.currentRevision = number
            try Self.supersedeProjections(of: intakeID, in: context)
            return try appendRevision(
                intakeID: intakeID, number: number, componentsJSON: json, components: components,
                product: product, changeReason: changeReason, now: now, context: context)
        }
    }

    public func delete(intakeID: String, now: Date) throws {
        try commit { context in
            guard let record = try Self.intakeRecord(intakeID, in: context) else {
                throw JournalError.unknownIntake(intakeID)
            }
            guard record.lifecycleRaw == IntakeLifecycle.active.rawValue else {
                throw JournalError.intakeDeleted(intakeID)
            }
            record.lifecycleRaw = IntakeLifecycle.deleted.rawValue
            try Self.supersedeProjections(of: intakeID, in: context)
            let revision = record.currentRevision
            queueWork(intakeID: intakeID, revision: revision, kind: .delete, payload: "delete:\(intakeID):\(revision)", context: context)
        }
    }

    // MARK: Restore

    /// Writes the whole plan in one save: the product snapshots, every intake with all of its revisions,
    /// and the tombstones of deleted entries.
    ///
    /// No projection and no outbox operation is written. A restored entry is history the destinations
    /// have already been sent once, so queueing it would deliver it a second time just because a phone
    /// was replaced. That is also why this is separate from `create`: creating an entry means the person
    /// just ate something and it must reach Health, and importing one means they ate it weeks ago.
    ///
    /// The emptiness check is inside this closure, so it is read and the rows are written under one write
    /// lock. A separate check before the save would leave a window in which another write creates an entry
    /// and the restore joins it, which is the merge this refuses.
    public func restore(_ plan: JournalRestorePlan) throws -> JournalRestoreReceipt {
        try commit { context in
            guard try context.fetchCount(FetchDescriptor<IntakeRecord>()) == 0 else {
                throw JournalImportError.notEmpty
            }
            var restored: [JournalRestoredIntake] = []
            var insertedProducts: [String] = []
            for product in plan.products {
                if try Self.restoreSnapshot(product, in: context) {
                    insertedProducts.append(product.snapshotID)
                }
            }
            for entry in plan.entries {
                let intake = entry.intake
                context.insert(IntakeRecord(
                    intakeID: intake.id, category: intake.category, occurredAt: intake.occurredAt,
                    timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
                    lifecycleRaw: IntakeLifecycle.active.rawValue, currentRevision: intake.currentRevision))
                for revision in entry.revisions {
                    context.insert(RevisionRecord(
                        intakeID: intake.id, number: revision.number,
                        componentsJSON: try Self.encode(revision.components),
                        productSnapshotID: revision.productSnapshotID, changeReason: revision.changeReason,
                        createdAt: revision.createdAt))
                }
                restored.append(
                    JournalRestoredIntake(
                        intakeID: intake.id, lifecycle: .active, currentRevision: intake.currentRevision,
                        revisionNumbers: entry.revisions.map(\.number)))
            }
            for tombstone in plan.tombstones {
                // A tombstone has no revision row: the export carries the revision number it was deleted
                // at, not the amounts it held then, and a deleted entry is never shown or repeated.
                context.insert(IntakeRecord(
                    intakeID: tombstone.id, category: tombstone.category, occurredAt: tombstone.occurredAt,
                    timeZoneIdentifier: tombstone.timeZoneIdentifier, meal: tombstone.meal,
                    note: tombstone.note, lifecycleRaw: IntakeLifecycle.deleted.rawValue,
                    currentRevision: tombstone.currentRevision))
                restored.append(
                    JournalRestoredIntake(
                        intakeID: tombstone.id, lifecycle: .deleted,
                        currentRevision: tombstone.currentRevision, revisionNumbers: []))
            }
            return JournalRestoreReceipt(intakes: restored, insertedProductSnapshotIDs: insertedProducts)
        }
    }

    /// Removes the rows a restore inserted, so a later step of the same import can be undone.
    ///
    /// This is compensation, not a reset, and it is deliberately narrow. An intake the restore wrote is only
    /// removed while it still looks exactly as the restore left it: same lifecycle, same current revision. A
    /// write that landed in between - an edit that added a revision, a delete that hid the entry - means
    /// those rows are no longer only the restore's, and removing them would throw the person's work away to
    /// make the journal look empty. So the undo refuses instead, and the importer says the import could not
    /// be put back. Revisions go one number at a time for the same reason. Product rows are removed only for
    /// the snapshots this restore created; nothing else writes one, so nothing else can be caught by it.
    public func undoRestore(_ receipt: JournalRestoreReceipt) throws {
        try commit { context in
            for restored in receipt.intakes {
                // Copied out of the receipt first: a #Predicate may compare a key path of the iterated model
                // only against plain values, not against a property read from a different object. The same
                // rule the delivery bookkeeping below follows for the same reason.
                let intakeID = restored.intakeID
                guard let record = try Self.intakeRecord(intakeID, in: context) else {
                    throw JournalImportError.corrupt(
                        "the entry \(intakeID) is gone already, so the import cannot be undone")
                }
                guard record.lifecycleRaw == restored.lifecycle.rawValue,
                      record.currentRevision == restored.currentRevision
                else {
                    throw JournalImportError.corrupt(
                        "the entry \(intakeID) was written to after the import restored it, "
                            + "so undoing the import would throw that away too")
                }
                for number in restored.revisionNumbers {
                    for row in try context.fetch(FetchDescriptor<RevisionRecord>(
                        predicate: #Predicate<RevisionRecord> { $0.intakeID == intakeID && $0.number == number })) {
                        context.delete(row)
                    }
                }
                context.delete(record)
            }
            for snapshotID in receipt.insertedProductSnapshotIDs {
                for row in try context.fetch(FetchDescriptor<ProductRecord>(
                    predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID })) {
                    context.delete(row)
                }
            }
        }
    }

    /// Writes one product snapshot for a restore, and reports whether it created the row.
    ///
    /// A document records which product a revision used and where it came from, not the nutrient values
    /// that product states, so a restored snapshot brings no values of its own. Where this store already
    /// knows the snapshot, its values are the better ones: they are what the journal was reading before the
    /// restore, so they are kept exactly and an import cannot quietly empty them.
    ///
    /// Two rows under one snapshot id may therefore differ only in that one respect, and only when one of
    /// them states no values: the stored row's values win when it has any, and a stored row with none is
    /// filled in from the plan. The product's identity always has to match, and two sets of values that
    /// disagree are a conflict rather than a preference, because one snapshot id cannot name two products
    /// that state different things. Only a row this restore created is listed in the receipt for
    /// `undoRestore` to remove.
    @discardableResult
    private static func restoreSnapshot(_ product: ProductDefinition, in context: ModelContext) throws -> Bool {
        let id = product.snapshotID
        let existing = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == id }))
        guard let row = existing.first else {
            context.insert(ProductRecord(
                snapshotID: product.snapshotID, productID: product.productID, name: product.name,
                brand: product.brand, barcode: product.barcode, labelBasis: product.labelBasis,
                catalogOrigin: product.catalogOrigin, catalogVersion: product.catalogVersion,
                nutrientsJSON: Self.encodeNutrients(product.nutrients)))
            return true
        }
        let stored = snapshot(from: row)
        guard stored.withNutrients([:]) == product.withNutrients([:]) else {
            throw JournalError.snapshotConflict(id)
        }
        // The values are compared as decoded `[String: NutrientValue]`, never as the stored JSON text, so
        // key order, the spelling of a decimal and an absent dictionary cannot make two equal sets look
        // different.
        //
        // A plan that states no values at all is the everyday case: a document carries a product's identity
        // and origin, not what it states, so every snapshot built from one arrives with an empty dictionary.
        // That is not a disagreement with the values this store holds - it is the absence of an opinion -
        // and treating it as one refused every restore into a store that already knew the product. Only two
        // sets that both state values and differ are a conflict, because one snapshot id cannot name two
        // products that state different things.
        guard !product.nutrients.isEmpty, stored.nutrients != product.nutrients else { return false }
        guard stored.nutrients.isEmpty else { throw JournalError.snapshotConflict(id) }
        row.nutrientsJSON = Self.encodeNutrients(product.nutrients)
        return false
    }

    /// Writes one product snapshot with no intake, the way a store that already knew a product would hold
    /// it. Only tests use this; nothing in the app writes a snapshot on its own.
    func insertProductSnapshotForTesting(_ product: ProductDefinition) throws {
        let context = ModelContext(try openContainer())
        context.autosaveEnabled = false
        try Self.insertSnapshot(product, in: context)
        try context.save()
    }

    // MARK: Erasing

    /// Removes every row the journal file holds: intakes, their revision history, product snapshots,
    /// projections and queued outbox operations. A deleted entry leaves no tombstone behind either,
    /// because a tombstone only exists so a later export can retract the entry.
    ///
    /// The rows are fetched and deleted one at a time rather than with the batch delete, which runs
    /// against the persistent store immediately, outside the save and outside the rollback. Fetching
    /// keeps the whole erase inside one commit, so a failure anywhere in it leaves the journal exactly
    /// as it was: a journal emptied by a failed save would be worse than an unerased one, because the
    /// person cannot tell which half is gone.
    ///
    /// The container is not closed: the store reads empty and accepts new entries afterwards.
    public func eraseAll() throws {
        _ = try commit { context in
            for row in try context.fetch(FetchDescriptor<RevisionRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<OutboxRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<ProjectionRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<ProductRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<IntakeRecord>()) { context.delete(row) }
        }
    }

    // MARK: Delivery bookkeeping

    /// Marks one operation delivered and its projection `succeeded`, in one save.
    ///
    /// Acknowledging an operation that is already acknowledged is not an error: a worker that
    /// crashed after writing but before recording the delivery will deliver again, and that second
    /// delivery has to be recordable rather than refused.
    public func acknowledge(operationID: String, at date: Date) throws {
        try commit { context in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            guard row.acknowledgedAt == nil else { return }
            row.acknowledgedAt = date
            row.nextAttemptAt = nil
            try Self.setProjectionState(
                .succeeded, of: row, in: context)
        }
    }

    /// Records one failed attempt: `attempts` grows by one, and the operation is due again at
    /// `retryAt` unless the failure needs a person, in which case the projection becomes
    /// `needsAttention` and no automatic retry is scheduled.
    ///
    /// An acknowledged operation is left alone: it was delivered, so a failure recorded afterwards
    /// belongs to a different attempt and must not reopen it.
    public func recordFailure(operationID: String, retryAt: Date?, needsAttention: Bool) throws {
        try commit { context in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            guard row.acknowledgedAt == nil else { return }
            row.attempts += 1
            row.nextAttemptAt = retryAt
            try Self.setProjectionState(needsAttention ? .needsAttention : .pending, of: row, in: context)
        }
    }

    private static func outboxRecord(_ operationID: String, in context: ModelContext) throws -> OutboxRecord? {
        try context.fetch(FetchDescriptor<OutboxRecord>(
            predicate: #Predicate<OutboxRecord> { $0.operationID == operationID })).first
    }

    /// The pending operations a worker must not retry on its own.
    ///
    /// Read through the projections rather than inferred from the operations, because `nil` on
    /// `nextAttemptAt` means both "do not retry" (suspended) and "due now" (first attempt). Only the
    /// projection records which one it is.
    ///
    /// **A suspension outlives the projection becoming noncurrent.** An edit supersedes the previous
    /// projections but leaves their outbox operations pending, so a denied revision 1 whose projection
    /// has just been marked noncurrent is still an undelivered, suspended operation. Filtering on
    /// `isCurrent` here would drop it, and every later run would retry the denied write, grow its
    /// attempt count and block the newer revision indefinitely. Each `needsAttention` projection is
    /// therefore matched to its operation whatever its currency, because the projection still names
    /// the one operation it belongs to.
    public func suspendedOperationIDs() throws -> Set<String> {
        let context = ModelContext(try openContainer())
        let state = DestinationState.needsAttention.rawValue
        let projections = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.stateRaw == state }))
        var suspended: Set<String> = []
        for projection in projections {
            // Copied out of the model first: a #Predicate may compare a key path of the iterated model
            // only against plain values, never against a key path read from a different model object.
            let intakeID = projection.intakeID
            let revision = projection.revision
            let destination = projection.destinationRaw
            let action = projection.actionRaw
            let operations = try context.fetch(FetchDescriptor<OutboxRecord>(
                predicate: #Predicate<OutboxRecord> { $0.intakeID == intakeID }))
            for operation in operations where operation.acknowledgedAt == nil
                && operation.revision == revision
                && operation.destinationRaw == destination
                && operation.kindRaw == action {
                suspended.insert(operation.operationID)
            }
        }
        return suspended
    }

    /// Clears the suspension on one operation, so an automatic run may pick it up again.
    ///
    /// This is the only way a `needsAttention` operation becomes due again, and it is deliberately a
    /// separate call: re-arming after a person has granted or withdrawn Health access is their
    /// decision, not something a scheduled run may decide on its own.
    public func rearmDelivery(operationID: String) throws {
        try commit { context in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            guard row.acknowledgedAt == nil else { return }
            row.nextAttemptAt = nil
            // `includingSuperseded: true`: the suspension is recorded on the projection belonging to
            // this operation, and a later edit may have made that projection noncurrent. Clearing only
            // current projections would leave the state at `needsAttention`, and since suspension is
            // matched by state whatever the projection's currency, the operation would stay suspended
            // and never be delivered again — re-arming would silently do nothing.
            try Self.setProjectionState(.pending, of: row, in: context, includingSuperseded: true)
        }
    }

    /// Moves the projection for this operation's revision, destination **and action**.
    ///
    /// The action is part of the match because deleting an intake does not bump its revision: the
    /// queued upsert and the queued delete share an intake id, a revision number and a destination, and
    /// differ only in what they are for. Matching without it would let acknowledging the stale upsert
    /// mark the delete `succeeded`, and the app would then report a finished retraction while the
    /// samples are still in Health.
    ///
    /// A superseded projection is left as it is: what a later revision is doing matters more than what
    /// an old operation did.
    /// `includingSuperseded` is for clearing a suspension, where the projection that records it may
    /// already have been superseded by a later edit. Every other caller wants current projections only.
    private static func setProjectionState(
        _ state: DestinationState, of row: OutboxRecord, in context: ModelContext,
        includingSuperseded: Bool = false
    ) throws {
        // Copied out of the outbox row first: a #Predicate may compare a key path of the iterated
        // model only against plain values, not against a key path read from a different model object.
        let intakeID = row.intakeID
        let rows = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
        for projection in rows where (includingSuperseded || projection.isCurrent)
            && projection.revision == row.revision
            && projection.destinationRaw == row.destinationRaw
            && projection.actionRaw == row.kindRaw {
            projection.stateRaw = state.rawValue
        }
    }

    private func appendRevision(
        intakeID: String, number: Int, componentsJSON: String, components: [IntakeComponent],
        product: ProductDefinition?, changeReason: String, now: Date, context: ModelContext
    ) throws -> IntakeRevision {
        if let product {
            try Self.insertSnapshot(product, in: context)
        }
        context.insert(RevisionRecord(
            intakeID: intakeID, number: number, componentsJSON: componentsJSON,
            productSnapshotID: product?.snapshotID, changeReason: changeReason, createdAt: now))
        let payload = "\(intakeID):\(number):\(product?.snapshotID ?? ""):\(componentsJSON)"
        queueWork(intakeID: intakeID, revision: number, kind: .upsert, payload: payload, context: context)
        return IntakeRevision(
            intakeID: intakeID, number: number, components: components,
            productSnapshotID: product?.snapshotID, changeReason: changeReason, createdAt: now)
    }

    /// One projection per destination; an enabled one also gets one outbox operation.
    private func queueWork(intakeID: String, revision: Int, kind: OutboxKind, payload: String, context: ModelContext) {
        let hash = Self.fingerprint(payload)
        for destination in JournalDestination.allCases {
            let enabled = enabledDestinations.contains(destination)
            context.insert(ProjectionRecord(
                intakeID: intakeID, revision: revision, destinationRaw: destination.rawValue,
                actionRaw: kind.rawValue,
                stateRaw: (enabled ? DestinationState.pending : DestinationState.disabled).rawValue,
                isCurrent: true))
            if enabled {
                context.insert(OutboxRecord(
                    operationID: UUID().uuidString.lowercased(), kindRaw: kind.rawValue, intakeID: intakeID,
                    revision: revision, destinationRaw: destination.rawValue, payloadHash: hash))
            }
        }
    }

    private static func supersedeProjections(of intakeID: String, in context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
        for row in rows {
            row.isCurrent = false
        }
    }

    /// A snapshot id is written once. Re-using an id is fine only with identical content.
    ///
    /// A row written before the nutrient column existed carries no values at all. Such a row is the
    /// same product with less recorded, so the values this build has are written into it rather than
    /// refused: the snapshot id still names one product, and the values only ever fill in what the
    /// product states. Any other difference is still a conflict.
    private static func insertSnapshot(_ product: ProductDefinition, in context: ModelContext) throws {
        let id = product.snapshotID
        let existing = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == id }))
        if let row = existing.first {
            let stored = snapshot(from: row)
            if stored == product { return }
            guard stored.nutrients.isEmpty, stored.withNutrients(product.nutrients) == product else {
                throw JournalError.snapshotConflict(id)
            }
            row.nutrientsJSON = Self.encodeNutrients(product.nutrients)
            return
        }
        context.insert(ProductRecord(
            snapshotID: product.snapshotID, productID: product.productID, name: product.name,
            brand: product.brand, barcode: product.barcode, labelBasis: product.labelBasis,
            catalogOrigin: product.catalogOrigin, catalogVersion: product.catalogVersion,
            nutrientsJSON: Self.encodeNutrients(product.nutrients)))
    }

    // MARK: Reads

    public func activeIntakes() throws -> [Intake] {
        try Self.readActiveIntakes(container: try openContainer())
    }

    public func activeIntakesFromBackground() async throws -> [Intake] {
        let container = try openContainer()
        return try await Task.detached {
            try SwiftDataJournalStore.readActiveIntakes(container: container)
        }.value
    }

    public func revisions(of intakeID: String) throws -> [IntakeRevision] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<RevisionRecord>(
            predicate: #Predicate<RevisionRecord> { $0.intakeID == intakeID }))
        return try rows.sorted { $0.number < $1.number }.map { row in
            IntakeRevision(
                intakeID: row.intakeID, number: row.number, components: try Self.decode(row.componentsJSON),
                productSnapshotID: row.productSnapshotID, changeReason: row.changeReason, createdAt: row.createdAt)
        }
    }

    public func projections(of intakeID: String) throws -> [DestinationProjection] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
        return try rows.map { row in
            guard let destination = JournalDestination(rawValue: row.destinationRaw),
                  let action = OutboxKind(rawValue: row.actionRaw),
                  let state = DestinationState(rawValue: row.stateRaw)
            else { throw JournalError.corruptRecord("projection") }
            return DestinationProjection(
                intakeID: row.intakeID, revision: row.revision, destination: destination,
                desiredAction: action, state: state, isCurrent: row.isCurrent)
        }.sorted { ($0.revision, $0.destination.rawValue) < ($1.revision, $1.destination.rawValue) }
    }

    /// Operations not yet acknowledged, oldest revision first, upsert before delete within a revision.
    public func pendingOutbox() throws -> [OutboxOperation] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<OutboxRecord>(
            predicate: #Predicate<OutboxRecord> { $0.acknowledgedAt == nil }))
        return try rows.map { row in
            guard let kind = OutboxKind(rawValue: row.kindRaw),
                  let destination = JournalDestination(rawValue: row.destinationRaw)
            else { throw JournalError.corruptRecord("outbox") }
            return OutboxOperation(
                operationID: row.operationID, kind: kind, intakeID: row.intakeID, revision: row.revision,
                destination: destination, payloadHash: row.payloadHash, attempts: row.attempts,
                nextAttemptAt: row.nextAttemptAt, acknowledgedAt: row.acknowledgedAt)
        }.sorted {
            ($0.intakeID, $0.revision, Self.kindRank($0.kind), $0.destination.rawValue)
                < ($1.intakeID, $1.revision, Self.kindRank($1.kind), $1.destination.rawValue)
        }
    }

    /// Creation order within one revision: an upsert is always queued before a delete.
    private static func kindRank(_ kind: OutboxKind) -> Int {
        switch kind {
        case .upsert: return 0
        case .delete: return 1
        }
    }

    public func product(snapshotID: String) throws -> ProductDefinition? {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID }))
        return rows.first.map(Self.snapshot(from:))
    }

    // MARK: Helpers

    private static func intakeRecord(_ id: String, in context: ModelContext) throws -> IntakeRecord? {
        try context.fetch(FetchDescriptor<IntakeRecord>(
            predicate: #Predicate<IntakeRecord> { $0.intakeID == id })).first
    }

    private static func readActiveIntakes(container: ModelContainer) throws -> [Intake] {
        try readIntakes(container: container, lifecycle: .active)
    }

    /// Deleted intakes, kept as tombstones so an export can retract them later.
    public func deletedIntakes() throws -> [Intake] {
        try Self.readIntakes(container: try openContainer(), lifecycle: .deleted)
    }

    /// One consistent read of the journal for the exporter: active intakes with every revision, and deleted
    /// intakes, all from a single model context. The write lock is held for the read, so an export cannot
    /// observe an entry that was deleted after the active list was read but before the tombstones were, which
    /// would leave it in neither list.
    public func readJournalSnapshot() throws -> JournalSnapshot {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<IntakeRecord>())
        let revisionRows = try context.fetch(FetchDescriptor<RevisionRecord>())
        let revisionsByIntake = Dictionary(grouping: revisionRows, by: \.intakeID)

        var active: [JournalExportIntakeSnapshot] = []
        var deleted: [Intake] = []
        for row in rows {
            let lifecycle = try Self.lifecycle(rawValue: row.lifecycleRaw)
            let intake = Intake(
                id: row.intakeID, category: row.category, occurredAt: row.occurredAt,
                timeZoneIdentifier: row.timeZoneIdentifier, meal: row.meal, note: row.note,
                lifecycle: lifecycle, currentRevision: row.currentRevision)
            if intake.lifecycle == .deleted {
                deleted.append(intake)
                continue
            }
            var revisions: [IntakeRevision] = []
            for revision in (revisionsByIntake[row.intakeID] ?? []).sorted(by: { $0.number < $1.number }) {
                // A stored row whose components cannot be read is corrupt; the caller must hear about it
                // rather than get an intake with no amounts.
                let components = try Self.decode(revision.componentsJSON)
                revisions.append(
                    IntakeRevision(
                        intakeID: revision.intakeID, number: revision.number, components: components,
                        productSnapshotID: revision.productSnapshotID, changeReason: revision.changeReason,
                        createdAt: revision.createdAt))
            }
            active.append(JournalExportIntakeSnapshot(intake: intake, revisions: revisions))
        }
        return JournalSnapshot(
            activeIntakes: active.sorted { ($0.intake.occurredAt, $0.intake.id) < ($1.intake.occurredAt, $1.intake.id) },
            deletedIntakes: deleted.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) })
    }

    /// Maps a stored lifecycle string to its value. An unrecognised value means the row is corrupt or was
    /// written by a build this one does not understand: the ordinary active read leaves such a row out
    /// because it predicates on the exact `active` value, so defaulting it to `active` here would put a
    /// deleted entry back into an export as live data. Refuse it instead.
    static func lifecycle(rawValue: String) throws -> IntakeLifecycle {
        guard let lifecycle = IntakeLifecycle(rawValue: rawValue) else {
            throw JournalError.corruptRecord("lifecycle:\(rawValue)")
        }
        return lifecycle
    }

    private static func readIntakes(container: ModelContainer, lifecycle: IntakeLifecycle) throws -> [Intake] {
        let context = ModelContext(container)
        let raw = lifecycle.rawValue
        let rows = try context.fetch(FetchDescriptor<IntakeRecord>(
            predicate: #Predicate<IntakeRecord> { $0.lifecycleRaw == raw }))
        return rows.map {
            Intake(
                id: $0.intakeID, category: $0.category, occurredAt: $0.occurredAt,
                timeZoneIdentifier: $0.timeZoneIdentifier, meal: $0.meal, note: $0.note,
                lifecycle: lifecycle, currentRevision: $0.currentRevision)
        }.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
    }

    private static func snapshot(from row: ProductRecord) -> ProductDefinition {
        ProductDefinition(
            snapshotID: row.snapshotID, productID: row.productID, name: row.name, brand: row.brand,
            barcode: row.barcode, labelBasis: row.labelBasis, catalogOrigin: row.catalogOrigin,
            catalogVersion: row.catalogVersion, nutrients: Self.decodeNutrients(row.nutrientsJSON))
    }

    /// The nutrient values a product states, sorted by id so the same values always write the same
    /// text. Values that cannot be encoded are left out rather than stored as something else.
    static func encodeNutrients(_ values: [String: NutrientValue]) -> String {
        let stored = values.keys.sorted().compactMap { id -> StoredNutrient? in
            guard let value = values[id] else { return nil }
            switch value {
            case .known(let amount, let unit):
                return StoredNutrient(
                    id: id, state: "known", valueText: DecimalText.encode(amount), unitSymbol: unit.symbol)
            case .unknown:
                return StoredNutrient(id: id, state: "unknown", valueText: nil, unitSymbol: nil)
            case .notApplicable:
                return StoredNutrient(id: id, state: "notApplicable", valueText: nil, unitSymbol: nil)
            case .belowReportingThreshold(let unit):
                return StoredNutrient(
                    id: id, state: "belowThreshold", valueText: nil, unitSymbol: unit?.symbol)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads the stored values. An entry that cannot be read is left out, so it reads as unknown
    /// rather than as a number this build invented.
    static func decodeNutrients(_ json: String?) -> [String: NutrientValue] {
        guard let json, let data = json.data(using: .utf8),
            let stored = try? JSONDecoder().decode([StoredNutrient].self, from: data)
        else { return [:] }
        var values: [String: NutrientValue] = [:]
        for item in stored {
            switch item.state {
            case "known":
                guard let text = item.valueText, let amount = DecimalText.decode(text),
                    let symbol = item.unitSymbol, let unit = try? UnitRegistry.unit(for: symbol)
                else { continue }
                values[item.id] = .known(amount, unit)
            case "unknown":
                values[item.id] = .unknown
            case "notApplicable":
                values[item.id] = .notApplicable
            case "belowThreshold":
                if let symbol = item.unitSymbol, let unit = try? UnitRegistry.unit(for: symbol) {
                    values[item.id] = .belowReportingThreshold(unit)
                } else {
                    values[item.id] = .belowReportingThreshold(nil)
                }
            default:
                continue
            }
        }
        return values
    }

    private static func encode(_ components: [IntakeComponent]) throws -> String {
        var seen = Set<String>()
        var stored: [StoredComponent] = []
        for component in components {
            guard JournalValidation.isValidComponentID(component.componentID) else {
                throw JournalError.invalidComponentID(component.componentID)
            }
            guard seen.insert(component.componentID).inserted else {
                throw JournalError.duplicateComponentID(component.componentID)
            }
            guard !component.amount.isNaN else { throw JournalError.invalidAmount(component.componentID) }
            stored.append(StoredComponent(
                componentID: component.componentID, name: component.name,
                amountText: DecimalText.encode(component.amount), unitSymbol: component.unit.symbol))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        guard let text = String(data: data, encoding: .utf8) else { throw JournalError.corruptRecord("components") }
        return text
    }

    private static func decode(_ json: String) throws -> [IntakeComponent] {
        let stored = try JSONDecoder().decode([StoredComponent].self, from: Data(json.utf8))
        return try stored.map { item in
            guard let amount = DecimalText.decode(item.amountText) else {
                throw JournalError.invalidAmount(item.componentID)
            }
            return IntakeComponent(
                componentID: item.componentID, name: item.name, amount: amount,
                unit: try MeasureUnit(symbol: item.unitSymbol))
        }
    }

    /// FNV-1a over the UTF-8 bytes; a change detector, not a security hash.
    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
