import Foundation
import NutritionDomain

/// Why a journal revision could not be written as an intake-context operation.
///
/// Every case here is a refusal the receiver would make anyway, caught before a digest is taken: a delivery
/// row that is not this operation, a product snapshot that is not this revision's, a component id that is not a
/// slug, a link the contract's link rules reject, or an envelope field that is not canonical.
public enum IntakeContextEncoderError: Error, Equatable, Sendable {
    /// The revision belongs to another intake than the one it is being encoded with.
    case revisionIntakeMismatch(String)
    /// The outbox row belongs to another intake, or to another revision, than the one being encoded.
    case operationDoesNotMatchIntake(String)
    /// The outbox row's action is not the one this method delivers, so its delivery identity is not ours to use.
    case operationActionMismatch(OutboxKind)
    /// The outbox row is queued for another destination. This encoder only writes relay deliveries.
    case operationDestinationMismatch(JournalDestination)
    /// The product is not the snapshot the revision names, or the revision names none and one was supplied.
    /// Both would hash another product's values as this revision's immutable facts.
    case productSnapshotMismatch(expected: String?, found: String?)
    /// An intake with no components has no facts, and the contract requires a non-empty `facts` array.
    case noComponents(String)
    /// The intake's time zone name is not a portable IANA zone. The contract rejects host-local names such as
    /// `localtime`, `Factory` and `posixrules`, and the `posix/` and `right/` copies, because they do not name
    /// one zone on every receiver.
    case unknownTimeZone(String)
    /// The component id is not a slug, so it has no contract form: `^[a-z0-9][a-z0-9._-]{0,63}$`.
    case invalidComponentID(String)
    /// The same component id appears twice in one revision, and the contract requires unique component ids.
    case duplicateComponent(String)
    /// A component amount is negative, and the contract's decimal strings are non-negative.
    case negativeAmount(String)
    /// A blend needs at least one member, and its members are never invented.
    case blendWithoutMembers(String)
    /// A link names a component that is not a nutrient fact of the operation's revision.
    case linkComponentIsNotAFact(String)
    /// The same component and sample pair appears twice in one link snapshot.
    case duplicateLink(String)
    /// A link names a sample UUID that is not lowercase canonical UUID text.
    case invalidSampleUUID(String)
    /// A link names a HealthKit type that is not the type its fact's code lands in.
    case linkTypeMismatch(component: String, expected: String, found: String)
    /// A sync version below 1, which the schema rejects: only `revision`, `projection_sequence` and
    /// `sync_version` are integers, and all three start at 1.
    case invalidSyncVersion(Int)
    /// One sync identity repeats a `sync_version`, so the same object would be written twice.
    case duplicateSyncVersion(String)
    /// Two samples are active for one sync identity. HealthKit replaces the object a sync identifier names, so
    /// only one of them can be.
    case duplicateActiveLinkForSyncIdentity(String)
    /// One sample is active on two components, so it would be counted for both.
    case sampleActiveOnTwoComponents(sample: String, first: String, second: String)
    /// An inactive link carries a version newer than the active link of the same sync identity.
    case inactiveLinkNewerThanActive(syncIdentifier: String, active: Int, found: Int)
    /// A link-only change cannot carry sequence 1: that sequence belongs to the revision's upsert.
    case projectionSequenceMustBeAtLeastTwo(Int)
    /// A batch was asked for with no operations.
    case emptyBatch
    /// The operations given to one batch were not all encoded under the same producer scope.
    case scopeMismatch
    /// A batch was asked to carry a value that is already a batch, which would nest one envelope in another.
    case operationAlreadyBatched
    /// The scope's installation id is not canonical UUID text, and no normalization could make it so.
    case invalidInstallationID(String)
    /// A batch id is not UUID text, so it could never satisfy the schema's lowercase canonical form.
    case invalidBatchID(String)
}

