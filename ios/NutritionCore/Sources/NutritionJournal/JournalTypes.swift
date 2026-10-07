import Foundation
import NutritionDomain

/// Where an intake is delivered. This module only queues the work; workers live elsewhere.
public enum JournalDestination: String, Sendable, Hashable, Codable, CaseIterable {
    case healthKit
    case relay
}

/// Delivery state of one destination for one revision.
public enum DestinationState: String, Sendable, Hashable, Codable, CaseIterable {
    case pending
    case inProgress
    case succeeded
    case needsAttention
    case disabled
}

public enum OutboxKind: String, Sendable, Hashable, Codable, CaseIterable {
    case upsert
    case delete
}

public enum IntakeLifecycle: String, Sendable, Hashable, Codable, CaseIterable {
    case active
    case deleted
}

public enum JournalError: Error, Sendable, Equatable {
    case closed
    case injectedSaveFailure
    case invalidIntakeID(String)
    case invalidComponentID(String)
    case duplicateComponentID(String)
    case invalidAmount(String)
    case unknownIntake(String)
    case intakeAlreadyExists(String)
    case intakeDeleted(String)
    case snapshotConflict(String)
    case unknownOperation(String)
    case corruptRecord(String)
}

/// Validation of the identifiers used in the intake-context contract.
public enum JournalValidation {
    /// Component ids are slugs: `[a-z0-9][a-z0-9._-]{0,63}`, the whole string.
    public static func isValidComponentID(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = componentIDExpression.firstMatch(in: value, options: [], range: range) else {
            return false
        }
        return match.range == range
    }

    /// Intake ids are lowercase UUIDs.
    public static func isValidIntakeID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value == value.lowercased()
    }

    private static let componentIDExpression: NSRegularExpression = {
        // The pattern is a constant, so construction cannot fail.
        try! NSRegularExpression(pattern: "\\A[a-z0-9][a-z0-9._-]{0,63}\\z", options: [])
    }()
}

/// Exact decimal text, independent of the device locale.
enum DecimalText {
    /// True when `text` is the exact form the export schema allows: an optional minus sign, digits, and at
    /// most one fractional part. `Decimal(string:)` alone is too permissive for the contract, because it
    /// accepts forms such as `"1.2.3"` in some locales.
    static func isValidDecimalText(_ text: String) -> Bool {
        text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }
    static let locale = Locale(identifier: "en_US_POSIX")

    static func encode(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: locale)
    }

    static func decode(_ text: String) -> Decimal? {
        guard !text.isEmpty else { return nil }
        let value = Decimal(string: text, locale: locale)
        guard let value, !value.isNaN else { return nil }
        return value
    }
}

public struct Intake: Sendable, Hashable {
    /// Lowercase UUID.
    public var id: String
    public var category: String
    public var occurredAt: Date
    public var timeZoneIdentifier: String
    public var meal: String?
    public var note: String?
    public var lifecycle: IntakeLifecycle
    /// Revision numbers start at 1 and grow by one per edit.
    public var currentRevision: Int

    public init(
        id: String,
        category: String,
        occurredAt: Date,
        timeZoneIdentifier: String,
        meal: String? = nil,
        note: String? = nil,
        lifecycle: IntakeLifecycle = .active,
        currentRevision: Int = 1
    ) {
        self.id = id
        self.category = category
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.meal = meal
        self.note = note
        self.lifecycle = lifecycle
        self.currentRevision = currentRevision
    }
}

public struct IntakeComponent: Sendable, Hashable {
    public var componentID: String
    public var name: String
    /// Exact decimal amount; stored as decimal text.
    public var amount: Decimal
    public var unit: MeasureUnit

    public init(componentID: String, name: String, amount: Decimal, unit: MeasureUnit) {
        self.componentID = componentID
        self.name = name
        self.amount = amount
        self.unit = unit
    }
}

