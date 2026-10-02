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

/// One schema version so far. A later version adds a stage here before its first release.
enum JournalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [JournalSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias IntakeRecord = JournalSchemaV1.IntakeRecord
typealias RevisionRecord = JournalSchemaV1.RevisionRecord
typealias ProductRecord = JournalSchemaV1.ProductRecord
typealias ProjectionRecord = JournalSchemaV1.ProjectionRecord
typealias OutboxRecord = JournalSchemaV1.OutboxRecord

private struct StoredComponent: Codable {
    var componentID: String
    var name: String
    var amountText: String
    var unitSymbol: String
}

public final class SwiftDataJournalStore: JournalStore, @unchecked Sendable {
    private let lock = NSLock()
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
        let schema = Schema(versionedSchema: JournalSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(
            for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    public func close() {
        lock.withLock { container = nil }
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
    private static func insertSnapshot(_ product: ProductDefinition, in context: ModelContext) throws {
        let id = product.snapshotID
        let existing = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == id }))
        if let row = existing.first {
            if snapshot(from: row) != product {
                throw JournalError.snapshotConflict(id)
            }
            return
        }
        context.insert(ProductRecord(
            snapshotID: product.snapshotID, productID: product.productID, name: product.name,
            brand: product.brand, barcode: product.barcode, labelBasis: product.labelBasis,
            catalogOrigin: product.catalogOrigin, catalogVersion: product.catalogVersion))
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

    /// Operations not yet acknowledged, oldest revision first.
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
            ($0.intakeID, $0.revision, $0.destination.rawValue, $0.kind.rawValue)
                < ($1.intakeID, $1.revision, $1.destination.rawValue, $1.kind.rawValue)
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
        let context = ModelContext(container)
        let active = IntakeLifecycle.active.rawValue
        let rows = try context.fetch(FetchDescriptor<IntakeRecord>(
            predicate: #Predicate<IntakeRecord> { $0.lifecycleRaw == active }))
        return rows.map {
            Intake(
                id: $0.intakeID, category: $0.category, occurredAt: $0.occurredAt,
                timeZoneIdentifier: $0.timeZoneIdentifier, meal: $0.meal, note: $0.note,
                lifecycle: .active, currentRevision: $0.currentRevision)
        }.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
    }

    private static func snapshot(from row: ProductRecord) -> ProductDefinition {
        ProductDefinition(
            snapshotID: row.snapshotID, productID: row.productID, name: row.name, brand: row.brand,
            barcode: row.barcode, labelBasis: row.labelBasis, catalogOrigin: row.catalogOrigin,
            catalogVersion: row.catalogVersion)
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