/// Lowercase canonical UUID text, which is the form the contract's schema requires of every UUID it carries.
///
/// `UUID().uuidString` is upper case, so a caller who builds a scope or a batch id from the obvious API would
/// otherwise send a payload the receiver rejects while parsing. Identifiers are normalized through here instead,
/// and text that is not a UUID at all is refused.
enum IntakeContextIdentifier {
    /// The canonical lowercase spelling of a UUID, or nil when the text is not one.
    static func canonicalUUIDText(_ text: String) -> String? {
        guard let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// Whether the text is already lowercase canonical UUID text.
    static func isCanonicalUUIDText(_ text: String) -> Bool {
        canonicalUUIDText(text) == text
    }
}

/// The stable producer scope a batch is sent under.
///
/// The receiver derives the owner binding from its own configuration, so nothing here selects a tenant: these
/// three fields say which registered producer is speaking, which bundle it expects its HealthKit samples to be
/// written as, and which app installation sent the batch. `installation_id` is provenance only, so an intake
/// restored onto a new installation is the same intake and not a new event.
public struct IntakeContextProducerScope: Sendable, Hashable {
    /// The registered producer, for example `nutrition-app`.
    public let producerID: String
    /// The bundle identifier the producer expects to write HealthKit samples as.
    public let writerBundleID: String
    /// The app installation that sent the batch, normalized to lowercase canonical UUID text where it can be.
    public let installationID: String

    public init(producerID: String, writerBundleID: String, installationID: String) {
        self.producerID = producerID
        self.writerBundleID = writerBundleID
        self.installationID = IntakeContextIdentifier.canonicalUUIDText(installationID) ?? installationID
    }
}

/// What a link claims about a saved HealthKit sample.
///
/// A link is a claim the receiver verifies, not proof: it joins a component to an accepted measurement by
/// exact sample UUID and then checks the quantity type and the source bundle. The sample UUID is therefore
/// lowercased canonical text, and the sync metadata is the one `HealthKitWritePlanner` saved the sample with.
public struct IntakeContextLink: Sendable, Hashable {
    /// The fact the sample belongs to. A compound and a blend have no HealthKit quantity type, so only a
    /// nutrient fact is ever linked.
    public let componentID: String
    /// Lowercase UUID of the saved sample.
    public let sampleUUID: String
    /// The quantity type identifier, `HKQuantityTypeIdentifier...`.
    public let healthKitTypeIdentifier: String
    /// The sync identifier the producer saved the sample with.
    public let syncIdentifier: String
    /// The sync version, at least 1. HealthKit replaces a sample rather than duplicating it.
    public let syncVersion: Int
    public let disposition: IntakeContextLinkDisposition

    public init(
        componentID: String,
        sampleUUID: String,
        healthKitTypeIdentifier: String,
        syncIdentifier: String,
        syncVersion: Int,
        disposition: IntakeContextLinkDisposition
    ) {
        self.componentID = componentID
        self.sampleUUID = sampleUUID
        self.healthKitTypeIdentifier = healthKitTypeIdentifier
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.disposition = disposition
    }

    /// The sync identity this link belongs to. The contract compares versions only within one of these.
    var syncIdentity: String {
        [componentID, healthKitTypeIdentifier, syncIdentifier].joined(separator: "|")
    }
}

/// Whether a link counts towards the totals or is kept for audit only.
public enum IntakeContextLinkDisposition: String, Sendable, Hashable, CaseIterable {
    /// The sample currently stands for the component.
    case active
    /// A newer sample replaced it. Kept for audit, never for resurrection.
    case superseded
    /// The sample was removed. Kept for audit, never for resurrection.
    case deleted
}

/// Which operation of the contract a value is.
public enum IntakeContextOperationKind: String, Sendable, Hashable, CaseIterable {
    case upsert
    case delete
    case linkProjection

    /// The contract's spelling of the operation, which is not the camel-case raw value.
    public var contractValue: String {
        switch self {
        case .upsert: return "upsert"
        case .delete: return "delete"
        case .linkProjection: return "link_projection"
        }
    }
}

/// One encoded operation, described without its JSON.
///
/// The digests are here so a caller can log or compare them without reading the payload, and the payload
/// itself is `IntakeContextValue.canonicalBytes`.
public struct IntakeContextOperationValue: Sendable, Hashable {
    /// The outbox row's id, which is the delivery identity of this operation.
    public let operationID: String
    public let kind: IntakeContextOperationKind
    public let intakeID: String
    public let revision: Int
    /// 1 for an upsert, which opens the projection lifecycle of its revision, and 2 or more for a link-only
    /// change to the same revision.
    public let projectionSequence: Int
    /// The digest of the facts at `(owner, producer, intake_id, revision)`. Absent on a link projection, which
    /// carries no facts.
    public let domainFactsHash: String?
    /// The digest of the complete link snapshot. Absent on a delete, which carries no links.
    public let projectionHash: String?
    /// The digest of the delivered content, including the other two.
    public let clientPayloadHash: String
}

/// An encoded intake-context payload: one operation, or a whole batch of them.
///
/// The bytes are canonical, because the receiver hashes exactly what it received: the same journal revision
/// encoded twice produces the same `canonicalBytes`, and a digest that does not match them is a permanent
/// failure. Encoding is pure data, so nothing here opens a connection or reads the outbox.
public struct IntakeContextValue: Sendable, Hashable {
    public let schemaVersion: String
    public let scope: IntakeContextProducerScope
    /// The delivery identifier of a batch. Nil while a value is still a single operation: only the batch
    /// carries one, and no digest covers it.
    public let batchID: String?
    public let operations: [IntakeContextOperationValue]
    /// The canonical bytes of this value exactly as it is sent: the operation alone, or the whole batch.
    public let canonicalBytes: Data
    /// The payload as a JSON value, for a caller that needs to read a member back.
    let payload: IntakeContextJSONValue

