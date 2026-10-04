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

    public init(
        intakeID: String,
        number: Int,
        components: [IntakeComponent],
        productSnapshotID: String?,
        changeReason: String,
        createdAt: Date
    ) {
        self.intakeID = intakeID
        self.number = number
        self.components = components
        self.productSnapshotID = productSnapshotID
        self.changeReason = changeReason
        self.createdAt = createdAt
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
    @discardableResult
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String, now: Date
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
