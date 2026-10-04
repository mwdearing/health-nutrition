import Foundation
import NutritionDomain

/// Why a journal revision could not be written as an intake-context operation.
///
/// Every case here is a refusal the receiver would make anyway, caught before a digest is taken: an operation
/// that names another intake, a component with no catalog code, a link to a component that is not a fact of the
/// same operation, or a link whose HealthKit type is not the type its fact's code lands in.
public enum IntakeContextEncoderError: Error, Equatable, Sendable {
    /// The revision belongs to another intake than the one it is being encoded with.
    case revisionIntakeMismatch(String)
    /// The outbox operation belongs to another intake, or to another revision, than the ones being encoded.
    case operationDoesNotMatchIntake(String)
    /// An intake with no components has no facts, and the contract requires a non-empty `facts` array.
    case noComponents(String)
    /// The intake's time zone name is not one this platform knows.
    case unknownTimeZone(String)
    /// The catalog has no row for this component, so it has no contract code.
    case unknownComponent(String)
    /// The same component id appears twice in one revision, and the contract requires unique component ids.
    case duplicateComponent(String)
    /// A component amount is negative, and the contract's decimal strings are non-negative.
    case negativeAmount(String)
    /// A blend needs at least one member, and its members are never invented.
    case blendWithoutMembers(String)
    /// A link names a component that is not a nutrient fact of the same upsert.
    case linkComponentIsNotAFact(String)
    /// The same component and sample pair appears twice in one link snapshot.
    case duplicateLink(String)
    /// A link names a sample UUID that is not lowercase canonical UUID text.
    case invalidSampleUUID(String)
    /// A link names a HealthKit type that is not the type its fact's code lands in.
    case linkTypeMismatch(component: String, expected: String, found: String)
    /// A link-only change cannot carry sequence 1: that sequence belongs to the revision's upsert.
    case projectionSequenceMustBeAtLeastTwo(Int)
    /// A batch was asked for with no operations.
    case emptyBatch
    /// The operations given to one batch were not all encoded under the same producer scope.
    case scopeMismatch
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
    /// The app installation that sent the batch.
    public let installationID: String