    /// One member of the payload, or nil when this value has no such member. Internal because the JSON value
    /// is this module's own: a caller sends `canonicalBytes` and needs nothing else.
    func member(_ key: String) -> IntakeContextJSONValue? {
        payload.member(key)
    }

    /// Whether this value is a finished batch rather than a single operation.
    var isBatch: Bool { batchID != nil }
}

/// Writes a journal revision as an intake-context operation, exactly as the contract spells it.
///
/// The encoder owns no state beyond its producer scope, so the same input always produces the same bytes. Every
/// digest is computed with `IntakeContextDigests` over the canonical bytes of the operation as sent, which is
/// the only way to satisfy the receiver: it recomputes all three and rejects a mismatch.
///
/// See `docs/intake-context.md` for the journal to contract mapping table.
public struct IntakeContextEncoder: Sendable {
    public static let schema = "healthrelay.intake-context"
    /// The only version this app sends. A receiver rejects an unknown major version, and a minor it does not
    /// know, before it reads anything else.
    public static let schemaVersion = "1.0"

    /// The scope every batch is sent under.
    public let scope: IntakeContextProducerScope

    public init(scope: IntakeContextProducerScope) {
        self.scope = scope
    }

    /// The `upsert` for one revision: the facts of that revision and the first link snapshot for it.
    ///
    /// `operation` is the relay outbox row this delivery is made under, and its `operation_id` is the delivery
    /// identity the receiver deduplicates on. `links` is the snapshot the samples of the HealthKit write plan
    /// produced; without them the snapshot is empty, which is the contract's way of saying nothing has been
    /// linked yet rather than of omitting the field.
    public func upsert(
        intake: Intake,
        revision: IntakeRevision,
        product: ProductDefinition?,
        operation: OutboxOperation,
        links: [IntakeContextLink]? = nil
    ) throws -> IntakeContextValue {
        try validateScope()
        try checked(operation, kind: .upsert, intakeID: intake.id, revision: revision.number)
        guard revision.intakeID == intake.id else {
            throw IntakeContextEncoderError.revisionIntakeMismatch(intake.id)
        }
        let snapshot = try checkedProduct(product, for: revision)
        let facts = try encodedFacts(of: revision, product: snapshot)
        var members: [String: IntakeContextJSONValue] = [
            "operation_id": .string(operation.operationID),
            "operation": .string(IntakeContextOperationKind.upsert.contractValue),
            "intake_id": .string(intake.id),
            "revision": .integer(String(revision.number)),
            // An upsert always opens the projection lifecycle of its revision, so it is sequence 1.
            "projection_sequence": .integer("1"),
            "occurred_at": .string(
                try IntakeContextTimestamp.local(intake.occurredAt, timeZone: intake.timeZoneIdentifier)),
            "time_zone": .string(intake.timeZoneIdentifier),
            "recorded_at": .string(IntakeContextTimestamp.utc(revision.createdAt)),
            "category": .string(intake.category),
            "display_name": .string(displayName(intake: intake, product: snapshot)),
            "serving": try serving(of: revision),
            "facts": .array(facts),
            "healthkit_links": .array(try linkValues(links ?? [], codes: nutrientCodes(of: facts))),
            "nutrition_completeness": .string(completeness(product: snapshot, facts: facts)),
        ]
        return try sealed(members: &members, kind: .upsert, operationID: operation.operationID,
            intakeID: intake.id, revision: revision.number, sequence: 1)
    }