public struct IntakeRevision: Sendable, Hashable {
    public var intakeID: String
    public var number: Int
    public var components: [IntakeComponent]
    public var productSnapshotID: String?
    public var changeReason: String
    public var createdAt: Date
    /// The instant this revision says the entry was eaten, with the zone that goes with it.
    ///
    /// The entry's own `Intake.occurredAt` moves when the time is corrected, so a revision that is still
    /// queued cannot read its own instant back out of it: rebuilding a revision 1 that is waiting for a
    /// delivery would name the corrected time, and the retry would reach the receiver under the revision's
    /// own `operation_id` with a different payload — a conflict rather than the duplicate it is. Each
    /// revision therefore carries the time it was written with, and a delivery rebuilds the revision from
    /// these.
    ///
    /// Nil means "the entry's current time", which is what a row written before this column existed says.
    /// A revision that predates the column was written when the entry's row was the only record of the
    /// time, so nil is the honest reading of it and the corrected instant is the only one such a row can
    /// offer.
    public var occurredAt: Date?
    /// The zone `occurredAt` is a wall clock in. Read with `occurredAt`: nil here means the entry's own.
    public var timeZoneIdentifier: String?

    public init(
        intakeID: String,
        number: Int,
        components: [IntakeComponent],
        productSnapshotID: String?,
        changeReason: String,
        createdAt: Date,
        occurredAt: Date? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.intakeID = intakeID
        self.number = number
        self.components = components
        self.productSnapshotID = productSnapshotID
        self.changeReason = changeReason
        self.createdAt = createdAt
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// An immutable product snapshot. Changing a product means a new snapshot id; old revisions keep theirs.
public struct ProductDefinition: Sendable, Hashable {
    public var snapshotID: String
    public var productID: String
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var labelBasis: String
    public var catalogOrigin: String
    public var catalogVersion: String
    /// The nutrient values this product states, on the basis `labelBasis` names. A nutrient the
    /// product does not state is absent, which reads as unknown and never as zero; a known zero is
    /// stored as zero. Empty when the product carries no values.
    ///
    /// The values are the product's own, not the component's: they are not scaled to how much of the
    /// product an intake records. A reader that needs the amount for one component scales them with
    /// `labelBasis` itself.
    public var nutrients: [String: NutrientValue]

    public init(
        snapshotID: String,
        productID: String,
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        labelBasis: String,
        catalogOrigin: String,
        catalogVersion: String,
        nutrients: [String: NutrientValue] = [:]
    ) {
        self.snapshotID = snapshotID
        self.productID = productID
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.labelBasis = labelBasis
        self.catalogOrigin = catalogOrigin
        self.catalogVersion = catalogVersion
        self.nutrients = nutrients
    }

    /// The value for one nutrient; a nutrient this product does not state is unknown, never zero.
    public func value(for nutrient: String) -> NutrientValue {
        nutrients[nutrient] ?? .unknown
    }

    /// This snapshot with the given values in place of its own. Every other field is kept, so a caller
    /// can ask whether two snapshots of one product differ only in what they record.
    public func withNutrients(_ values: [String: NutrientValue]) -> ProductDefinition {
        var copy = self
        copy.nutrients = values
        return copy
    }
}

public struct DestinationProjection: Sendable, Hashable {
    public var intakeID: String
    public var revision: Int
    public var destination: JournalDestination
    public var desiredAction: OutboxKind
    public var state: DestinationState
    /// False once a later revision or a delete supersedes this projection.
    public var isCurrent: Bool

    public init(
        intakeID: String,
        revision: Int,
        destination: JournalDestination,
        desiredAction: OutboxKind,
        state: DestinationState,
        isCurrent: Bool
    ) {
        self.intakeID = intakeID
        self.revision = revision
        self.destination = destination
        self.desiredAction = desiredAction
        self.state = state
        self.isCurrent = isCurrent
    }
}

public struct OutboxOperation: Sendable, Hashable {
    /// Lowercase UUID; the idempotency key of the operation.
    public var operationID: String
    public var kind: OutboxKind
    public var intakeID: String
    public var revision: Int
    public var destination: JournalDestination
    public var payloadHash: String
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var acknowledgedAt: Date?

    public init(
        operationID: String,
        kind: OutboxKind,
        intakeID: String,
        revision: Int,
        destination: JournalDestination,
        payloadHash: String,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        acknowledgedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.kind = kind
        self.intakeID = intakeID
        self.revision = revision
        self.destination = destination
        self.payloadHash = payloadHash
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.acknowledgedAt = acknowledgedAt
    }
}

public protocol JournalStore: AnyObject, Sendable {
    /// When true, the next write inserts its rows and then fails before committing.
    var failNextSaveForTesting: Bool { get set }

    /// Writes intake, revision 1, product snapshot, projections and outbox operations in one save.
    @discardableResult
    func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision
    /// Writes revision n+1 and supersedes the previous projections, in one save.
    ///
    /// `occurredAt`, with the `timeZoneIdentifier` that goes with it, corrects when the entry was
    /// eaten: the new revision carries the corrected time and the intake's own row moves with it in
    /// the same save. **It is a new revision, never an update to a delivered one** — the encoder
    /// digests `occurred_at` per (intake, revision), so a time changed in place would leave a
    /// delivered revision describing an instant that is no longer true. Every earlier revision is
    /// kept, the superseded projections are not updated, and the queued upsert payload hash covers
    /// the timestamp. Leaving both nil corrects the amounts only and leaves the time as it was.
    @discardableResult
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?
    ) throws -> IntakeRevision
    /// Marks the intake deleted and queues delete operations at the current revision, in one save.
    func delete(intakeID: String, now: Date) throws

    func activeIntakes() throws -> [Intake]
    func revisions(of intakeID: String) throws -> [IntakeRevision]
    func projections(of intakeID: String) throws -> [DestinationProjection]
    func pendingOutbox() throws -> [OutboxOperation]
    func product(snapshotID: String) throws -> ProductDefinition?
    /// Reads the active intakes through a context created off the calling executor.
    func activeIntakesFromBackground() async throws -> [Intake]
    /// Releases the store; a new instance can reopen the same file.
    func close()
}

extension JournalStore {
    /// Corrects the amounts only and leaves the entry's time as it was.
    @discardableResult
    public func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date
    ) throws -> IntakeRevision {
        try edit(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: nil, timeZoneIdentifier: nil)
    }
}