    public init(producerID: String, writerBundleID: String, installationID: String) {
        self.producerID = producerID
        self.writerBundleID = writerBundleID
        self.installationID = installationID
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
    /// The outbox operation's id, which is the delivery identity of this operation.
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
    /// `operation` is the outbox row this delivery is made under, and its `operation_id` is the delivery
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
        guard revision.intakeID == intake.id else {
            throw IntakeContextEncoderError.revisionIntakeMismatch(intake.id)
        }
        guard operation.intakeID == intake.id, operation.revision == revision.number else {
            throw IntakeContextEncoderError.operationDoesNotMatchIntake(intake.id)
        }
        let facts = try encodedFacts(of: revision, product: product)
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
            "display_name": .string(displayName(intake: intake, product: product)),
            "serving": try serving(of: revision),
            "facts": .array(facts),
            "healthkit_links": .array(try linkValues(links ?? [], of: facts)),
            "nutrition_completeness": .string(completeness(product: product, facts: facts)),
        ]
        return try sealed(members: &members, kind: .upsert, operationID: operation.operationID,
            intakeID: intake.id, revision: revision.number, sequence: 1)
    }

    /// The `delete` for a deleted intake: a higher revision and nothing else.
    ///
    /// It carries no food details, no facts and no links, and the receiver keeps it as a tombstone so that a
    /// delayed older upsert cannot resurrect the intake. `deletedAt` is an instant, so it is written in UTC.
    public func delete(
        intake: Intake,
        revision: IntakeRevision,
        operation: OutboxOperation,
        deletedAt: Date
    ) throws -> IntakeContextValue {
        guard revision.intakeID == intake.id else {
            throw IntakeContextEncoderError.revisionIntakeMismatch(intake.id)
        }
        guard operation.intakeID == intake.id, operation.revision == revision.number else {
            throw IntakeContextEncoderError.operationDoesNotMatchIntake(intake.id)
        }
        var members: [String: IntakeContextJSONValue] = [
            "operation_id": .string(operation.operationID),
            "operation": .string(IntakeContextOperationKind.delete.contractValue),
            "intake_id": .string(intake.id),
            "revision": .integer(String(revision.number)),
            "deleted_at": .string(IntakeContextTimestamp.utc(deletedAt)),
        ]
        return try sealed(members: &members, kind: .delete, operationID: operation.operationID,
            intakeID: intake.id, revision: revision.number, sequence: 0)
    }

    /// The `link_projection` for a link-only change to a revision whose facts are already accepted.
    ///
    /// A later HealthKit save can reveal a sample UUID after the facts were accepted. The operation carries the
    /// complete link snapshot, never a delta, and no facts and no domain digest, so the receiver checks each
    /// link's component against the stored target revision. Sequence 1 belongs to the revision's upsert, so a
    /// link-only change starts at 2.
    public func linkProjection(
        intake: Intake,
        revision: IntakeRevision,
        sequence: Int,
        operation: OutboxOperation,
        links: [IntakeContextLink]
    ) throws -> IntakeContextValue {
        guard revision.intakeID == intake.id else {
            throw IntakeContextEncoderError.revisionIntakeMismatch(intake.id)
        }
        guard operation.intakeID == intake.id, operation.revision == revision.number else {
            throw IntakeContextEncoderError.operationDoesNotMatchIntake(intake.id)
        }
        guard sequence >= 2 else {
            throw IntakeContextEncoderError.projectionSequenceMustBeAtLeastTwo(sequence)
        }
        var members: [String: IntakeContextJSONValue] = [
            "operation_id": .string(operation.operationID),
            "operation": .string(IntakeContextOperationKind.linkProjection.contractValue),
            "intake_id": .string(intake.id),
            "revision": .integer(String(revision.number)),
            "projection_sequence": .integer(String(sequence)),
            "healthkit_links": .array(try linkValues(links, of: nil)),
        ]
        return try sealed(members: &members, kind: .linkProjection, operationID: operation.operationID,
            intakeID: intake.id, revision: revision.number, sequence: sequence)
    }

    /// One batch carrying the given operations in the order they are sent.
    ///
    /// The receiver applies the operations in array order, and each one sees the effects of the ones before it,
    /// so the order is the caller's decision and this method keeps it. Every operation must have been encoded
    /// under this encoder's scope, because `client_payload_hash` covers the scope the operation was hashed
    /// under and a batch may not mix them.
    public func batch(batchID: String, operations: [IntakeContextValue]) throws -> IntakeContextValue {
        guard !operations.isEmpty else { throw IntakeContextEncoderError.emptyBatch }
        for value in operations {
            guard value.scope == scope, value.schemaVersion == Self.schemaVersion else {
                throw IntakeContextEncoderError.scopeMismatch
            }
        }
        let payload = IntakeContextJSONValue.object(
            batchMembers(batchID: batchID, operations: operations.map(\.payload)))
        return IntakeContextValue(
            schemaVersion: Self.schemaVersion,
            scope: scope,
            batchID: batchID,
            operations: operations.flatMap(\.operations),
            canonicalBytes: IntakeContextCanonicalJSON.encode(payload),
            payload: payload
        )
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
        guard let descriptor = IntakeContextFactCatalog.descriptor(for: component.componentID) else {
            throw IntakeContextEncoderError.unknownComponent(component.componentID)
        }
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
        if descriptor.kind == .compound {
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
    /// It is `complete` only when a product snapshot states a known value for every nutrient the app writes and
    /// nothing recorded is unknown, `partial` when some source data is known, and `unknown` when nothing is.
    private func completeness(product: ProductDefinition?, facts: [IntakeContextJSONValue]) -> String {
        let keys = HealthKitWritePlanner.mappings.map(\.nutrientKey)
        var stated = 0
        var known = 0
        for key in keys {
            guard let value = product?.nutrients[key] else { continue }
            stated += 1
            if case .known = value { known += 1 }
        }
        if known > 0 {
            return stated == keys.count ? "complete" : "partial"
        }
        let states = facts.compactMap { $0.string("value_state") }
        return states.contains("known") ? "partial" : "unknown"
    }

    // MARK: - Links

    /// The link snapshot as the contract writes it.
    ///
    /// When `facts` is given, a link has to name a nutrient fact of the same operation and its HealthKit type
    /// has to be the type that fact's code lands in: a compound or a blend has no quantity type, so a link to
    /// one would never join. A link-only change carries no facts of its own, and the receiver checks the same
    /// thing against the stored target revision.
    private func linkValues(
        _ links: [IntakeContextLink],
        of facts: [IntakeContextJSONValue]?
    ) throws -> [IntakeContextJSONValue] {
        var seen = Set<String>()
        return try links.map { link in
            guard let sample = UUID(uuidString: link.sampleUUID),
                  sample.uuidString.lowercased() == link.sampleUUID else {
                throw IntakeContextEncoderError.invalidSampleUUID(link.sampleUUID)
            }
            let pair = link.componentID + "|" + link.sampleUUID
            guard seen.insert(pair).inserted else {
                throw IntakeContextEncoderError.duplicateLink(pair)
            }
            if let facts {
                let code = try factCode(for: link.componentID, in: facts)
                if let expected = IntakeContextFactCatalog.healthKitTypeIdentifier(forCode: code),
                   expected != link.healthKitTypeIdentifier {
                    throw IntakeContextEncoderError.linkTypeMismatch(
                        component: link.componentID, expected: expected, found: link.healthKitTypeIdentifier)
                }
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

    private func factCode(for componentID: String, in facts: [IntakeContextJSONValue]) throws -> String {
        for fact in facts {
            guard fact.string("component_id") == componentID else { continue }
            guard fact.string("kind") == FactKind.nutrient.rawValue else {
                throw IntakeContextEncoderError.linkComponentIsNotAFact(componentID)
            }
            guard let code = fact.string("code") else {
                throw IntakeContextEncoderError.unknownComponent(componentID)
            }
            return code
        }
        throw IntakeContextEncoderError.linkComponentIsNotAFact(componentID)
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