    /// The `delete` for a deleted intake: a tombstone at the revision above the one it deletes, and nothing
    /// else.
    ///
    /// It carries no food details, no facts and no links, and the receiver keeps it as a tombstone so that a
    /// delayed older upsert cannot resurrect the intake. The contract requires that revision to be higher than
    /// every accepted one, so the tombstone is written one above `revision`: `revision` is the last accepted
    /// revision, not the revision the deletion claims to be. `deletedAt` is an instant, so it is written in UTC.
    public func delete(
        intake: Intake,
        revision: IntakeRevision,
        operation: OutboxOperation,
        deletedAt: Date
    ) throws -> IntakeContextValue {
        try validateScope()
        try checked(operation, kind: .delete, intakeID: intake.id, revision: nil)
        guard revision.intakeID == intake.id else {
            throw IntakeContextEncoderError.revisionIntakeMismatch(intake.id)
        }
        let tombstone = revision.number + 1
        var members: [String: IntakeContextJSONValue] = [
            "operation_id": .string(operation.operationID),
            "operation": .string(IntakeContextOperationKind.delete.contractValue),
            "intake_id": .string(intake.id),
            "revision": .integer(String(tombstone)),
            "deleted_at": .string(IntakeContextTimestamp.utc(deletedAt)),
        ]
        return try sealed(members: &members, kind: .delete, operationID: operation.operationID,
            intakeID: intake.id, revision: tombstone, sequence: 0)
    }

    /// The `link_projection` for a link-only change to a revision whose facts are already accepted.
    ///
    /// A later HealthKit save can reveal a sample UUID after the facts were accepted. The operation carries the
    /// complete link snapshot, never a delta, and no facts and no domain digest, so every link is checked here
    /// against the components of `revision`: it has to name a nutrient of that revision and the type that
    /// nutrient's code lands in, exactly as an upsert's links are. Sequence 1 belongs to the revision's upsert,
    /// so a link-only change starts at 2, and the delivery is made under that revision's relay upsert row.
    public func linkProjection(
        intake: Intake,
        revision: IntakeRevision,
        sequence: Int,
        operation: OutboxOperation,
        links: [IntakeContextLink]
    ) throws -> IntakeContextValue {
        try validateScope()
        try checked(operation, kind: .upsert, intakeID: intake.id, revision: revision.number)
        guard revision.intakeID == intake.id else {
            throw IntakeContextEncoderError.revisionIntakeMismatch(intake.id)
        }
        guard sequence >= 2 else {
            throw IntakeContextEncoderError.projectionSequenceMustBeAtLeastTwo(sequence)
        }
        let codes = try nutrientCodes(of: revision)
        var members: [String: IntakeContextJSONValue] = [
            "operation_id": .string(operation.operationID),
            "operation": .string(IntakeContextOperationKind.linkProjection.contractValue),
            "intake_id": .string(intake.id),
            "revision": .integer(String(revision.number)),
            "projection_sequence": .integer(String(sequence)),
            "healthkit_links": .array(try linkValues(links, codes: codes)),
        ]
        return try sealed(members: &members, kind: .linkProjection, operationID: operation.operationID,
            intakeID: intake.id, revision: revision.number, sequence: sequence)
    }

    /// One batch carrying the given operations in the order they are sent.
    ///
    /// The receiver applies the operations in array order, and each one sees the effects of the ones before it,
    /// so the order is the caller's decision and this method keeps it. Every operation must have been encoded
    /// under this encoder's scope, because `client_payload_hash` covers the scope the operation was hashed
    /// under and a batch may not mix them, and every input must be a single operation: a value that is already
    /// a batch carries its own envelope, and nesting one inside `operations` is a schema failure.
    public func batch(batchID: String, operations: [IntakeContextValue]) throws -> IntakeContextValue {
        try validateScope()
        guard !operations.isEmpty else { throw IntakeContextEncoderError.emptyBatch }
        for value in operations {
            guard !value.isBatch else { throw IntakeContextEncoderError.operationAlreadyBatched }
            guard value.scope == scope, value.schemaVersion == Self.schemaVersion else {
                throw IntakeContextEncoderError.scopeMismatch
            }
        }
        // The schema wants lowercase canonical UUID text, so an id is normalized before it is sent.
        guard let canonicalBatchID = IntakeContextIdentifier.canonicalUUIDText(batchID) else {
            throw IntakeContextEncoderError.invalidBatchID(batchID)
        }
        let payload = IntakeContextJSONValue.object(
            batchMembers(batchID: canonicalBatchID, operations: operations.map(\.payload)))
        return IntakeContextValue(
            schemaVersion: Self.schemaVersion,
            scope: scope,
            batchID: canonicalBatchID,
            operations: operations.flatMap(\.operations),
            canonicalBytes: IntakeContextCanonicalJSON.encode(payload),
            payload: payload
        )
    }

    // MARK: - What the encoder checks before it encodes

