import Foundation
import XCTest
@testable import NutritionJournal

/// The intake-context digests are byte-for-byte contract: the receiver recomputes `domain_facts_hash`,
/// `projection_hash` and `client_payload_hash` from the operation it received and rejects a mismatch. These
/// tests check the app's canonical JSON against the receiver's own reference, which lives with the contract in
/// `contracts/intake-context/README.md` under "Canonical JSON" and "Hashes".
///
/// Every fixture, UUID and sample here is synthetic.
final class IntakeContextDigestTests: XCTestCase {
    // MARK: - Literal golden vectors

    func testWorkedExampleDigestsAreTheLiteralGoldenVectors() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        XCTAssertEqual(
            try IntakeContextDigests.domainFactsHash(batch: batch, operation: operation),
            "sha256:93bb96b900c8d22d77630236eb60ec9c453e0627009d9fe01041ea3ef438c4f0")
        XCTAssertEqual(
            try IntakeContextDigests.projectionHash(batch: batch, operation: operation),
            "sha256:8d5f54713418cd2f525dbf176e4d9e6c73241ded8ac5f9288db6e0179b8f71fd")
        XCTAssertEqual(
            try IntakeContextDigests.clientPayloadHash(batch: batch, operation: operation),
            "sha256:873b7b15148917d14c17c36b074f8e4bb3fd1d0afea2652c8fb5319e54e81003")
    }

    /// The canonical bytes behind the worked `projection_hash`, copied from the receiver's reference:
    /// `healthkit_links` sorted into the projection object, keys sorted by code point, no whitespace.
    func testWorkedProjectionCanonicalBytesAreTheLiteralVector() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let canonical = String(decoding: try IntakeContextDigests.projectionBytes(batch: batch, operation: operation), as: UTF8.self)
        XCTAssertEqual(
            canonical,
            "{\"healthkit_links\":[{\"component_id\":\"water\",\"disposition\":\"active\","
                + "\"healthkit_sample_uuid\":\"2c932bd1-c46d-4e38-b481-e0d842fdd429\","
                + "\"healthkit_type\":\"HKQuantityTypeIdentifierDietaryWater\","
                + "\"sync_identifier\":\"intake:e6677963-418c-4027-b563-551d8a531eed:water\","
                + "\"sync_version\":2}],\"intake_id\":\"e6677963-418c-4027-b563-551d8a531eed\","
                + "\"producer_id\":\"nutrition-app\",\"projection_sequence\":1,\"revision\":2}")
    }

    // MARK: - The committed fixtures

    /// Every operation of every committed fixture carries digests, and the app must reproduce them byte for
    /// byte. The fixtures are loaded from `contracts/intake-context/fixtures` through `#filePath`, so this
    /// test cannot pass against a stale bundled copy.
    func testEveryOperationOfEveryCommittedFixtureRecomputesItsDigests() throws {
        let directory = try XCTUnwrap(Self.fixtureDirectory(), "contracts/intake-context/fixtures is missing")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("valid_") && $0.hasSuffix(".json") }
            .sorted()
        XCTAssertEqual(
            names,
            [
                "valid_delete.json",
                "valid_link_projection_seq2.json",
                "valid_proprietary_blend.json",
                "valid_worked_example.json",
            ])
        for name in names {
            let batch = try Self.batch(named: name, in: directory)
            let operations = try Self.operations(of: batch)
            XCTAssertFalse(operations.isEmpty, "\(name) has no operations")
            for (index, operation) in operations.enumerated() {
                let kind = try operation.string(named: "operation")
                if kind == "upsert" || kind == "delete" {
                    XCTAssertEqual(
                        try IntakeContextDigests.domainFactsHash(batch: batch, operation: operation),
                        try operation.string(named: "domain_facts_hash"),
                        "\(name) operation \(index) domain_facts_hash")
                }
                if kind == "upsert" || kind == "link_projection" {
                    XCTAssertEqual(
                        try IntakeContextDigests.projectionHash(batch: batch, operation: operation),
                        try operation.string(named: "projection_hash"),
                        "\(name) operation \(index) projection_hash")
                }
                XCTAssertEqual(
                    try IntakeContextDigests.clientPayloadHash(batch: batch, operation: operation),
                    try operation.string(named: "client_payload_hash"),
                    "\(name) operation \(index) client_payload_hash")
            }
        }
    }

    // MARK: - Canonical JSON

    func testObjectKeysAreSortedByUnicodeCodePoint() throws {
        // Code point order, not locale order: "1" < "A" < "B" < "_" < "a" < "b", and a key beyond the
        // basic plane sorts after U+FF5E rather than beside its case-folding neighbours.
        let value = IntakeContextJSONValue.object([
            "b": .integer("1"),
            "a": .object(["d": .string("x"), "c": .null]),
            "B": .bool(true),
            "_": .string("\u{FF5E}"),
            "\u{10000}": .integer("2"),
        ])
        XCTAssertEqual(
            String(decoding: IntakeContextCanonicalJSON.encode(value), as: UTF8.self),
            "{\"B\":true,\"_\":\"\u{FF5E}\",\"a\":{\"c\":null,\"d\":\"x\"},\"b\":1,\"\u{10000}\":2}")
        XCTAssertEqual(
            String(decoding: IntakeContextCanonicalJSON.encode(.object(["b": .array([.integer("2"), .integer("1")]), "a": .object(["d": .string("x"), "c": .null])])), as: UTF8.self),
            "{\"a\":{\"c\":null,\"d\":\"x\"},\"b\":[2,1]}")
    }

    func testNonASCIIIsWrittenAsRawUTF8() throws {
        // "café" and DEL followed by U+2028, byte for byte: the canonical form never escapes a printable or
        // non-ASCII character, and never writes it as a `\u` sequence either.
        XCTAssertEqual(
            IntakeContextCanonicalJSON.encode(.string("caf\u{E9}")),
            Data([0x22, 0x63, 0x61, 0x66, 0xC3, 0xA9, 0x22]))
        XCTAssertEqual(
            IntakeContextCanonicalJSON.encode(.string("\u{7F}\u{2028}")),
            Data([0x22, 0x7F, 0xE2, 0x80, 0xA8, 0x22]))
    }

    func testControlCharactersUseTheRequiredShortAndLowercaseEscapes() throws {
        // Only the escapes JSON requires, plus \u00xx with lowercase hex. U+002F is not escaped.
        XCTAssertEqual(
            IntakeContextCanonicalJSON.encode(.string("\"\\\u{8}\u{C}\n\r\t\u{1}\u{E}/")),
            Data("\"\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u000e/\"".utf8))
    }

    func testIntegersAndLiteralsAreCanonical() throws {
        XCTAssertEqual(
            String(
                decoding: IntakeContextCanonicalJSON.encode(
                    .array([.integer("-27"), .integer("0"), .integer("9223372036854775807"), .bool(true), .bool(false), .null])),
                as: UTF8.self),
            "[-27,0,9223372036854775807,true,false,null]")
    }

    func testTheReaderKeepsEveryNumberLiteralSpelling() throws {
        let text = "{\"revision\":2,\"sync_version\":7,\"amount\":\"1.0\"}"
        let value = try IntakeContextJSONReader.read(Data(text.utf8))
        XCTAssertEqual(try value.value(named: "revision"), .integer("2"))
        // A decimal amount is a string in this contract, and its spelling is content, not a number.
        XCTAssertEqual(try value.string(named: "amount"), "1.0")
        XCTAssertThrowsError(try IntakeContextJSONReader.read(Data("{\"revision\":2.0}".utf8)))
    }

    // MARK: - Digest scopes

    func testDecimalSpellingIsContent() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let baseline = try IntakeContextDigests.domainFactsHash(batch: batch, operation: operation)
        let facts = try operation.array(named: "facts")
        let five = facts[1]
        XCTAssertEqual(try five.string(named: "amount"), "5")
        let respellings = ["5.0", "5.00", "5.000"]
        for spelling in respellings {
            let changed = operation.settingMember(
                "facts",
                to: .array([facts[0], try five.settingMember("amount", to: .string(spelling))]))
            XCTAssertNotEqual(
                try IntakeContextDigests.domainFactsHash(batch: batch, operation: changed),
                baseline,
                "the decimal spelling \(spelling) must change the domain digest")
        }
        // "1" and "1.0" differ as well, in the serving.
        let serving = try operation.value(named: "serving")
        let changed = operation.settingMember("serving", to: try serving.settingMember("amount", to: .string("500.0")))
        XCTAssertNotEqual(try IntakeContextDigests.domainFactsHash(batch: batch, operation: changed), baseline)
    }

    func testLinkOrderDoesNotChangeTheProjectionHash() throws {
        let batch = try Self.batch(named: "valid_link_projection_seq2.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let links = try operation.array(named: "healthkit_links")
        XCTAssertEqual(links.count, 2)
        let baseline = try IntakeContextDigests.projectionHash(batch: batch, operation: operation)
        let reversed = operation.settingMember("healthkit_links", to: .array(links.reversed()))
        XCTAssertEqual(try IntakeContextDigests.projectionHash(batch: batch, operation: reversed), baseline)
        // The client digest still moves, because it hashes the operation exactly as sent.
        XCTAssertNotEqual(
            try IntakeContextDigests.clientPayloadHash(batch: batch, operation: reversed),
            try operation.string(named: "client_payload_hash"))
    }

    func testChangedDisplayNameMovesDomainAndClientDigestsButNotTheProjection() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let changed = operation.settingMember("display_name", to: .string("Tampered synthetic drink"))
        XCTAssertNotEqual(
            try IntakeContextDigests.domainFactsHash(batch: batch, operation: changed),
            try operation.string(named: "domain_facts_hash"))
        XCTAssertNotEqual(
            try IntakeContextDigests.clientPayloadHash(batch: batch, operation: changed),
            try operation.string(named: "client_payload_hash"))
        XCTAssertEqual(
            try IntakeContextDigests.projectionHash(batch: batch, operation: changed),
            try operation.string(named: "projection_hash"))
    }

    func testDomainScopeExcludesTransportAndLinkFields() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let baseline = try IntakeContextDigests.domainFactsHash(batch: batch, operation: operation)
        // installation_id, writer_bundle_id and batch_id never enter the domain facts digest.
        let otherBatch = batch
            .settingMember("installation_id", to: .string("another-installation"))
            .settingMember("writer_bundle_id", to: .string("another.writer"))
            .settingMember("batch_id", to: .string("00000000-0000-4000-8000-000000000000"))
        XCTAssertEqual(try IntakeContextDigests.domainFactsHash(batch: otherBatch, operation: operation), baseline)
        // Neither do the delivery fields the operation carries.
        let excluded: [String: IntakeContextJSONValue] = [
            "operation_id": .string("ignored"),
            "projection_sequence": .string("ignored"),
            "healthkit_links": .array([]),
            "domain_facts_hash": .string("ignored"),
            "projection_hash": .string("ignored"),
            "client_payload_hash": .string("ignored"),
        ]
        var changed = operation
        for (key, value) in excluded { changed = changed.settingMember(key, to: value) }
        XCTAssertEqual(try IntakeContextDigests.domainFactsHash(batch: otherBatch, operation: changed), baseline)
        // The producer scope is inside every digest, so a different producer never collides.
        let otherProducer = otherBatch.settingMember("producer_id", to: .string("another-producer"))
        XCTAssertNotEqual(try IntakeContextDigests.domainFactsHash(batch: otherProducer, operation: operation), baseline)
    }

    func testClientPayloadCoversTheBatchScopeAndTheNestedDigests() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let baseline = try IntakeContextDigests.clientPayloadHash(batch: batch, operation: operation)
        for key in ["writer_bundle_id", "installation_id", "schema_version"] {
            let changedBatch = batch.settingMember(key, to: .string("changed-\(key)"))
            XCTAssertNotEqual(
                try IntakeContextDigests.clientPayloadHash(batch: changedBatch, operation: operation),
                baseline,
                "\(key) is inside the client payload digest")
        }
        let otherProducer = batch.settingMember("producer_id", to: .string("another-producer"))
        XCTAssertNotEqual(try IntakeContextDigests.clientPayloadHash(batch: otherProducer, operation: operation), baseline)
        // The client digest covers the other two digests, so a rewritten one moves it.
        let tampered = operation.settingMember("domain_facts_hash", to: .string("sha256:" + String(repeating: "0", count: 64)))
        XCTAssertNotEqual(try IntakeContextDigests.clientPayloadHash(batch: batch, operation: tampered), baseline)
    }

    func testFactsOrderIsContentButMembersOfABlendToo() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let facts = try operation.array(named: "facts")
        let reversed = operation.settingMember("facts", to: .array(facts.reversed()))
        XCTAssertNotEqual(
            try IntakeContextDigests.domainFactsHash(batch: batch, operation: reversed),
            try IntakeContextDigests.domainFactsHash(batch: batch, operation: operation))

        let blendBatch = try Self.batch(named: "valid_proprietary_blend.json")
        let blend = try XCTUnwrap(Self.operations(of: blendBatch).first)
        let blendFacts = try blend.array(named: "facts")
        let blendFact = blendFacts[1]
        let members = try blendFact.array(named: "members")
        XCTAssertEqual(members.count, 3)
        let changedBlend = blend.settingMember(
            "facts",
            to: .array([blendFacts[0], try blendFact.settingMember("members", to: .array(members.reversed())), blendFacts[2]]))
        XCTAssertNotEqual(
            try IntakeContextDigests.domainFactsHash(batch: blendBatch, operation: changedBlend),
            try IntakeContextDigests.domainFactsHash(batch: blendBatch, operation: blend))
    }

    func testProjectionHashChangesWithASyncVersionOrDisposition() throws {
        let batch = try Self.batch(named: "valid_worked_example.json")
        let operation = try XCTUnwrap(Self.operations(of: batch).first)
        let link = try XCTUnwrap(operation.array(named: "healthkit_links").first)
        let baseline = try IntakeContextDigests.projectionHash(batch: batch, operation: operation)
        let newer = operation.settingMember(
            "healthkit_links",
            to: .array([try link.settingMember("sync_version", to: .integer("3"))]))
        XCTAssertNotEqual(try IntakeContextDigests.projectionHash(batch: batch, operation: newer), baseline)
        let superseded = operation.settingMember(
            "healthkit_links",
            to: .array([try link.settingMember("disposition", to: .string("superseded"))]))
        XCTAssertNotEqual(try IntakeContextDigests.projectionHash(batch: batch, operation: superseded), baseline)
    }

    // MARK: - Fixture helpers

    /// `contracts/intake-context/fixtures` walked up from this file, the same way the export test finds its
    /// canonical contract, so the committed fixtures are the ones under test.
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

    private static func batch(named name: String, file: StaticString = #filePath) throws -> IntakeContextJSONValue {
        let directory = try XCTUnwrap(
            fixtureDirectory(file: file),
            "contracts/intake-context/fixtures is missing")
        return try batch(named: name, in: directory)
    }

    private static func batch(named name: String, in directory: URL) throws -> IntakeContextJSONValue {
        let url = directory.appendingPathComponent(name)
        return try IntakeContextJSONReader.read(Data(contentsOf: url))
    }

    private static func operations(of batch: IntakeContextJSONValue) throws -> [IntakeContextJSONValue] {
        try batch.array(named: "operations")
    }
}
