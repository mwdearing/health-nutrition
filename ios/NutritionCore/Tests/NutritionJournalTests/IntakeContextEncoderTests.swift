import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The journal to intake-context encoder (NC-09B).
///
/// The receiver recomputes all three digests from the operation it received and rejects a mismatch, so these
/// tests hold the encoder against the contract's own fixtures: `valid_worked_example.json`,
/// `valid_delete.json` and `valid_link_projection_seq2.json` are rebuilt from journal types and their canonical
/// bytes compared byte for byte. Every UUID, bundle id, sample and product here is synthetic test data.
final class IntakeContextEncoderTests: XCTestCase {
    private let intakeID = "e6677963-418c-4027-b563-551d8a531eed"

    private static let scope = IntakeContextProducerScope(
        producerID: "nutrition-app",
        writerBundleID: "com.example.healthrelay.nutrition",
        installationID: "507b8fbb-78d3-450c-a88f-487e90df92e6")

    private var encoder: IntakeContextEncoder { IntakeContextEncoder(scope: Self.scope) }

    // MARK: - The contract's worked example, rebuilt from journal types

    /// A 500 mL water drink with 5 g of creatine monohydrate at revision 2, encoded from nothing but the
    /// journal's own types, is the fixture byte for byte.
    func testWorkedExampleIsRebuiltFromJournalTypesWithTheFixtureCanonicalBytes() throws {
        let value = try encoder.batch(
            batchID: "0bda35fc-3eab-47ce-9e31-c684343dd8d7",
            operations: [try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: upsertOperation,
                links: [waterLink(disposition: .active, sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429", syncVersion: 2)])])
        XCTAssertEqual(value.canonicalBytes, try Self.fixtureCanonicalBytes(named: "valid_worked_example.json"))
        let operation = try XCTUnwrap(value.operations.first)
        XCTAssertEqual(operation.kind, .upsert)
        XCTAssertEqual(operation.operationID, "8b8719ea-6bb3-4dd4-8508-a63ee33d1381")
        XCTAssertEqual(operation.intakeID, intakeID)
        XCTAssertEqual(operation.revision, 2)
        // An upsert opens the projection lifecycle of its revision, so it is always sequence 1.
        XCTAssertEqual(operation.projectionSequence, 1)
    }

    /// The three digests the encoder computed are the fixture's, which is the only thing that matters to the
    /// receiver: it recomputes them from the operation it received.
    func testWorkedExampleDigestsEqualTheFixtureHashes() throws {
        let operation = try encoder.upsert(
            intake: intake,
            revision: waterAndCreatineRevision,
            product: product,
            operation: upsertOperation,
            links: [waterLink(disposition: .active, sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429", syncVersion: 2)])
        let fixture = try Self.operations(of: Self.fixture(named: "valid_worked_example.json")).first
        XCTAssertEqual(operation.operations.first?.domainFactsHash, try fixture?.string(named: "domain_facts_hash"))
        XCTAssertEqual(operation.operations.first?.projectionHash, try fixture?.string(named: "projection_hash"))
        XCTAssertEqual(
            operation.operations.first?.clientPayloadHash, try fixture?.string(named: "client_payload_hash"))
    }

    /// A delete at a higher revision carries the tombstone and nothing else: no food details, no facts, no
    /// links, and no projection digest.
    func testDeleteIsRebuiltFromJournalTypesWithTheFixtureCanonicalBytes() throws {
        let deleted = Intake(
            id: intakeID,
            category: "beverage",
            occurredAt: intake.occurredAt,
            timeZoneIdentifier: intake.timeZoneIdentifier,
            lifecycle: .deleted,
            currentRevision: 3)
        let deletion = try encoder.delete(
            intake: deleted,
            revision: waterAndCreatineRevision(number: 3, components: nil),
            operation: outboxOperation(id: "c1f4a7d2-93be-4e65-8d0a-2b6f1e7c9a35", kind: .delete, revision: 3),
            deletedAt: Self.deletedAt)
        // Read back through the reader the receiver's own document would go through, so the assertions are on
        // the bytes that are sent rather than on the encoder's own view of them.
        let encoded = try Self.read(deletion)
        XCTAssertNotNil(encoded.member("deleted_at"))
        XCTAssertNil(encoded.member("facts"), "a delete carries no food details")
        XCTAssertNil(encoded.member("healthkit_links"), "a delete carries no links")
        XCTAssertNil(encoded.member("display_name"))
        let value = try encoder.batch(
            batchID: "5f0e8a2c-6d41-4b0e-9c3a-7a1d2b9e4f10",
            operations: [deletion])
        XCTAssertEqual(value.canonicalBytes, try Self.fixtureCanonicalBytes(named: "valid_delete.json"))
        let operation = try XCTUnwrap(value.operations.first)
        XCTAssertEqual(operation.kind, .delete)
        XCTAssertEqual(operation.revision, 3)
        XCTAssertNotNil(operation.domainFactsHash)
        XCTAssertNil(operation.projectionHash, "a delete has no links, so it has no projection digest")
    }

    /// A link-only change after a later HealthKit save revealed a sample UUID is the third fixture, again byte
    /// for byte, with the complete snapshot rather than a delta and no facts at all.
    func testLinkProjectionCarriesTheCompleteSnapshotAndNoFacts() throws {
        let projection = try encoder.linkProjection(
            intake: intake,
            revision: waterAndCreatineRevision,
            sequence: 2,
            operation: outboxOperation(id: "d94b6e18-27c3-4a5f-8e91-b0f3a6c2d587", kind: .upsert, revision: 2),
            links: [
                waterLink(disposition: .active, sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396", syncVersion: 3),
                waterLink(disposition: .superseded, sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429", syncVersion: 2),
            ])
        let encoded = try Self.read(projection)
        XCTAssertNil(encoded.member("facts"), "a link projection carries no facts at all")
        XCTAssertNil(encoded.member("domain_facts_hash"), "and so no domain digest")
        XCTAssertEqual(try XCTUnwrap(encoded.array("healthkit_links")).count, 2, "the complete snapshot, not a delta")
        let value = try encoder.batch(
            batchID: "a3c9d1e7-4b25-4f8a-b6d0-18e5c7f2a940",
            operations: [projection])
        XCTAssertEqual(value.canonicalBytes, try Self.fixtureCanonicalBytes(named: "valid_link_projection_seq2.json"))
        let operation = try XCTUnwrap(value.operations.first)
        XCTAssertEqual(operation.kind, .linkProjection)
        XCTAssertEqual(operation.projectionSequence, 2)
        XCTAssertNil(operation.domainFactsHash, "a link projection carries no facts, so no domain digest")
        XCTAssertNotNil(operation.projectionHash)
    }

    // MARK: - Facts

    /// The amounts go out as the exact decimal text the journal holds: no rounding, no rescaling and no
    /// floating point on the way, because the contract hashes the string as written and "5" and "5.0" are
    /// different content.
    func testDecimalSpellingsAreKeptAsGiven() throws {
        let revision = waterAndCreatineRevision(components: [
            IntakeComponent(componentID: "water", name: "Water", amount: try XCTUnwrap(DecimalText.decode("250")), unit: .mL),
            IntakeComponent(
                componentID: "creatine-monohydrate",
                name: "Creatine monohydrate",
                amount: try XCTUnwrap(DecimalText.decode("5.25")),
                unit: .g),
        ])
        let value = try encoder.upsert(
            intake: intake, revision: revision, product: product, operation: upsertOperation)
        XCTAssertEqual(amounts(of: value), ["250", "5.25"])
        // A journal that stored a trailing zero keeps it: what the decimal spells is what is sent, because the
        // receiver would read a respelled amount as different facts at the same identity.
        let trailingZero = try XCTUnwrap(DecimalText.decode("5.0"))
        let respelled = try encoder.upsert(
            intake: intake,
            revision: waterAndCreatineRevision(components: [
                IntakeComponent(componentID: "creatine-monohydrate", name: "Creatine monohydrate", amount: trailingZero, unit: .g),
                IntakeComponent(componentID: "water", name: "Water", amount: try XCTUnwrap(DecimalText.decode("250")), unit: .mL),
            ]),
            product: product,
            operation: upsertOperation)
        XCTAssertEqual(amounts(of: respelled)[1], DecimalText.encode(trailingZero))
        XCTAssertFalse(DecimalText.encode(trailingZero).contains("e"), "an amount is never an exponent")
    }

    /// A nutrient the product snapshot does not state is unknown, and unknown is never written as a zero: the
    /// fact carries its state and no amount at all.
    func testAnUnknownNutrientIsStatedUnknownAndNeverZero() throws {
        let undisclosed = ProductDefinition(
            snapshotID: "snapshot-undisclosed-water",
            productID: "product-undisclosed-water",
            name: "Water with creatine",
            labelBasis: "per_serving",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1",
            nutrients: ["water": NutrientValue.unknown])
        let value = try encoder.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: undisclosed, operation: upsertOperation)
        let water = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue?.first)
        XCTAssertEqual(water.string("value_state"), "unknown")
        XCTAssertNil(water.member("amount"), "an unknown value has no amount, and above all not a zero")
        XCTAssertNil(water.member("unit"))
        let canonical = String(decoding: value.canonicalBytes, as: UTF8.self)
        XCTAssertFalse(canonical.contains("\"amount\":\"0\""), "unknown is never zero")
        // The compound beside it is still measured, and a partial source says so.
        let creatine = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue?.last)
        XCTAssertEqual(creatine.string("value_state"), "known")
        XCTAssertEqual(creatine.string("amount"), "5")
        XCTAssertEqual(value.member("nutrition_completeness")?.stringValue, "partial")
    }

    /// A compound states the basis its amount measures and the name as printed; a proprietary blend is one fact
    /// with its stated total and its named members, and never an invented member amount.
    func testCompoundAndBlendFactsCarryTheirBasisAndMembers() throws {
        let revision = IntakeRevision(
            intakeID: intakeID,
            number: 1,
            components: [
                IntakeComponent(
                    componentID: "energy-blend",
                    name: "Energy Blend",
                    amount: try XCTUnwrap(DecimalText.decode("1500")),
                    unit: .mg),
                IntakeComponent(componentID: "water", name: "Water", amount: try XCTUnwrap(DecimalText.decode("500")), unit: .mL),
            ],
            productSnapshotID: "snapshot-blend",
            changeReason: "Logged from the label",
            createdAt: Self.labelReadAt)
        let value = try encoder.upsert(
            intake: intake,
            revision: revision,
            product: nil,
            operation: outboxOperation(id: "f6a0c3e9-5b72-4d18-9c4e-a83d1b7f2e60", kind: .upsert, revision: 1))
        let facts = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue)
        let blend = facts[0]
        XCTAssertEqual(blend.string("kind"), "blend")
        XCTAssertEqual(blend.string("code"), "proprietary_energy_blend")
        XCTAssertEqual(blend.string("label_name"), "Energy Blend")
        XCTAssertEqual(blend.string("aggregation_role"), "blend_total_only")
        XCTAssertEqual(blend.string("quantity_basis"), "compound_mass")
        let members = try XCTUnwrap(blend.array("members"))
        XCTAssertEqual(members.count, 3)
        for member in members {
            XCTAssertNotNil(member.string("label_name"))
            XCTAssertNil(member.member("amount"), "an undisclosed member amount is never invented")
        }
        // A nutrient's code already names it, so it carries no label name of its own.
        let water = facts[1]
        XCTAssertEqual(water.string("kind"), "nutrient")
        XCTAssertEqual(water.string("code"), "hydration")
        XCTAssertEqual(water.string("aggregation_role"), "context_only")
        XCTAssertNil(water.member("label_name"))
        let compound = try encoder.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        let creatine = try XCTUnwrap(try XCTUnwrap(compound.member("facts"))?.arrayValue?.last)
        XCTAssertEqual(creatine.string("kind"), "compound")
        XCTAssertEqual(creatine.string("quantity_basis"), "compound_mass")
        XCTAssertEqual(creatine.string("aggregation_role"), "compound_measurement")
        XCTAssertEqual(creatine.string("label_name"), "Creatine monohydrate")
    }

    // MARK: - Links and scope

    /// A link snapshot is carried when the write plan gave one and is empty when it did not. The field is
    /// always present, because the contract requires it: an empty snapshot is how this app says nothing has
    /// been linked yet, which is not the same as having no snapshot.
    func testLinksAreCarriedOnlyWhenTheyAreGiven() throws {
        let withoutLinks = try encoder.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        XCTAssertEqual(try XCTUnwrap(withoutLinks.member("healthkit_links")).arrayValue?.count, 0)
        XCTAssertNotNil(withoutLinks.member("healthkit_links"), "the field is required even when it is empty")

        let withLinks = try encoder.upsert(
            intake: intake,
            revision: waterAndCreatineRevision,
            product: product,
            operation: upsertOperation,
            links: [waterLink(disposition: .active, sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429", syncVersion: 2)])
        let links = try XCTUnwrap(try XCTUnwrap(withLinks.member("healthkit_links"))?.arrayValue)
        XCTAssertEqual(links.count, 1)
        let link = links[0]
        XCTAssertEqual(link.string("component_id"), "water")
        XCTAssertEqual(link.string("healthkit_sample_uuid"), "2c932bd1-c46d-4e38-b481-e0d842fdd429")
        XCTAssertEqual(link.string("healthkit_type"), "HKQuantityTypeIdentifierDietaryWater")
        XCTAssertEqual(
            link.string("sync_identifier"), HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"))
        XCTAssertEqual(link.member("sync_version"), .integer("2"))
        XCTAssertEqual(link.string("disposition"), "active")
    }

    /// The batch carries the producer scope the encoder was given, and only that: a different installation moves
    /// the client digest and nothing else, because `installation_id` is provenance and never enters the domain
    /// digest.
    func testBatchScopeComesFromTheInjectedProducerScope() throws {
        let mine = try encoder.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        let batch = try encoder.batch(batchID: "0bda35fc-3eab-47ce-9e31-c684343dd8d7", operations: [mine])
        XCTAssertEqual(batch.member("schema")?.stringValue, "healthrelay.intake-context")
        XCTAssertEqual(batch.member("schema_version")?.stringValue, "1.0")
        XCTAssertEqual(batch.member("producer_id")?.stringValue, "nutrition-app")
        XCTAssertEqual(batch.member("writer_bundle_id")?.stringValue, "com.example.healthrelay.nutrition")
        XCTAssertEqual(batch.member("installation_id")?.stringValue, "507b8fbb-78d3-450c-a88f-487e90df92e6")
        XCTAssertEqual(batch.member("batch_id")?.stringValue, "0bda35fc-3eab-47ce-9e31-c684343dd8d7")

        // A reinstalled app sends the same facts from another installation, so the domain digest is unchanged
        // and only the client digest moves.
        let reinstalled = try IntakeContextEncoder(scope: IntakeContextProducerScope(
            producerID: "nutrition-app",
            writerBundleID: "com.example.healthrelay.nutrition",
            installationID: "00000000-0000-4000-8000-000000000001")).upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        XCTAssertEqual(mine.operations.first?.domainFactsHash, reinstalled.operations.first?.domainFactsHash)
        XCTAssertNotEqual(mine.operations.first?.clientPayloadHash, reinstalled.operations.first?.clientPayloadHash)

        // The same intake id from another producer is another set of facts, never the same identity.
        let theirs = try IntakeContextEncoder(scope: IntakeContextProducerScope(
            producerID: "another-producer",
            writerBundleID: "com.example.healthrelay.another",
            installationID: "507b8fbb-78d3-450c-a88f-487e90df92e6")).upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        XCTAssertNotEqual(mine.operations.first?.domainFactsHash, theirs.operations.first?.domainFactsHash)
        // A batch may not mix scopes: the operations would have been hashed under a scope the batch denies.
        XCTAssertThrowsError(
            try encoder.batch(batchID: "1e2f3a4b-5c6d-4e8f-9a0b-1c2d3e4f5a6b", operations: [theirs])
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .scopeMismatch)
        }
    }

    // MARK: - Determinism and refusals

    /// Encoding is pure: the same journal revision encoded twice, and by a second encoder, gives the same bytes
    /// every time. That is what makes a retry of one revision a duplicate rather than a conflict.
    func testEncodingIsDeterministic() throws {
        let first = try encoder.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        let second = try IntakeContextEncoder(scope: Self.scope).upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        XCTAssertEqual(first.canonicalBytes, second.canonicalBytes)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try encoder.batch(batchID: "0bda35fc-3eab-47ce-9e31-c684343dd8d7", operations: [first]).canonicalBytes,
            try encoder.batch(batchID: "0bda35fc-3eab-47ce-9e31-c684343dd8d7", operations: [second]).canonicalBytes)
    }

    /// The encoder refuses what the receiver would refuse, so a refusal here is never a payload sent for nothing.
    func testRefusalsCatchWhatTheReceiverWouldReject() throws {
        // An outbox row for another intake or another revision is not this revision's operation.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: outboxOperation(id: "8b8719ea-6bb3-4dd4-8508-a63ee33d1381", kind: .upsert, revision: 1))
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .operationDoesNotMatchIntake(intakeID))
        }
        // A component with no catalog row has no contract code, and none is invented for it.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision(components: [
                    IntakeComponent(componentID: "oats", name: "Oats", amount: try XCTUnwrap(DecimalText.decode("50")), unit: .g),
                ]),
                product: nil,
                operation: upsertOperation)
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .unknownComponent("oats"))
        }
        // A link to a compound would never join: a compound has no HealthKit quantity type.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: upsertOperation,
                links: [IntakeContextLink(
                    componentID: "creatine-monohydrate",
                    sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                    healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                    syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "creatine-monohydrate"),
                    syncVersion: 2,
                    disposition: .active)])
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .linkComponentIsNotAFact("creatine-monohydrate"))
        }
        // A link whose type is not the one its fact's code lands in cannot join either.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: upsertOperation,
                links: [IntakeContextLink(
                    componentID: "water",
                    sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                    healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietarySodium",
                    syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
                    syncVersion: 2,
                    disposition: .active)])
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .linkTypeMismatch(
                    component: "water",
                    expected: "HKQuantityTypeIdentifierDietaryWater",
                    found: "HKQuantityTypeIdentifierDietarySodium"))
        }
        // Sequence 1 belongs to the revision's upsert.
        XCTAssertThrowsError(
            try encoder.linkProjection(
                intake: intake,
                revision: waterAndCreatineRevision,
                sequence: 1,
                operation: upsertOperation,
                links: [waterLink(disposition: .active, sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429", syncVersion: 2)])
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .projectionSequenceMustBeAtLeastTwo(1))
        }
        // A revision with no components has no facts, and the contract requires a non-empty array.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision(components: []),
                product: nil,
                operation: upsertOperation)
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .noComponents(intakeID))
        }
    }

    // MARK: - The journal types the fixtures are rebuilt from

    /// 2026-09-30T17:30:00Z is the worked example's `occurred_at` of 12:30 in `America/Chicago`, whose offset
    /// that day is -05:00.
    private static let occurredAt = Date(timeIntervalSince1970: 1_790_789_400)
    /// 2026-09-30T17:31:02Z, the revision's `recorded_at`.
    private static let recordedAt = Date(timeIntervalSince1970: 1_790_789_462)
    /// 2026-09-30T12:46:10Z, the proprietary blend example's `recorded_at`.
    private static let labelReadAt = Date(timeIntervalSince1970: 1_790_772_370)
    /// 2026-09-30T18:05:00Z, the delete fixture's `deleted_at`.
    private static let deletedAt = Date(timeIntervalSince1970: 1_790_791_500)

    private var intake: Intake {
        Intake(
            id: intakeID,
            category: "beverage",
            occurredAt: Self.occurredAt,
            timeZoneIdentifier: "America/Chicago")
    }

    private var waterAndCreatineRevision: IntakeRevision {
        waterAndCreatineRevision(number: 2, components: nil)
    }

    private func waterAndCreatineRevision(number: Int = 2, components: [IntakeComponent]?) -> IntakeRevision {
        IntakeRevision(
            intakeID: intakeID,
            number: number,
            components: components ?? [
                IntakeComponent(componentID: "water", name: "Water", amount: 500, unit: .mL),
                IntakeComponent(componentID: "creatine-monohydrate", name: "Creatine monohydrate", amount: 5, unit: .g),
            ],
            productSnapshotID: "snapshot-water-creatine",
            changeReason: "Added the creatine",
            createdAt: Self.recordedAt)
    }

    /// The product snapshot carries exactly the fixture's values: it names the drink and states the water it
    /// holds, which is what makes this source partial rather than complete.
    private var product: ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-water-creatine",
            productID: "product-water-creatine",
            name: "Water with creatine",
            labelBasis: "per_serving",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1",
            nutrients: ["water": NutrientValue.known(500, .mL)])
    }

    private var upsertOperation: OutboxOperation {
        outboxOperation(id: "8b8719ea-6bb3-4dd4-8508-a63ee33d1381", kind: .upsert, revision: 2)
    }

    private func outboxOperation(id: String, kind: OutboxKind, revision: Int) -> OutboxOperation {
        OutboxOperation(
            operationID: id,
            kind: kind,
            intakeID: intakeID,
            revision: revision,
            destination: .relay,
            payloadHash: "sha256:" + String(repeating: "0", count: 64))
    }

    private func waterLink(
        disposition: IntakeContextLinkDisposition,
        sampleUUID: String,
        syncVersion: Int
    ) -> IntakeContextLink {
        IntakeContextLink(
            componentID: "water",
            sampleUUID: sampleUUID,
            healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
            // ADR 0002: one sync identifier per (intake, nutrient), the same one the writer saved with.
            syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
            syncVersion: syncVersion,
            disposition: disposition)
    }

    /// A single operation's canonical bytes read back as a payload, so a test can assert on the members of the
    /// operation that is sent rather than on the encoder's own view of it.
    private static func read(_ value: IntakeContextValue) throws -> IntakeContextJSONValue {
        try IntakeContextJSONReader.read(value.canonicalBytes)
    }

    /// The amounts of a value's facts, in fact order.
    private func amounts(of value: IntakeContextValue) -> [String] {
        (value.payload.array("facts") ?? []).compactMap { $0.string("amount") }
    }

    // MARK: - Fixture helpers

    /// `contracts/intake-context/fixtures` walked up from this file, the same way the digest test finds it, so
    /// the committed fixtures are the ones under test.
    private static func fixtureDirectory(file: StaticString = #filePath) -> URL? {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("contracts/intake-context/fixtures")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    private static func fixture(named name: String, file: StaticString = #filePath) throws -> IntakeContextJSONValue {
        let directory = try XCTUnwrap(fixtureDirectory(file: file), "contracts/intake-context/fixtures is missing")
        return try IntakeContextJSONReader.read(Data(contentsOf: directory.appendingPathComponent(name)))
    }

    /// A fixture's canonical bytes, which is what the encoder's own canonical bytes are compared against: the
    /// comparison is on the bytes the receiver hashes, not on the fixture's formatting.
    private static func fixtureCanonicalBytes(named name: String, file: StaticString = #filePath) throws -> Data {
        IntakeContextCanonicalJSON.encode(try fixture(named: name, file: file))
    }

    private static func operations(of batch: IntakeContextJSONValue) throws -> [IntakeContextJSONValue] {
        try batch.array(named: "operations")
    }
}