    /// The scope's installation id has to be a UUID, or every payload built under it would fail the schema.
    private func validateScope() throws {
        guard IntakeContextIdentifier.isCanonicalUUIDText(scope.installationID) else {
            throw IntakeContextEncoderError.invalidInstallationID(scope.installationID)
        }
    }

    /// Checks that the outbox row is the delivery this method makes.
    ///
    /// The destination has to be the relay, because this encoder writes relay payloads and never a HealthKit
    /// write plan, and the action has to be the one the method delivers, so a worker that dispatches the wrong
    /// pending row cannot send one kind of operation under another's durable delivery identity. `revision` is
    /// checked when the row has to name this exact revision, and is left out for a delete, whose row is the
    /// journal's bookkeeping at the last accepted revision while the tombstone itself stands one above it.
    private func checked(
        _ operation: OutboxOperation,
        kind: OutboxKind,
        intakeID: String,
        revision: Int?
    ) throws {
        guard operation.destination == .relay else {
            throw IntakeContextEncoderError.operationDestinationMismatch(operation.destination)
        }
        guard operation.kind == kind else {
            throw IntakeContextEncoderError.operationActionMismatch(operation.kind)
        }
        guard operation.intakeID == intakeID else {
            throw IntakeContextEncoderError.operationDoesNotMatchIntake(intakeID)
        }
        if let revision, operation.revision != revision {
            throw IntakeContextEncoderError.operationDoesNotMatchIntake(intakeID)
        }
    }

    /// The product a revision names, or nothing at all.
    ///
    /// The product's name and its nutrient states are hashed as immutable facts of `(intake_id, revision)`, so
    /// a caller that fetched another snapshot would silently make this revision's facts another product's, and
    /// the receiver would reject the retry as a domain conflict.
    private func checkedProduct(
        _ product: ProductDefinition?,
        for revision: IntakeRevision
    ) throws -> ProductDefinition? {
        guard let snapshotID = revision.productSnapshotID else {
            guard product == nil else {
                throw IntakeContextEncoderError.productSnapshotMismatch(expected: nil, found: product?.snapshotID)
            }
            return nil
        }
        guard let product, product.snapshotID == snapshotID else {
            throw IntakeContextEncoderError.productSnapshotMismatch(expected: snapshotID, found: product?.snapshotID)
        }
        return product
    }

    // MARK: - The batch envelope

    /// The scope half of a batch. A digest only reads these five members, so a single operation is hashed
    /// against them before it is given a batch id, which no digest covers.
    private var scopeMembers: [String: IntakeContextJSONValue] {
        [
            "schema": .string(Self.schema),
            "schema_version": .string(Self.schemaVersion),
            "producer_id": .string(scope.producerID),
            "writer_bundle_id": .string(scope.writerBundleID),
            "installation_id": .string(scope.installationID),
        ]
    }

    private var scopePayload: IntakeContextJSONValue {
        .object(scopeMembers)
    }

    private func batchMembers(
        batchID: String,
        operations: [IntakeContextJSONValue]
    ) -> [String: IntakeContextJSONValue] {
        var members = scopeMembers
        members["batch_id"] = .string(batchID)
        members["operations"] = .array(operations)
        return members
    }

    // MARK: - Digests

    /// Adds the three digests to an operation, in the order the contract computes them, and returns the value.
    ///
    /// `client_payload_hash` covers the other two, so it is taken last; `projection_hash` needs the links and
    /// the sequence, and `domain_facts_hash` excludes both, so their order among themselves does not matter.
    private func sealed(
        members: inout [String: IntakeContextJSONValue],
        kind: IntakeContextOperationKind,
        operationID: String,
        intakeID: String,
        revision: Int,
        sequence: Int
    ) throws -> IntakeContextValue {
        let open = IntakeContextJSONValue.object(members)
        var domainFactsHash: String?
        var projectionHash: String?
        if kind != .linkProjection {
            let hash = try IntakeContextDigests.domainFactsHash(batch: scopePayload, operation: open)
            domainFactsHash = hash
            members["domain_facts_hash"] = .string(hash)
        }
        if kind != .delete {
            let hash = try IntakeContextDigests.projectionHash(batch: scopePayload, operation: open)
            projectionHash = hash
            members["projection_hash"] = .string(hash)
        }
        var withDigests = members
        // The client digest covers the operation as sent, without its own member.
        withDigests["client_payload_hash"] = .string(
            try IntakeContextDigests.clientPayloadHash(batch: scopePayload, operation: .object(withDigests)))
        let payload = IntakeContextJSONValue.object(withDigests)
        return IntakeContextValue(
            schemaVersion: Self.schemaVersion,
            scope: scope,
            batchID: nil,
            operations: [
                IntakeContextOperationValue(
                    operationID: operationID,
                    kind: kind,
                    intakeID: intakeID,
                    revision: revision,
                    projectionSequence: sequence,
                    domainFactsHash: domainFactsHash,
                    projectionHash: projectionHash,
                    clientPayloadHash: withDigests["client_payload_hash"]?.stringValue ?? ""
                ),
            ],
            canonicalBytes: IntakeContextCanonicalJSON.encode(payload),
            payload: payload
        )
    }

