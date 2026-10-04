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

    /// A delete carries the tombstone and nothing else: no food details, no facts, no links, and no projection
    /// digest. It stands one revision above the last accepted upsert, which is what the receiver requires of a
    /// tombstone and what the contract fixture encodes.
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
            revision: waterAndCreatineRevision,
            tombstone: IntakeContextTombstone(intakeID: intakeID, deletedAt: Self.deletedAt),
            operation: outboxOperation(id: "c1f4a7d2-93be-4e65-8d0a-2b6f1e7c9a35", kind: .delete, revision: 3))
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
            product: product,
            sequence: 2,
            links: [
                waterLink(disposition: .active, sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396", syncVersion: 3),
                waterLink(disposition: .superseded, sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429", syncVersion: 2),
            ],
            operationID: "d94b6e18-27c3-4a5f-8e91-b0f3a6c2d587")
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
        let waterAmount = try XCTUnwrap(DecimalText.decode("250"))
        let creatineAmount = try XCTUnwrap(DecimalText.decode("5.25"))
        let revision = waterAndCreatineRevision(components: [
            IntakeComponent(componentID: "water", name: "Water", amount: waterAmount, unit: .mL),
            IntakeComponent(componentID: "creatine-monohydrate", name: "Creatine monohydrate", amount: creatineAmount, unit: .g),
        ])
        let value = try encoder.upsert(
            intake: intake, revision: revision, product: product, operation: upsertOperation)
        // Facts are looked up by component id, because the contract makes their order part of the content and a
        // fact's position says nothing about which fact it is.
        XCTAssertEqual(amount(ofComponent: "water", in: value), "250")
        XCTAssertEqual(amount(ofComponent: "creatine-monohydrate", in: value), "5.25")
        // What is sent is exactly the spelling the journal spells, byte for byte. The journal keeps an exact
        // decimal rather than text, so `DecimalText.encode` is the one rule the whole app spells amounts with,
        // and the encoder may not respell a value the receiver would read as different facts at the same
        // identity.
        XCTAssertEqual(amount(ofComponent: "creatine-monohydrate", in: value), DecimalText.encode(creatineAmount))
        XCTAssertEqual(amount(ofComponent: "water", in: value), DecimalText.encode(waterAmount))
        // An amount is a decimal string in the payload, never a JSON number and never an exponent.
        let canonical = String(decoding: value.canonicalBytes, as: UTF8.self)
        XCTAssertTrue(canonical.contains("\"amount\":\"250\""))
        XCTAssertTrue(canonical.contains("\"amount\":\"5.25\""))
        XCTAssertFalse(canonical.contains("\"amount\":250"), "an amount never crosses the wire as a number")
        XCTAssertFalse(canonical.contains("e+"), "an amount is never an exponent")
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
            intake: intake,
            revision: waterAndCreatineRevision(productSnapshotID: "snapshot-undisclosed-water"),
            product: undisclosed,
            operation: upsertOperation)
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
            productSnapshotID: nil,
            changeReason: "Logged from the label",
            createdAt: Self.labelReadAt)
        let value = try encoder.upsert(
            intake: intake,
            revision: revision,
            product: nil,
            operation: outboxOperation(id: "f6a0c3e9-5b72-4d18-9c4e-a83d1b7f2e60", kind: .upsert, revision: 1))
        let facts = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue)
        // The contract makes the order of `facts` part of the content, and the journal's component order is
        // the order the receiver hashes, so the encoder never sorts them.
        XCTAssertEqual(facts.map { $0.string("component_id") }, ["energy-blend", "water"])
        let blend = facts[0]
        XCTAssertEqual(blend.string("kind"), "blend")
        XCTAssertEqual(blend.string("code"), "proprietary_energy_blend")
        XCTAssertEqual(blend.string("label_name"), "Energy Blend")
        XCTAssertEqual(blend.string("aggregation_role"), "blend_total_only")
        // A blend states what its total measures, exactly as the contract's own blend fixture does.
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
        // A component id that is not a slug cannot be a contract component id, so it is refused.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision(components: [
                    IntakeComponent(componentID: "Rolled oats", name: "Rolled oats", amount: try XCTUnwrap(DecimalText.decode("50")), unit: .g),
                ], productSnapshotID: nil),
                product: nil,
                operation: upsertOperation)
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .invalidComponentID("Rolled oats"))
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
                product: nil,
                sequence: 1,
                links: [waterLink(disposition: .active, sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429", syncVersion: 2)])
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .projectionSequenceMustBeAtLeastTwo(1))
        }
        // A revision with no components has no facts, and the contract requires a non-empty array.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                // No components and no product snapshot, so this input exercises one rule only: the missing
                // facts. A revision that named a snapshot and carried none would be refused for that instead.
                revision: waterAndCreatineRevision(components: [], productSnapshotID: nil),
                product: nil,
                operation: upsertOperation)
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .noComponents(intakeID))
        }
    }

    // MARK: - What the contract requires of a tombstone

    /// A tombstone has to stand above every accepted revision, or the receiver rejects it instead of keeping
    /// it, so the delete is written at one above the revision it deletes.
    func testDeleteIsWrittenOneRevisionAboveTheLastAcceptedRevision() throws {
        let lastUpsert = waterAndCreatineRevision
        let upsert = try encoder.upsert(
            intake: intake, revision: lastUpsert, product: product, operation: upsertOperation)
        let deletion = try encoder.delete(
            intake: intake,
            revision: lastUpsert,
            tombstone: IntakeContextTombstone(intakeID: intakeID, deletedAt: Self.deletedAt),
            operation: outboxOperation(id: "c1f4a7d2-93be-4e65-8d0a-2b6f1e7c9a35", kind: .delete, revision: 3))
        let tombstone = try XCTUnwrap(deletion.operations.first?.revision)
        XCTAssertGreaterThan(tombstone, try XCTUnwrap(upsert.operations.first?.revision))
        XCTAssertEqual(tombstone, lastUpsert.number + 1)
    }

    // MARK: - What the app actually records

    /// Ordinary journal foods and recipe components are encodable. The catalog is a set of known overrides,
    /// not a whitelist: any slug is a component, and its code is derived from what it measures.
    func testAnySlugComponentIDIsEncodable() throws {
        let oats = IntakeComponent(
            componentID: "oats", name: "Rolled oats", amount: try XCTUnwrap(DecimalText.decode("50")), unit: .g)
        let coffee = IntakeComponent(
            componentID: "coffee", name: "Coffee", amount: try XCTUnwrap(DecimalText.decode("250")), unit: .mL)
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-oats",
            productID: "product-oats",
            name: "Oats",
            labelBasis: "per_serving",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1",
            nutrients: ["oats": .known(try XCTUnwrap(DecimalText.decode("380")), .kcal)])
        let value = try encoder.upsert(
            intake: intake,
            revision: IntakeRevision(
                intakeID: intakeID,
                number: 1,
                components: [oats, coffee],
                productSnapshotID: "snapshot-oats",
                changeReason: "Logged from the label",
                createdAt: Self.recordedAt),
            product: snapshot,
            operation: outboxOperation(id: "4a1c9d0e-5b6f-4a8c-9d2e-3f4a5b6c7d8e", kind: .upsert, revision: 1))
        let facts = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue)
        XCTAssertEqual(facts.map { $0.string("component_id") }, ["oats", "coffee"])
        // A food measured by mass is an ordinary nutrient under its own catalog-style code, and its provenance
        // is the catalog it was read from.
        XCTAssertEqual(facts[0].string("kind"), "nutrient")
        XCTAssertEqual(facts[0].string("code"), "dietary_oats")
        XCTAssertEqual(facts[0].string("amount"), "50")
        XCTAssertEqual(facts[0].string("unit"), "g")
        XCTAssertEqual(facts[0].string("aggregation_role"), "context_only")
        XCTAssertEqual(facts[0].string("provenance"), "catalog_reference")
        XCTAssertNil(facts[0].member("quantity_basis"), "a nutrient's amount is the nutrient's own")
        // A drink's volume is water, and water is always `hydration` whatever the component is called.
        XCTAssertEqual(facts[1].string("kind"), "nutrient")
        XCTAssertEqual(facts[1].string("code"), "hydration")
        XCTAssertEqual(facts[1].string("unit"), "mL")
        // Such a fact still joins HealthKit, because its code is a catalog code.
        XCTAssertEqual(
            IntakeContextFactCatalog.healthKitTypeIdentifier(forCode: try XCTUnwrap(facts[0].string("code"))),
            "HKQuantityTypeIdentifierDietaryOats")
    }

    /// A component id the contract's slug pattern rejects has no contract form, so it is refused.
    func testComponentIDsThatAreNotSlugsAreRejected() throws {
        for bad in ["Rolled oats", "-water", "water!", ""] {
            XCTAssertThrowsError(
                try encoder.upsert(
                    intake: intake,
                    revision: waterAndCreatineRevision(components: [
                        IntakeComponent(
                            componentID: bad,
                            name: "Whatever",
                            amount: try XCTUnwrap(DecimalText.decode("50")),
                            unit: .g),
                    ], productSnapshotID: nil),
                    product: nil,
                    operation: upsertOperation)
            ) { error in
                XCTAssertEqual(error as? IntakeContextEncoderError, .invalidComponentID(bad), bad)
            }
        }
    }

    /// `complete` means every relevant entry is known. A snapshot that keeps an unknown entry states the gap,
    /// so it is partial however many other nutrients it fills in.
    func testCompletenessIsCompleteOnlyWhenEveryRelevantEntryIsKnown() throws {
        var stated: [String: NutrientValue] = [:]
        for key in HealthKitWritePlanner.mappings.map(\.nutrientKey) {
            stated[key] = .known(1, .g)
        }
        let complete = ProductDefinition(
            snapshotID: "snapshot-complete",
            productID: "product-complete",
            name: "Water with creatine",
            labelBasis: "per_serving",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1",
            nutrients: stated)
        let revision = waterAndCreatineRevision(productSnapshotID: "snapshot-complete")
        let allKnown = try encoder.upsert(
            intake: intake, revision: revision, product: complete, operation: upsertOperation)
        XCTAssertEqual(allKnown.member("nutrition_completeness")?.stringValue, "complete")

        stated["energy"] = NutrientValue.unknown
        let oneUnknown = ProductDefinition(
            snapshotID: "snapshot-complete",
            productID: "product-complete",
            name: "Water with creatine",
            labelBasis: "per_serving",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1",
            nutrients: stated)
        let partial = try encoder.upsert(
            intake: intake, revision: revision, product: oneUnknown, operation: upsertOperation)
        XCTAssertEqual(partial.member("nutrition_completeness")?.stringValue, "partial")
    }

    /// One sample is never counted for two components, so a sample UUID may be active on at most one of them.
    func testOneSampleCannotBeActiveOnTwoComponents() throws {
        let sample = "2c932bd1-c46d-4e38-b481-e0d842fdd429"
        let revision = waterAndCreatineRevision(components: [
            IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL),
            IntakeComponent(componentID: "caffeine", name: "Caffeine", amount: 80, unit: .mg),
        ], productSnapshotID: nil)
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: revision,
                product: nil,
                operation: upsertOperation,
                links: [
                    waterLink(disposition: .active, sampleUUID: sample, syncVersion: 2),
                    link(
                        componentID: "caffeine",
                        nutrientKey: "caffeine",
                        sampleUUID: sample,
                        syncVersion: 2,
                        disposition: .active),
                ])
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .sampleActiveOnTwoComponents(sample: sample, first: "water", second: "caffeine"))
        }
        // The same sample as a superseded link on the other component is fine: it counts for nothing.
        let ok = try encoder.upsert(
            intake: intake,
            revision: revision,
            product: nil,
            operation: upsertOperation,
            links: [
                waterLink(disposition: .active, sampleUUID: sample, syncVersion: 2),
                link(
                    componentID: "caffeine",
                    nutrientKey: "caffeine",
                    sampleUUID: sample,
                    syncVersion: 2,
                    disposition: .superseded),
            ])
        XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(ok.member("healthkit_links"))?.arrayValue).count, 2)
    }

    /// The product is hashed as an immutable fact of the revision, so it has to be the snapshot that revision
    /// names. The wrong snapshot, or one for a revision that has none, is refused rather than hashed.
    func testProductSnapshotMustMatchTheRevision() throws {
        let other = ProductDefinition(
            snapshotID: "snapshot-other",
            productID: "product-other",
            name: "Something else",
            labelBasis: "per_serving",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1")
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake, revision: waterAndCreatineRevision, product: other, operation: upsertOperation)
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .productSnapshotMismatch(expected: "snapshot-water-creatine", found: "snapshot-other"))
        }
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision(productSnapshotID: nil),
                product: product,
                operation: upsertOperation)
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .productSnapshotMismatch(expected: nil, found: "snapshot-water-creatine"))
        }
        // A snapshot the revision does name is of course accepted.
        XCTAssertNoThrow(
            try encoder.upsert(
                intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation))
    }

    /// A batch is built from operations, never from another batch: nesting one envelope inside `operations`
    /// would produce a payload the receiver rejects as a schema failure.
    func testBatchRejectsAValueThatIsAlreadyABatch() throws {
        let upsert = try encoder.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        let batch = try encoder.batch(batchID: "0bda35fc-3eab-47ce-9e31-c684343dd8d7", operations: [upsert])
        XCTAssertEqual(batch.operations.count, 1)
        XCTAssertThrowsError(
            try encoder.batch(batchID: "1e2f3a4b-5c6d-4e8f-9a0b-1c2d3e4f5a6b", operations: [batch])
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .operationAlreadyBatched)
        }
        XCTAssertThrowsError(
            try encoder.batch(batchID: "1e2f3a4b-5c6d-4e8f-9a0b-1c2d3e4f5a6b", operations: [upsert, batch])
        )
    }

    /// A link projection is checked against the revision it names, exactly as an upsert's links are, so it
    /// cannot link a compound, a component that is not there, or the wrong quantity type.
    func testLinkProjectionValidatesItsLinksAgainstTheRevision() throws {
        // The cases are built as data and encoded in this scope, rather than inside a closure, so nothing
        // escapes and captures self.
        let sample = "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396"
        let refused: [(what: String, links: [IntakeContextLink], expected: IntakeContextEncoderError)] = [
            // A compound has no HealthKit quantity type, so a link to it would never join.
            (
                "a compound",
                [link(
                    componentID: "creatine-monohydrate",
                    nutrientKey: "creatine-monohydrate",
                    sampleUUID: sample,
                    syncVersion: 3,
                    disposition: .active)],
                .linkComponentIsNotAFact("creatine-monohydrate")
            ),
            // Neither can a component the revision does not have.
            (
                "a component that is not there",
                [link(
                    componentID: "caffeine",
                    nutrientKey: "caffeine",
                    sampleUUID: sample,
                    syncVersion: 3,
                    disposition: .active)],
                .linkComponentIsNotAFact("caffeine")
            ),
            // And a nutrient of this revision still has to name the type its code lands in.
            (
                "the wrong quantity type",
                [waterLink(
                    disposition: .active,
                    sampleUUID: sample,
                    syncVersion: 3,
                    typeIdentifier: "HKQuantityTypeIdentifierDietarySodium")],
                .linkTypeMismatch(
                    component: "water",
                    expected: "HKQuantityTypeIdentifierDietaryWater",
                    found: "HKQuantityTypeIdentifierDietarySodium")
            ),
        ]
        for testCase in refused {
            XCTAssertThrowsError(
                try encoder.linkProjection(
                    intake: intake,
                    revision: waterAndCreatineRevision,
                    // The revision's own snapshot: a projection is checked against the facts of that
                    // revision, and a missing or mismatched snapshot is refused first.
                    product: product,
                    sequence: 2,
                    links: testCase.links,
                    operationID: "d94b6e18-27c3-4a5f-8e91-b0f3a6c2d587"),
                testCase.what
            ) { error in
                XCTAssertEqual(error as? IntakeContextEncoderError, testCase.expected, testCase.what)
            }
        }
        XCTAssertNoThrow(
            try encoder.linkProjection(
                intake: intake,
                revision: waterAndCreatineRevision,
                // The revision's own snapshot: a projection is checked against the facts of that
                // revision, and a missing or mismatched snapshot is refused first.
                product: product,
                sequence: 2,
                links: [waterLink(disposition: .active, sampleUUID: sample, syncVersion: 3)],
                operationID: "d94b6e18-27c3-4a5f-8e91-b0f3a6c2d587"))
    }

    /// One sync identity names one object: its versions are unique, only one sample of it is active, and an
    /// inactive link is never newer than the active one.
    func testSyncIdentityRulesWithinOneSnapshot() throws {
        let newer = "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396"
        let older = "2c932bd1-c46d-4e38-b481-e0d842fdd429"
        // Two samples active for one sync identity: HealthKit replaces a sample, it never duplicates it.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: upsertOperation,
                links: [
                    waterLink(disposition: .active, sampleUUID: newer, syncVersion: 3),
                    waterLink(disposition: .active, sampleUUID: older, syncVersion: 2),
                ])
        ) { error in
            guard case .duplicateActiveLinkForSyncIdentity? = error as? IntakeContextEncoderError else {
                return XCTFail("expected a duplicate active link, got \(error)")
            }
        }
        // The same version twice for one identity.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: upsertOperation,
                links: [
                    waterLink(disposition: .active, sampleUUID: newer, syncVersion: 3),
                    waterLink(disposition: .superseded, sampleUUID: older, syncVersion: 3),
                ])
        ) { error in
            guard case .duplicateSyncVersion? = error as? IntakeContextEncoderError else {
                return XCTFail("expected a duplicate sync version, got \(error)")
            }
        }
        // An inactive link newer than the active one.
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: upsertOperation,
                links: [
                    waterLink(disposition: .active, sampleUUID: newer, syncVersion: 3),
                    waterLink(disposition: .superseded, sampleUUID: older, syncVersion: 4),
                ])
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .inactiveLinkNewerThanActive(
                    syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
                    active: 3,
                    found: 4))
        }
        // The contract's own sequence-2 snapshot is exactly the legal shape: one active link at the highest
        // version, with the sample it replaced kept for audit.
        let legal = try encoder.linkProjection(
            intake: intake,
            revision: waterAndCreatineRevision,
            product: product,
            sequence: 2,
            links: [
                waterLink(disposition: .active, sampleUUID: newer, syncVersion: 3),
                waterLink(disposition: .superseded, sampleUUID: older, syncVersion: 2),
            ],
            operationID: "d94b6e18-27c3-4a5f-8e91-b0f3a6c2d587")
        XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(legal.member("healthkit_links"))?.arrayValue).count, 2)
    }

    /// A sync version below 1 is a schema failure, so it never reaches a digest.
    func testNonPositiveSyncVersionsAreRejected() throws {
        for version in [0, -1] {
            XCTAssertThrowsError(
                try encoder.upsert(
                    intake: intake,
                    revision: waterAndCreatineRevision,
                    product: product,
                    operation: upsertOperation,
                    links: [
                        waterLink(
                            disposition: .active,
                            sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                            syncVersion: version),
                    ])
            ) { error in
                XCTAssertEqual(error as? IntakeContextEncoderError, .invalidSyncVersion(version))
            }
        }
    }

    /// A zone name that does not name one zone on every receiver is refused, even when this platform knows it.
    func testImplementationSpecificTimeZonesAreRejected() throws {
        for identifier in [
            "Factory", "localtime", "posixrules", "posix/America/Chicago", "right/UTC", "Nowhere/Special",
        ] {
            var copy = intake
            copy.timeZoneIdentifier = identifier
            XCTAssertThrowsError(
                try encoder.upsert(
                    intake: copy,
                    revision: waterAndCreatineRevision,
                    product: product,
                    operation: upsertOperation)
            ) { error in
                XCTAssertEqual(error as? IntakeContextEncoderError, .unknownTimeZone(identifier), identifier)
            }
        }
        // A real IANA zone is of course accepted.
        XCTAssertNoThrow(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: upsertOperation))
    }

    /// The envelope's UUIDs are normalized to lowercase canonical text before anything is hashed, so a caller
    /// that spells one in upper case still sends a payload the schema accepts, and text that is not a UUID is
    /// refused rather than sent.
    func testEnvelopeUUIDsAreNormalizedToLowercaseCanonicalText() throws {
        let shouted = IntakeContextEncoder(scope: IntakeContextProducerScope(
            producerID: "nutrition-app",
            writerBundleID: "com.example.healthrelay.nutrition",
            installationID: "507B8FBB-78D3-450C-A88F-487E90DF92E6"))
        XCTAssertEqual(shouted.scope.installationID, "507b8fbb-78d3-450c-a88f-487e90df92e6")
        let value = try shouted.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        let lowercased = try encoder.upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        // Normalization happens before hashing, so the two spellings are one payload.
        XCTAssertEqual(value.canonicalBytes, lowercased.canonicalBytes)
        let batch = try shouted.batch(
            batchID: "0BDA35FC-3EAB-47CE-9E31-C684343DD8D7", operations: [value])
        XCTAssertEqual(batch.member("batch_id")?.stringValue, "0bda35fc-3eab-47ce-9e31-c684343dd8d7")
        XCTAssertEqual(batch.member("installation_id")?.stringValue, "507b8fbb-78d3-450c-a88f-487e90df92e6")
        XCTAssertEqual(
            batch.canonicalBytes,
            try encoder.batch(batchID: "0bda35fc-3eab-47ce-9e31-c684343dd8d7", operations: [lowercased]).canonicalBytes)

        let broken = IntakeContextEncoder(scope: IntakeContextProducerScope(
            producerID: "nutrition-app",
            writerBundleID: "com.example.healthrelay.nutrition",
            installationID: "not-a-uuid"))
        XCTAssertThrowsError(
            try broken.upsert(
                intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation)
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .invalidInstallationID("not-a-uuid"))
        }
        XCTAssertThrowsError(
            try encoder.batch(batchID: "not-a-uuid", operations: [lowercased])
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .invalidBatchID("not-a-uuid"))
        }
    }

    /// The outbox row's action and destination have to be the ones this method delivers, so a worker that
    /// dispatches the wrong pending row cannot send one kind of operation under another's delivery identity.
    func testOutboxActionAndDestinationMustMatchTheMethod() throws {
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: outboxOperation(id: "8b8719ea-6bb3-4dd4-8508-a63ee33d1381", kind: .delete, revision: 2))
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .operationActionMismatch(.delete))
        }
        XCTAssertThrowsError(
            try encoder.upsert(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                operation: outboxOperation(
                    id: "8b8719ea-6bb3-4dd4-8508-a63ee33d1381",
                    kind: .upsert,
                    revision: 2,
                    destination: .healthKit))
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .operationDestinationMismatch(.healthKit))
        }
        XCTAssertThrowsError(
            try encoder.delete(
                intake: intake,
                revision: waterAndCreatineRevision,
                tombstone: IntakeContextTombstone(intakeID: intakeID, deletedAt: Self.deletedAt),
                operation: outboxOperation(id: "c1f4a7d2-93be-4e65-8d0a-2b6f1e7c9a35", kind: .upsert, revision: 3))
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .operationActionMismatch(.upsert))
        }
        // A link-only change takes no outbox row at all: it carries a delivery identity of its own, so a wrong
        // action or destination is no longer expressible for it.
        XCTAssertThrowsError(
            try encoder.linkProjection(
                intake: intake,
                revision: waterAndCreatineRevision,
                product: product,
                sequence: 2,
                links: [
                    waterLink(
                        disposition: .active,
                        sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396",
                        syncVersion: 3),
                ],
                operationID: "not-a-uuid")
        ) { error in
            XCTAssertEqual(error as? IntakeContextEncoderError, .invalidOperationID("not-a-uuid"))
        }
    }

    // MARK: - Delivery identities, snapshot nutrients and durable values

    /// Every projection sequence has a delivery identity of its own, derived from the intake and the sequence
    /// when the caller has queued no row for it. It is never the revision's upsert row: reusing that id with
    /// different links is a conflict at the receiver, not an update. The same sequence derives the same id on
    /// every retry, so a retry is still a duplicate.
    func testLinkProjectionsUseTheirOwnDeliveryIdentity() throws {
        let links = [
            waterLink(disposition: .active, sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396", syncVersion: 3),
        ]
        let first = try encoder.linkProjection(
            intake: intake, revision: waterAndCreatineRevision, product: product, sequence: 2, links: links)
        let retry = try encoder.linkProjection(
            intake: intake, revision: waterAndCreatineRevision, product: product, sequence: 2, links: links)
        let later = try encoder.linkProjection(
            intake: intake, revision: waterAndCreatineRevision, product: product, sequence: 3, links: [
                waterLink(disposition: .active, sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396", syncVersion: 4),
            ])
        let delivered = try XCTUnwrap(first.member("operation_id")?.stringValue)
        XCTAssertEqual(delivered, try XCTUnwrap(retry.member("operation_id")?.stringValue), "a retry repeats the id")
        XCTAssertEqual(first.canonicalBytes, retry.canonicalBytes)
        XCTAssertNotEqual(delivered, try XCTUnwrap(later.member("operation_id")?.stringValue))
        XCTAssertEqual(first.operations.first?.operationID, delivered)
        // Never the revision's own upsert row, and always canonical UUID text.
        XCTAssertNotEqual(delivered, upsertOperation.operationID)
        XCTAssertTrue(IntakeContextIdentifier.isCanonicalUUIDText(delivered), delivered)
        XCTAssertEqual(
            IntakeContextEncoder.linkProjectionOperationID(
                intakeID: intakeID, revision: 2, sequence: 2),
            delivered)
        // Two intakes at the same revision and sequence never share an identity either.
        XCTAssertNotEqual(
            IntakeContextEncoder.linkProjectionOperationID(
                intakeID: "7d2e9b40-1c85-4a3f-9e67-f0a8b5c3d214", revision: 2, sequence: 2),
            delivered)
    }

    /// A projection sequence restarts at 2 for every revision, so the derived identity carries the revision as
    /// well: sequence 2 of revision 3 and sequence 2 of revision 4 are different deliveries, and a shared id
    /// would make the second one a conflict at the receiver instead of an update.
    func testDerivedProjectionIdentityIsScopedToTheRevision() throws {
        let links = [
            waterLink(disposition: .active, sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396", syncVersion: 2),
        ]
        let second = waterAndCreatineRevision(number: 3)
        let atTwo = try encoder.linkProjection(
            intake: intake, revision: waterAndCreatineRevision, product: product, sequence: 2, links: links)
        let atThree = try encoder.linkProjection(
            intake: intake, revision: second, product: product, sequence: 2, links: links)
        let revision2 = try XCTUnwrap(atTwo.member("operation_id")?.stringValue)
        let revision3 = try XCTUnwrap(atThree.member("operation_id")?.stringValue)
        XCTAssertNotEqual(revision2, revision3)
        XCTAssertNotEqual(revision2, upsertOperation.operationID)
        XCTAssertTrue(IntakeContextIdentifier.isCanonicalUUIDText(revision3), revision3)
        // The payload's own revision differs too, so nothing else about the two deliveries collides either.
        XCTAssertEqual(atTwo.member("revision"), .integer("2"))
        XCTAssertEqual(atThree.member("revision"), .integer("3"))
        // Each is still stable for its own revision.
        XCTAssertEqual(
            IntakeContextEncoder.linkProjectionOperationID(intakeID: intakeID, revision: 2, sequence: 2),
            revision2)
        XCTAssertEqual(
            IntakeContextEncoder.linkProjectionOperationID(intakeID: intakeID, revision: 3, sequence: 2),
            revision3)
    }

    /// A barcode or recipe entry keeps one food component and puts its nutrition in the product snapshot, so
    /// those values travel as facts of their own instead of being lost or folded into an invented fact.
    func testSnapshotNutrientsBecomeFactsForFoodComponents() throws {
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-protein-bar",
            productID: "product-protein-bar",
            name: "Synthetic protein bar",
            labelBasis: "per100g",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1",
            nutrients: [
                "energyKcal": .known(210, .kcal),
                "protein": .known(20, .g),
                "sugars": .unknown,
            ])
        let value = try encoder.upsert(
            intake: intake,
            revision: IntakeRevision(
                intakeID: intakeID,
                number: 1,
                components: [
                    IntakeComponent(
                        componentID: "protein-bar",
                        name: "Protein bar",
                        amount: try XCTUnwrap(DecimalText.decode("60")),
                        unit: .g),
                ],
                productSnapshotID: "snapshot-protein-bar",
                changeReason: "Scanned from the shelf",
                createdAt: Self.recordedAt),
            product: snapshot,
            operation: outboxOperation(id: "4a1c9d0e-5b6f-4a8c-9d2e-3f4a5b6c7d8e", kind: .upsert, revision: 1))
        let facts = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue)
        // The food itself first, then the snapshot's own nutrients by their own codes.
        XCTAssertEqual(
            facts.map { $0.string("component_id") }, ["protein-bar", "energy", "protein", "sugar"])
        // The label states these per 100 g and 60 g were logged, so the facts are scaled: 210 kcal per 100 g
        // is 126 kcal here, and 20 g of protein is 12 g. Sending the label's own numbers would state the whole
        // package, not the amount eaten.
        XCTAssertEqual(facts[1].string("code"), "dietary_energy")
        XCTAssertEqual(facts[1].string("amount"), "126")
        XCTAssertEqual(facts[1].string("unit"), "kcal")
        XCTAssertEqual(facts[2].string("code"), "dietary_protein")
        XCTAssertEqual(facts[2].string("amount"), "12")
        XCTAssertEqual(facts[2].string("unit"), "g")
        XCTAssertEqual(facts[2].string("aggregation_role"), "context_only")
        // A nutrient the label does not state is unknown, and unknown is never a zero.
        XCTAssertEqual(facts[3].string("code"), "dietary_sugar")
        XCTAssertEqual(facts[3].string("value_state"), "unknown")
        XCTAssertNil(facts[3].member("amount"))
        XCTAssertEqual(facts[3].string("provenance"), "catalog_reference")
        // Each of them joins HealthKit under the type its code lands in.
        XCTAssertEqual(
            IntakeContextFactCatalog.healthKitTypeIdentifier(forCode: "dietary_energy"),
            "HKQuantityTypeIdentifierDietaryEnergyConsumed")
    }

    /// A component id may be as long as the contract's slug allows, so a code derived from it is shortened
    /// rather than left over the limit: a code the schema rejects would fail the whole operation.
    func testInferredCodesStayWithinTheSlugLimit() throws {
        // The journal will accept a component id that fills the contract's whole 64-character slug, so the
        // derived code would be 72 characters without trimming and has to come back inside the limit.
        let componentID = String("extremely-long-synthetic-food-name-for-the-slug-limit-check-again".prefix(64))
        XCTAssertEqual(componentID.count, 64)
        XCTAssertEqual(componentID.count + "dietary_".count, 72)
        let value = try encoder.upsert(
            intake: intake,
            revision: waterAndCreatineRevision(components: [
                IntakeComponent(
                    componentID: componentID,
                    name: "Long food name",
                    amount: try XCTUnwrap(DecimalText.decode("50")),
                    unit: .g),
            ], productSnapshotID: nil),
            product: nil,
            operation: upsertOperation)
        let fact = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue?.first)
        let code = try XCTUnwrap(fact.string("code"))
        XCTAssertEqual(code, "dietary_extremely_long_synthetic_food_name_for_the_slug_limit_ch")
        XCTAssertLessThanOrEqual(code.count, 64, code)
        XCTAssertTrue(IntakeContextFactCatalog.isSlug(code), code)
        XCTAssertTrue(code.hasPrefix("dietary_"))
        // The component id is the fact's identity and is untouched by the shortening.
        XCTAssertEqual(fact.string("component_id"), componentID)
    }

    /// The scope's own fields are part of the envelope the receiver validates, so a configuration mistake is a
    /// local refusal rather than a permanent failure after a delivery attempt.
    func testProducerScopeFieldsAreValidated() throws {
        XCTAssertNoThrow(try IntakeContextEncoder(scope: Self.scope).upsert(
            intake: intake, revision: waterAndCreatineRevision, product: product, operation: upsertOperation))
        let installation = "507b8fbb-78d3-450c-a88f-487e90df92e6"
        for scope in [
            IntakeContextProducerScope(
                producerID: "Nutrition-App", writerBundleID: "com.example.healthrelay.nutrition",
                installationID: installation),
            IntakeContextProducerScope(
                producerID: "9 nutrition-app", writerBundleID: "com.example.healthrelay.nutrition",
                installationID: installation),
            IntakeContextProducerScope(
                producerID: "nutrition_app", writerBundleID: "com.example.healthrelay.nutrition",
                installationID: installation),
            IntakeContextProducerScope(
                producerID: "", writerBundleID: "com.example.healthrelay.nutrition",
                installationID: installation),
            IntakeContextProducerScope(
                producerID: "nutrition-app", writerBundleID: "com.example.healthrelay.nutrition_2",
                installationID: installation),
            IntakeContextProducerScope(
                producerID: "nutrition-app", writerBundleID: ".com.example.healthrelay.nutrition",
                installationID: installation),
            IntakeContextProducerScope(
                producerID: "nutrition-app", writerBundleID: "com.example.healthrelay.nutrition",
                installationID: "not-a-uuid"),
        ] {
            XCTAssertThrowsError(
                try IntakeContextEncoder(scope: scope).upsert(
                    intake: intake,
                    revision: waterAndCreatineRevision,
                    product: product,
                    operation: upsertOperation),
                "\(scope.producerID) / \(scope.writerBundleID) / \(scope.installationID)")
        }
    }

    /// A retried delete has to hash the same, so `deleted_at` comes from the persisted tombstone rather than
    /// from a fresh reading of the clock.
    func testRetriedDeleteHashesTheSameFromItsPersistedTombstone() throws {
        let tombstone = IntakeContextTombstone(intakeID: intakeID, deletedAt: Self.deletedAt)
        let row = outboxOperation(id: "c1f4a7d2-93be-4e65-8d0a-2b6f1e7c9a35", kind: .delete, revision: 3)
        let first = try encoder.delete(
            intake: intake, revision: waterAndCreatineRevision, tombstone: tombstone, operation: row)
        // The same durable record, rebuilt by a worker from storage after a lost response.
        let retry = try encoder.delete(
            intake: intake, revision: waterAndCreatineRevision, tombstone: tombstone, operation: row)
        XCTAssertEqual(first.canonicalBytes, retry.canonicalBytes)
        XCTAssertEqual(
            first.operations.first?.clientPayloadHash, retry.operations.first?.clientPayloadHash)
        XCTAssertEqual(
            first.operations.first?.domainFactsHash, retry.operations.first?.domainFactsHash)
        XCTAssertEqual(
            try XCTUnwrap(Self.read(first).member("deleted_at")?.stringValue), "2026-09-30T18:05:00Z")
        // A tombstone that belongs to another intake is refused rather than deleting the wrong one.
        XCTAssertThrowsError(
            try encoder.delete(
                intake: intake,
                revision: waterAndCreatineRevision,
                tombstone: IntakeContextTombstone(
                    intakeID: "7d2e9b40-1c85-4a3f-9e67-f0a8b5c3d214", deletedAt: Self.deletedAt),
                operation: row)
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .tombstoneIntakeMismatch("7d2e9b40-1c85-4a3f-9e67-f0a8b5c3d214"))
        }
    }

    /// A snapshot built from a recipe's ingredients is calculated, and the contract records that in the
    /// immutable provenance: downstream consumers must not read calculated values as catalog-sourced.
    func testRecipeSnapshotsKeepRecipeCalculatedProvenance() throws {
        let revision = IntakeRevision(
            intakeID: intakeID,
            number: 1,
            components: [
                IntakeComponent(
                    componentID: "recipe-oats-whey",
                    name: "Oats and whey",
                    amount: try XCTUnwrap(DecimalText.decode("1")),
                    unit: .serving),
            ],
            productSnapshotID: "snapshot-recipe",
            changeReason: "Logged from the recipe",
            createdAt: Self.recordedAt)
        let row = outboxOperation(id: "5b2d0e1f-6c7a-4b9d-8e3f-4a5b6c7d8e9f", kind: .upsert, revision: 1)
        let calculated = try encoder.upsert(
            intake: intake,
            revision: revision,
            product: ProductDefinition(
                snapshotID: "snapshot-recipe",
                productID: "recipe-synthetic",
                name: "Synthetic oats and whey",
                labelBasis: "per_serving",
                catalogOrigin: "recipe_calculated",
                catalogVersion: "1",
                nutrients: ["protein": .known(24, .g)]),
            operation: row)
        let facts = try XCTUnwrap(try XCTUnwrap(calculated.member("facts"))?.arrayValue)
        XCTAssertEqual(facts.map { $0.string("component_id") }, ["recipe-oats-whey", "protein"])
        XCTAssertEqual(facts[0].string("provenance"), "recipe_calculated")
        XCTAssertEqual(facts[1].string("provenance"), "recipe_calculated")
        XCTAssertEqual(facts[1].string("code"), "dietary_protein")

        // A snapshot read from a catalog is catalog-sourced, and an entry with no snapshot is the user's own.
        let catalogued = try encoder.upsert(
            intake: intake,
            revision: waterAndCreatineRevision(productSnapshotID: "snapshot-catalog"),
            product: ProductDefinition(
                snapshotID: "snapshot-catalog",
                productID: "product-oats",
                name: "Oats",
                labelBasis: "per_serving",
                catalogOrigin: "synthetic-catalog",
                catalogVersion: "1",
                nutrients: ["protein": .known(13, .g)]),
            operation: upsertOperation)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(try XCTUnwrap(catalogued.member("facts"))?.arrayValue?.last)
                .string("provenance")),
            "catalog_reference")
        let byHand = try encoder.upsert(
            intake: intake,
            revision: waterAndCreatineRevision(productSnapshotID: nil),
            product: nil,
            operation: upsertOperation)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(try XCTUnwrap(byHand.member("facts"))?.arrayValue?.first)
                .string("provenance")),
            "user_confirmed")
    }

    /// A snapshot states its values on a basis, and the facts are the amount actually logged. A basis that
    /// cannot be resolved against the logged quantity sends nothing at all, because an unscaled value would be
    /// the whole package rather than the portion eaten - the same reason `JournalSnapshotTotals` carries none.
    func testSnapshotNutrientsAreScaledToTheLoggedAmountOrOmitted() throws {
        let component = IntakeComponent(
            componentID: "protein-bar",
            name: "Protein bar",
            amount: try XCTUnwrap(DecimalText.decode("40")),
            unit: .g)
        func encode(basis: String) throws -> [IntakeContextJSONValue] {
            let value = try encoder.upsert(
                intake: intake,
                revision: IntakeRevision(
                    intakeID: intakeID,
                    number: 1,
                    components: [component],
                    productSnapshotID: "snapshot-bar",
                    changeReason: "Scanned from the shelf",
                    createdAt: Self.recordedAt),
                product: ProductDefinition(
                    snapshotID: "snapshot-bar",
                    productID: "product-protein-bar",
                    name: "Synthetic protein bar",
                    labelBasis: basis,
                    catalogOrigin: "synthetic-catalog",
                    catalogVersion: "1",
                    nutrients: ["protein": .known(13, .g)]),
                operation: outboxOperation(
                    id: "4a1c9d0e-5b6f-4a8c-9d2e-3f4a5b6c7d8e", kind: .upsert, revision: 1))
            return try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue)
        }
        // Per 100 g, 40 g logged: 13 g per 100 g is 5.2 g, never 13 g.
        let per100g = try encode(basis: "per 100 g")
        XCTAssertEqual(per100g.map { $0.string("component_id") }, ["protein-bar", "protein"])
        XCTAssertEqual(per100g[1].string("amount"), "5.2")
        // The same basis without a space, as a stored lookup states it.
        XCTAssertEqual(try encode(basis: "per100g")[1].string("amount"), "5.2")
        // A source that did not resolve per 100 g or per 100 mL cannot be scaled to a mass or a volume.
        for unresolved in ["per 100 g or mL", "per serving (30 g)", "per 100 kcal", "unknown"] {
            let facts = try encode(basis: unresolved)
            XCTAssertEqual(
                facts.map { $0.string("component_id") }, ["protein-bar"], unresolved)
        }
        // Per serving, two servings logged: the label's one serving becomes two.
        let servings = try encoder.upsert(
            intake: intake,
            revision: IntakeRevision(
                intakeID: intakeID,
                number: 1,
                components: [
                    IntakeComponent(
                        componentID: "recipe-oats-whey",
                        name: "Oats and whey",
                        amount: try XCTUnwrap(DecimalText.decode("2")),
                        unit: .serving),
                ],
                productSnapshotID: "snapshot-recipe",
                changeReason: "Logged from the recipe",
                createdAt: Self.recordedAt),
            product: ProductDefinition(
                snapshotID: "snapshot-recipe",
                productID: "recipe-synthetic",
                name: "Synthetic oats and whey",
                labelBasis: "Per serving; yield 4 servings",
                catalogOrigin: "recipe_calculated",
                catalogVersion: "1",
                nutrients: ["protein": .known(24, .g)]),
            operation: outboxOperation(id: "5b2d0e1f-6c7a-4b9d-8e3f-4a5b6c7d8e9f", kind: .upsert, revision: 1))
        let served = try XCTUnwrap(try XCTUnwrap(servings.member("facts"))?.arrayValue)
        XCTAssertEqual(served.map { $0.string("component_id") }, ["recipe-oats-whey", "protein"])
        XCTAssertEqual(served[1].string("amount"), "48")
    }

    /// A canonical key and an accepted alias name one nutrient, so they become one fact: the contract requires
    /// `component_id` to be unique, and two facts under one id fail the whole operation.
    func testAliasAndCanonicalKeysProduceOneFact() throws {
        let value = try encoder.upsert(
            intake: intake,
            revision: IntakeRevision(
                intakeID: intakeID,
                number: 1,
                components: [
                    IntakeComponent(
                        componentID: "protein-bar",
                        name: "Protein bar",
                        amount: try XCTUnwrap(DecimalText.decode("40")),
                        unit: .g),
                ],
                productSnapshotID: "snapshot-aliases",
                changeReason: "Scanned from the shelf",
                createdAt: Self.recordedAt),
            product: ProductDefinition(
                snapshotID: "snapshot-aliases",
                productID: "product-protein-bar",
                name: "Synthetic protein bar",
                labelBasis: "per 100 g",
                catalogOrigin: "synthetic-catalog",
                catalogVersion: "1",
                nutrients: [
                    "energy": .known(400, .kcal),
                    "energyKcal": .known(410, .kcal),
                    "sugars": .known(10, .g),
                    "sugar": .known(11, .g),
                ]),
            operation: outboxOperation(id: "6c3e1f2a-7d8b-4c0e-9f1a-2b3c4d5e6f70", kind: .upsert, revision: 1))
        let facts = try XCTUnwrap(try XCTUnwrap(value.member("facts"))?.arrayValue)
        let ids = facts.map { $0.string("component_id") }
        XCTAssertEqual(ids, ["protein-bar", "energy", "sugar"], "one fact per nutrient, not one per key")
        XCTAssertEqual(Set(ids).count, ids.count, "component ids are unique")
        XCTAssertEqual(facts[1].string("amount"), "160", "40 g of 400 kcal per 100 g")
    }

    /// A fact the upsert derived from a product snapshot is a fact of that revision, so a later projection may
    /// link it even though the revision's own components never named it.
    func testLinkProjectionAcceptsSnapshotDerivedFacts() throws {
        let revision = IntakeRevision(
            intakeID: intakeID,
            number: 1,
            components: [
                IntakeComponent(
                    componentID: "protein-bar",
                    name: "Protein bar",
                    amount: try XCTUnwrap(DecimalText.decode("40")),
                    unit: .g),
            ],
            productSnapshotID: "snapshot-bar",
            changeReason: "Scanned from the shelf",
            createdAt: Self.recordedAt)
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-bar",
            productID: "product-protein-bar",
            name: "Synthetic protein bar",
            labelBasis: "per 100 g",
            catalogOrigin: "synthetic-catalog",
            catalogVersion: "1",
            nutrients: ["protein": .known(13, .g)])
        let row = outboxOperation(id: "7d4f2a3b-8e9c-4d1f-8a2b-3c4d5e6f7081", kind: .upsert, revision: 1)
        let upsert = try encoder.upsert(intake: intake, revision: revision, product: snapshot, operation: row)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(upsert.member("facts"))?.arrayValue?.last?.string("component_id")),
            "protein")
        // The projection links that stored fact, which no component of the revision names.
        let projection = try encoder.linkProjection(
            intake: intake,
            revision: revision,
            product: snapshot,
            sequence: 2,
            links: [
                IntakeContextLink(
                    componentID: "protein",
                    sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396",
                    healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryProtein",
                    syncIdentifier: HealthKitWritePlanner.syncIdentifier(
                        intakeID: intakeID, nutrientKey: "protein"),
                    syncVersion: 2,
                    disposition: .active),
            ])
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(projection.member("healthkit_links"))?.arrayValue?.count), 1)
        // The wrong type for that same fact is still refused, so the snapshot facts are checked, not skipped.
        XCTAssertThrowsError(
            try encoder.linkProjection(
                intake: intake,
                revision: revision,
                product: snapshot,
                sequence: 3,
                links: [
                    IntakeContextLink(
                        componentID: "protein",
                        sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396",
                        healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietarySodium",
                        syncIdentifier: HealthKitWritePlanner.syncIdentifier(
                            intakeID: intakeID, nutrientKey: "protein"),
                        syncVersion: 3,
                        disposition: .active),
                ])
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .linkTypeMismatch(
                    component: "protein",
                    expected: "HKQuantityTypeIdentifierDietaryProtein",
                    found: "HKQuantityTypeIdentifierDietarySodium"))
        }
        // And a projection whose product is not this revision's snapshot is refused like an upsert's.
        XCTAssertThrowsError(
            try encoder.linkProjection(
                intake: intake,
                revision: revision,
                product: nil,
                sequence: 2,
                links: [
                    IntakeContextLink(
                        componentID: "protein",
                        sampleUUID: "9a1f3c57-8e2d-4b60-a7c4-d5e0b1f28396",
                        healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryProtein",
                        syncIdentifier: HealthKitWritePlanner.syncIdentifier(
                            intakeID: intakeID, nutrientKey: "protein"),
                        syncVersion: 2,
                        disposition: .active),
                ])
        ) { error in
            XCTAssertEqual(
                error as? IntakeContextEncoderError,
                .productSnapshotMismatch(expected: "snapshot-bar", found: nil))
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
        waterAndCreatineRevision()
    }

    private func waterAndCreatineRevision(
        number: Int = 2,
        components: [IntakeComponent]? = nil,
        productSnapshotID: String? = "snapshot-water-creatine"
    ) -> IntakeRevision {
        IntakeRevision(
            intakeID: intakeID,
            number: number,
            components: components ?? [
                IntakeComponent(componentID: "water", name: "Water", amount: 500, unit: .mL),
                IntakeComponent(componentID: "creatine-monohydrate", name: "Creatine monohydrate", amount: 5, unit: .g),
            ],
            productSnapshotID: productSnapshotID,
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

    private func outboxOperation(
        id: String,
        kind: OutboxKind,
        revision: Int,
        destination: JournalDestination = .relay
    ) -> OutboxOperation {
        OutboxOperation(
            operationID: id,
            kind: kind,
            intakeID: intakeID,
            revision: revision,
            destination: destination,
            payloadHash: "sha256:" + String(repeating: "0", count: 64))
    }

    private func waterLink(
        disposition: IntakeContextLinkDisposition,
        sampleUUID: String,
        syncVersion: Int,
        typeIdentifier: String? = nil
    ) -> IntakeContextLink {
        link(
            componentID: "water",
            nutrientKey: "water",
            typeIdentifier: typeIdentifier,
            sampleUUID: sampleUUID,
            syncVersion: syncVersion,
            disposition: disposition)
    }

    /// One link, with the type and the sync identifier the write plan would have used for that nutrient.
    private func link(
        componentID: String,
        nutrientKey: String,
        typeIdentifier: String? = nil,
        sampleUUID: String,
        syncVersion: Int,
        disposition: IntakeContextLinkDisposition,
        syncIdentifier: String? = nil
    ) -> IntakeContextLink {
        IntakeContextLink(
            componentID: componentID,
            sampleUUID: sampleUUID,
            healthKitTypeIdentifier: typeIdentifier
                ?? "HKQuantityTypeIdentifierDietary" + nutrientKey.prefix(1).uppercased() + nutrientKey.dropFirst(),
            // ADR 0002: one sync identifier per (intake, nutrient), the same one the writer saved with.
            syncIdentifier: syncIdentifier
                ?? HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: nutrientKey),
            syncVersion: syncVersion,
            disposition: disposition)
    }

    /// A single operation's canonical bytes read back as a payload, so a test can assert on the members of the
    /// operation that is sent rather than on the encoder's own view of it.
    private static func read(_ value: IntakeContextValue) throws -> IntakeContextJSONValue {
        try IntakeContextJSONReader.read(value.canonicalBytes)
    }

    /// The facts of a value, in the order they are sent.
    private func facts(of value: IntakeContextValue) -> [IntakeContextJSONValue] {
        value.payload.array("facts") ?? []
    }

    /// The amount of one named fact, so an assertion never depends on a fact's position.
    private func amount(ofComponent componentID: String, in value: IntakeContextValue) -> String? {
        facts(of: value).first { $0.string("component_id") == componentID }?.string("amount")
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