/// One intake with the whole revision history an import writes, exactly as the export carried it: the
/// ids, the timestamps, the revision numbers and the product snapshot ids are the file's, not new ones.
/// A restore must not renumber anything or move an entry onto another instant.
public struct JournalRestoreEntry: Sendable, Hashable {
    public var intake: Intake
    /// Every revision of the intake, numbered from 1 with no gaps, in order.
    public var revisions: [IntakeRevision]

    public init(intake: Intake, revisions: [IntakeRevision]) {
        self.intake = intake
        self.revisions = revisions
    }
}

/// Everything one import writes to a journal store, already checked. The importer builds the whole plan
/// before it writes any of it, so a file it refuses leaves the store untouched.
public struct JournalRestorePlan: Sendable {
    /// Active intakes with all their revisions.
    public var entries: [JournalRestoreEntry]
    /// Deleted intakes, written back as tombstones so a later export retracts them again.
    public var tombstones: [Intake]
    /// The product snapshots the entries and favorites refer to, so a restore needs no catalog lookup.
    public var products: [ProductDefinition]
    /// Favorites, which the importer writes through the favorites store rather than this one.
    public var favorites: [FavoriteTemplate]

    public init(
        entries: [JournalRestoreEntry], tombstones: [Intake],
        products: [ProductDefinition], favorites: [FavoriteTemplate]
    ) {
        self.entries = entries
        self.tombstones = tombstones
        self.products = products
        self.favorites = favorites
    }
}

/// What one restore wrote for one intake, so an undo can tell its own rows from a later one.
///
/// Between the restore and a step that follows it, another write may reach the same journal. The undo has to
/// be able to tell, so the receipt says which entry, which lifecycle, how far along it was and exactly which
/// revision numbers were written: enough to remove those rows, and to notice when an entry no longer looks
/// the way the restore left it.
public struct JournalRestoredIntake: Sendable, Equatable {
    public var intakeID: String
    /// `active` for a live entry, `deleted` for a tombstone: how the restore left it.
    public var lifecycle: IntakeLifecycle
    /// The revision number the intake's row was left at.
    public var currentRevision: Int
    /// Every revision number written for it. A tombstone has none.
    public var revisionNumbers: [Int]

    public init(intakeID: String, lifecycle: IntakeLifecycle, currentRevision: Int, revisionNumbers: [Int]) {
        self.intakeID = intakeID
        self.lifecycle = lifecycle
        self.currentRevision = currentRevision
        self.revisionNumbers = revisionNumbers
    }
}