    // MARK: - Facts

    /// The facts of one revision, in component order, which is part of the hashed content.
    private func encodedFacts(
        of revision: IntakeRevision,
        product: ProductDefinition?
    ) throws -> [IntakeContextJSONValue] {
        guard !revision.components.isEmpty else {
            throw IntakeContextEncoderError.noComponents(revision.intakeID)
        }
        var seen = Set<String>()
        return try revision.components.map { component in
            guard seen.insert(component.componentID).inserted else {
                throw IntakeContextEncoderError.duplicateComponent(component.componentID)
            }
            return try encodedFact(for: component, product: product)
        }
    }

    /// One fact for one journal component.
    ///
    /// The amount is the component's own, because a product snapshot states its values on its own basis rather
    /// than scaled to how much of the product this intake records. What the snapshot does decide is the value
    /// state: a nutrient it states as unknown or below the reporting threshold is encoded as that state with
    /// no amount at all, never as a zero. A nutrient the snapshot does not mention is not limited by it, so
    /// the recorded amount stands.
    private func encodedFact(
        for component: IntakeComponent,
        product: ProductDefinition?
    ) throws -> IntakeContextJSONValue {
        let descriptor = try descriptor(for: component, product: product)
        guard component.amount >= 0 else {
            throw IntakeContextEncoderError.negativeAmount(component.componentID)
        }
        var members: [String: IntakeContextJSONValue] = [
            "component_id": .string(component.componentID),
            "kind": .string(descriptor.kind.rawValue),
            "code": .string(descriptor.code),
            "aggregation_role": .string(descriptor.aggregationRole.intakeContextValue),
            "provenance": .string(descriptor.provenance),
        ]
        // A nutrient's code already names it; a compound and a blend carry the name as printed.
        if descriptor.kind != .nutrient {
            members["label_name"] = .string(component.name)
        }
        // A compound has to state what its amount measures, and a proprietary blend states it too: the blend
        // total is a mass of the blend as printed, which is what makes it a measurement rather than a guess.
        // A nutrient states no basis, because its amount is the nutrient's own.
        if descriptor.kind != .nutrient {
            members["quantity_basis"] = .string(descriptor.quantityBasis.intakeContextValue)
        }
        if descriptor.kind == .blend {
            guard !descriptor.blendMembers.isEmpty else {
                throw IntakeContextEncoderError.blendWithoutMembers(component.componentID)
            }
            members["members"] = .array(descriptor.blendMembers.map(\.object))
        }
        apply(valueState: statedValue(for: descriptor, in: product), to: &members, component: component)
        return .object(members)
    }

    /// What a component means to the contract.
    ///
    /// Any slug is a component: the journal builds its component ids from food names and from recipes, so the
    /// catalog is a set of known overrides rather than a whitelist, and only an id the contract's slug pattern
    /// rejects is refused. A component with no override is a nutrient, because a compound and a blend carry
    /// facts the journal's component does not: a declared basis, and members that the label prints. Its code
    /// follows what it measures, which is also what makes a link to it join: a volume is water, so it is
    /// `hydration`, and anything else is `dietary_<its own name>`. A snapshot attached to the revision means
    /// the value came from the catalog rather than from the user.
    private func descriptor(
        for component: IntakeComponent,
        product: ProductDefinition?
    ) throws -> IntakeContextComponentDescriptor {
        guard JournalValidation.isValidComponentID(component.componentID) else {
            throw IntakeContextEncoderError.invalidComponentID(component.componentID)
        }
        if let known = IntakeContextFactCatalog.descriptor(for: component.componentID) { return known }
        let code = component.unit.dimension == .volume
            ? IntakeContextFactCatalog.hydrationCode
            : "dietary_" + component.componentID.replacingOccurrences(of: "-", with: "_")
        let nutrientKey = product?.nutrients[component.componentID] != nil ? component.componentID : nil
        return IntakeContextComponentDescriptor(
            kind: .nutrient,
            code: code,
            nutrientKey: nutrientKey,
            provenance: product == nil ? "user_confirmed" : "catalog_reference")
    }

    /// Writes the value state, and with it the amount and unit the state allows.
    ///
    /// A nil `valueState` means no source data limits this component, so the recorded amount is the fact.
    /// Otherwise `known` needs both an amount and a unit; `unknown` and `not_applicable` allow neither; a value
    /// below the reporting threshold carries no amount and may still name its unit.
    private func apply(
        valueState: NutrientValue?,
        to members: inout [String: IntakeContextJSONValue],
        component: IntakeComponent
    ) {
        members["value_state"] = .string(stateText(for: valueState))
        switch valueState {
        case .none, .known?:
            // The exact decimal text the journal holds. It is never re-spelled, because the contract hashes the
            // string as written and "5" and "5.0" are different content.
            members["amount"] = .string(DecimalText.encode(component.amount))
            members["unit"] = .string(component.unit.symbol)
        case .belowReportingThreshold(let unit?):
            // No amount: a value below the reporting threshold may still name its unit.
            members["unit"] = .string(unit.symbol)
        case .belowReportingThreshold, .unknown?, .notApplicable?:
            // No amount and no unit: unknown is never written as a zero.
            break
        }
    }

    /// The contract's spelling of a value state. A nil state means no source data limits this component, so
    /// the recorded amount is the fact.
    private func stateText(for valueState: NutrientValue?) -> String {
        guard let valueState else { return "known" }
        return valueState.intakeContextValueState
    }

    /// The state a product snapshot states for this component, or nil when it states none.
    private func statedValue(
        for descriptor: IntakeContextComponentDescriptor,
        in product: ProductDefinition?
    ) -> NutrientValue? {
        guard let key = descriptor.nutrientKey else { return nil }
        return product?.nutrients[key]
    }

    // MARK: - The serving and the display name

    /// The serving the intake was recorded in: the volume it holds, else a count of items, else its first
    /// component. The journal has no serving of its own, so it is derived from the components and the first
    /// rule that matches wins, which keeps the same revision on the same serving.
    private func serving(of revision: IntakeRevision) throws -> IntakeContextJSONValue {
        let components = revision.components
        guard let chosen = components.first(where: { $0.unit.dimension == .volume })
            ?? components.first(where: { $0.unit.dimension == .count })
            ?? components.first
        else {
            throw IntakeContextEncoderError.noComponents(revision.intakeID)
        }
        return .object([
            "amount": .string(DecimalText.encode(chosen.amount)),
            "unit": .string(chosen.unit.symbol),
        ])
    }

    /// What the intake is called: the product's name when a snapshot is attached, else the meal or note the
    /// user wrote, else the category slug. The contract wants a readable name of 1 to 200 characters.
    private func displayName(intake: Intake, product: ProductDefinition?) -> String {
        for candidate in [product?.name, intake.meal, intake.note] {
            if let name = candidate, !name.isEmpty { return name }
        }
        return intake.category
    }

    /// How complete the source data for this intake is, which is not a statement about the day.
    ///
    /// It is `complete` only when the product states a known value for every nutrient the app writes and
    /// nothing recorded is unknown, `partial` when some source data is known, and `unknown` when nothing is.
    /// A snapshot that keeps an unknown entry states the gap, so it never counts as complete however many other
    /// nutrients it fills in.
    private func completeness(product: ProductDefinition?, facts: [IntakeContextJSONValue]) -> String {
        let keys = HealthKitWritePlanner.mappings.map(\.nutrientKey)
        var known = 0
        for key in keys {
            guard let value = product?.nutrients[key], case .known = value else { continue }
            known += 1
        }
        if known > 0 {
            let everyFactKnown = facts.allSatisfy { $0.string("value_state") == "known" }
            return known == keys.count && everyFactKnown ? "complete" : "partial"
        }
        let states = facts.compactMap { $0.string("value_state") }
        return states.contains("known") ? "partial" : "unknown"
    }

    // MARK: - Links

    /// The contract codes of the nutrient facts of an operation, which are the only components a link may name.
    private func nutrientCodes(of facts: [IntakeContextJSONValue]) -> [String: String] {
        var codes: [String: String] = [:]
        for fact in facts {
            guard fact.string("kind") == FactKind.nutrient.rawValue,
                  let componentID = fact.string("component_id"),
                  let code = fact.string("code")
            else { continue }
            codes[componentID] = code
        }
        return codes
    }