/// What one restore actually inserted, so it can be taken back out when a later step of the same import
/// fails. The journal held no intakes before the restore, which the store checks in the same transaction,
/// so the rows named here are everything the restore added and undoing them leaves the store as it was.
public struct JournalRestoreReceipt: Sendable, Equatable {
    /// The intakes written, live and deleted alike, with the rows each one owns.
    public var intakes: [JournalRestoredIntake]
    /// Product snapshots this restore created a row for. A snapshot the store already had is not listed:
    /// undoing must leave it, and the nutrient values it holds, alone.
    public var insertedProductSnapshotIDs: [String]

    public init(intakes: [JournalRestoredIntake], insertedProductSnapshotIDs: [String]) {
        self.intakes = intakes
        self.insertedProductSnapshotIDs = insertedProductSnapshotIDs
    }
}

/// A journal store the importer can write into in one save. This is deliberately not part of
/// `JournalStore`: a restore is not a create, an edit or a delete, and it must not change what those do.
///
/// An import writes no projection and no outbox operation. A restored entry is history the destinations
/// have already been sent once, so queueing it again would deliver yesterday's breakfast a second time
/// just because a phone was replaced.
public protocol JournalRestoreTarget: AnyObject, Sendable {
    /// Writes the whole plan in one save, keeping every id, timestamp and revision number, and reports what
    /// it inserted.
    ///
    /// A store that already holds an intake row, live or deleted, is refused with
    /// `JournalImportError.notEmpty` from inside this same transaction: the check and the inserts share one
    /// write lock, so a write that lands in between cannot turn an empty-only restore into a merge. Any
    /// other failure rolls the save back, so the store is left exactly as it was.
    func restore(_ plan: JournalRestorePlan) throws -> JournalRestoreReceipt
    /// Removes the rows a restore inserted, for the case where the step after it failed.
    ///
    /// Rows the store held before the restore are not touched, and neither are rows written since: an intake
    /// edited or deleted after the restore is left alone, and the undo throws `JournalImportError.corrupt`
    /// rather than throw that work away to make the journal look empty. Product rows are removed only for the
    /// snapshots this restore created, which nothing else writes.
    func undoRestore(_ receipt: JournalRestoreReceipt) throws
}

/// What a delivery worker needs from the journal beyond recording: reading the queue and recording
/// what happened to one operation.
///
/// This is a refinement of `JournalStore` rather than part of it on purpose. Reading the journal is
/// something every implementation can do; recording a delivery is something only a store that owns the
/// outbox can do, and a read-only stand-in (an export source, a view model's test double) should not
/// have to invent it. `SwiftDataJournalStore` is the implementation the app and the worker use.
public protocol JournalOutboxDelivery: JournalStore {
    /// Records that a worker delivered one operation: `acknowledgedAt` is stamped and the projection
    /// for that revision and destination becomes `succeeded`. An acknowledged operation is never
    /// offered again by `pendingOutbox()`.
    ///
    /// Acknowledging an operation that is already acknowledged is not an error: a worker that crashed
    /// after writing but before recording the delivery will deliver again, and that second delivery
    /// has to be recordable rather than refused.
    func acknowledge(operationID: String, at date: Date) throws
    /// Records one delivery attempt that did not succeed. `attempts` grows by one and the operation
    /// becomes due again at `retryAt`, which is nil when nothing should retry it on its own. A
    /// failure only a person can fix is recorded with `needsAttention`, which puts the projection in
    /// `needsAttention` so the app can show it instead of the worker retrying it forever.
    func recordFailure(operationID: String, retryAt: Date?, needsAttention: Bool) throws
    /// The pending operations whose current projection is `needsAttention`, which a delivery worker
    /// must leave alone: they are suspended until someone calls `rearmDelivery(operationID:)`.
    ///
    /// A suspension is not visible from the operation alone — its `nextAttemptAt` is nil, which is
    /// exactly what "do not retry" looks like and exactly what "due now" also looks like — so the
    /// worker has to ask.
    func suspendedOperationIDs() throws -> Set<String>
    /// Clears the suspension, making the operation due again. Deliberately explicit: re-arming after a
    /// person has resolved the denial is their decision, not a scheduled run's.
    func rearmDelivery(operationID: String) throws
}