    /// The same codes, read from a revision's components rather than from built facts, so a link projection is
    /// checked against the revision it names.
    private func nutrientCodes(of revision: IntakeRevision) throws -> [String: String] {
        var codes: [String: String] = [:]
        for component in revision.components {
            let descriptor = try descriptor(for: component, product: nil)
            guard descriptor.kind == .nutrient else { continue }
            codes[component.componentID] = descriptor.code
        }
        return codes
    }

    /// The link snapshot as the contract writes it.
    ///
    /// A link has to name a nutrient of this revision and its HealthKit type has to be the type that code
    /// lands in: a compound or a blend has no quantity type, so a link to one would never join. The snapshot's
    /// own rules are checked too, because every one of them is a permanent failure at the receiver: a repeated
    /// pair, a sample active on two components, and the sync identity's unique versions, its single active
    /// sample and the rule that an inactive link is never newer than the active one.
    private func linkValues(
        _ links: [IntakeContextLink],
        codes: [String: String]
    ) throws -> [IntakeContextJSONValue] {
        try checkedLinkRules(links)
        return try links.map { link in
            guard let expected = IntakeContextFactCatalog.healthKitTypeIdentifier(forCode: codes[link.componentID] ?? "")
            else {
                throw IntakeContextEncoderError.linkComponentIsNotAFact(link.componentID)
            }
            guard expected == link.healthKitTypeIdentifier else {
                throw IntakeContextEncoderError.linkTypeMismatch(
                    component: link.componentID, expected: expected, found: link.healthKitTypeIdentifier)
            }
            return .object([
                "component_id": .string(link.componentID),
                "healthkit_sample_uuid": .string(link.sampleUUID),
                "healthkit_type": .string(link.healthKitTypeIdentifier),
                "sync_identifier": .string(link.syncIdentifier),
                "sync_version": .integer(String(link.syncVersion)),
                "disposition": .string(link.disposition.rawValue),
            ])
        }
    }

    /// The rules the contract checks across one link snapshot.
    private func checkedLinkRules(_ links: [IntakeContextLink]) throws {
        var seenPairs = Set<String>()
        var versions: [String: Set<Int>] = [:]
        var activeVersions: [String: Int] = [:]
        var activeComponentsBySample: [String: String] = [:]
        for link in links {
            guard link.syncVersion >= 1 else {
                throw IntakeContextEncoderError.invalidSyncVersion(link.syncVersion)
            }
            guard let sample = UUID(uuidString: link.sampleUUID),
                  sample.uuidString.lowercased() == link.sampleUUID else {
                throw IntakeContextEncoderError.invalidSampleUUID(link.sampleUUID)
            }
            guard seenPairs.insert(link.componentID + "|" + link.sampleUUID).inserted else {
                throw IntakeContextEncoderError.duplicateLink(link.componentID + "|" + link.sampleUUID)
            }
            guard versions[link.syncIdentity, default: []].insert(link.syncVersion).inserted else {
                throw IntakeContextEncoderError.duplicateSyncVersion(link.syncIdentifier)
            }
            guard link.disposition != .active else {
                // One sample is never counted for two components, and one sync identity names one object.
                if let component = activeComponentsBySample[link.sampleUUID] {
                    throw IntakeContextEncoderError.sampleActiveOnTwoComponents(
                        sample: link.sampleUUID, first: component, second: link.componentID)
                }
                guard activeVersions[link.syncIdentity] == nil else {
                    throw IntakeContextEncoderError.duplicateActiveLinkForSyncIdentity(link.syncIdentifier)
                }
                activeComponentsBySample[link.sampleUUID] = link.componentID
                activeVersions[link.syncIdentity] = link.syncVersion
                continue
            }
        }
        // A superseded or deleted link is kept for audit and is never newer than the active link it lost to.
        for link in links where link.disposition != .active {
            guard let active = activeVersions[link.syncIdentity], link.syncVersion > active else { continue }
            throw IntakeContextEncoderError.inactiveLinkNewerThanActive(
                syncIdentifier: link.syncIdentifier, active: active, found: link.syncVersion)
        }
    }
}

extension IntakeContextBlendMember {
    /// The member as the contract writes it: a label name, and an amount with its unit only when the label
    /// discloses both.
    var object: IntakeContextJSONValue {
        var members: [String: IntakeContextJSONValue] = ["label_name": .string(labelName)]
        if let amount, let unit {
            members["amount"] = .string(amount)
            members["unit"] = .string(unit)
        }
        return .object(members)
    }
}