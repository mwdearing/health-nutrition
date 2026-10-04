import CryptoKit
import Foundation

/// The three digests of an intake-context operation.
///
/// The receiver recomputes every digest it needs from the operation it received and rejects an operation whose
/// supplied digest does not match, so these have to be byte-identical to the receiver's. Each digest includes
/// the producer scope, so the same `intake_id` from a different producer never collides, and
/// `client_payload_hash` covers the other two.
///
/// `batch` is the whole batch object and `operation` is one entry of its `operations` array, both read with
/// `IntakeContextJSONReader` so that a decimal keeps its spelling.
enum IntakeContextDigests {
    /// The operation fields that never enter the domain facts digest: delivery identity, the transport link
    /// snapshot and the three digests themselves.
    static let domainFactsExcludedFields = [
        "operation_id",
        "projection_sequence",
        "healthkit_links",
        "domain_facts_hash",
        "projection_hash",
        "client_payload_hash",
    ]

    /// `domain_facts_hash`: the immutable facts at `(owner, producer, intake_id, revision)`.
    ///
    /// It covers `producer_id` from the batch plus every operation field except `operation_id`,
    /// `projection_sequence`, `healthkit_links` and the three digests. `installation_id` never enters it, so
    /// the same facts replayed from a reinstalled app hash the same.
    static func domainFactsHash(batch: IntakeContextJSONValue, operation: IntakeContextJSONValue) throws -> String {
        digest(try domainFactsValue(batch: batch, operation: operation))
    }

    /// `projection_hash`: one complete link snapshot of one revision at one sequence.
    ///
    /// The links are sorted by `(component_id, healthkit_sample_uuid)` compared by code point, so the order in
    /// which the app listed them does not matter. A repeated pair is rejected before hashing, so the order is
    /// total.
    static func projectionHash(batch: IntakeContextJSONValue, operation: IntakeContextJSONValue) throws -> String {
        digest(try projectionBytes(batch: batch, operation: operation))
    }

    /// The canonical bytes hashed for `projection_hash`, exposed so a test can hold the receiver's worked
    /// vector byte for byte.
    static func projectionBytes(batch: IntakeContextJSONValue, operation: IntakeContextJSONValue) throws -> Data {
        IntakeContextCanonicalJSON.encode(try projectionValue(batch: batch, operation: operation))
    }

    /// `client_payload_hash`: the delivered content of one `operation_id`.
    ///
    /// It covers `producer_id`, `writer_bundle_id`, `installation_id` and `schema_version` from the batch plus
    /// the operation without its own `client_payload_hash`, including the other two digests and any additive
    /// field a later minor version sends. It is the only digest that moves when the installation or the
    /// asserted HealthKit writer changes.
    static func clientPayloadHash(batch: IntakeContextJSONValue, operation: IntakeContextJSONValue) throws -> String {
        digest(try clientPayloadValue(batch: batch, operation: operation))
    }

    // MARK: - The values that are hashed

    static func domainFactsValue(batch: IntakeContextJSONValue, operation: IntakeContextJSONValue) throws -> IntakeContextJSONValue {
        var value = operation
        for field in domainFactsExcludedFields {
            value = value.removingMember(field)
        }
        return try withProducer(batch: batch, in: value)
    }

    static func projectionValue(batch: IntakeContextJSONValue, operation: IntakeContextJSONValue) throws -> IntakeContextJSONValue {
        let links = try operation.array(named: "healthkit_links")
        let ordered = try links.sorted { first, second in
            try linkPrecedes(first, second)
        }
        let value: IntakeContextJSONValue = .object([
            "producer_id": .string(try batch.string(named: "producer_id")),
            "intake_id": try operation.value(named: "intake_id"),
            "revision": try operation.value(named: "revision"),
            "projection_sequence": try operation.value(named: "projection_sequence"),
            "healthkit_links": .array(ordered),
        ])
        return value
    }

    static func clientPayloadValue(batch: IntakeContextJSONValue, operation: IntakeContextJSONValue) throws -> IntakeContextJSONValue {
        .object([
            "producer_id": .string(try batch.string(named: "producer_id")),
            "writer_bundle_id": .string(try batch.string(named: "writer_bundle_id")),
            "installation_id": .string(try batch.string(named: "installation_id")),
            "schema_version": .string(try batch.string(named: "schema_version")),
            "operation": operation.removingMember("client_payload_hash"),
        ])
    }

    // MARK: - Helpers

    private static func withProducer(batch: IntakeContextJSONValue, in value: IntakeContextJSONValue) throws -> IntakeContextJSONValue {
        guard case .object(var members) = value else {
            throw IntakeContextJSONError.missingMember("producer_id")
        }
        members["producer_id"] = .string(try batch.string(named: "producer_id"))
        return .object(members)
    }

    private static func linkPrecedes(_ first: IntakeContextJSONValue, _ second: IntakeContextJSONValue) throws -> Bool {
        let leftComponent = try first.string(named: "component_id")
        let rightComponent = try second.string(named: "component_id")
        if leftComponent != rightComponent {
            return IntakeContextCanonicalJSON.precedesByCodePoint(leftComponent, rightComponent)
        }
        let leftSample = try first.string(named: "healthkit_sample_uuid")
        let rightSample = try second.string(named: "healthkit_sample_uuid")
        return IntakeContextCanonicalJSON.precedesByCodePoint(leftSample, rightSample)
    }

    /// `sha256:` followed by the lowercase hexadecimal SHA-256 of the canonical bytes.
    private static func digest(_ value: IntakeContextJSONValue) -> String {
        digest(IntakeContextCanonicalJSON.encode(value))
    }

    private static func digest(_ bytes: Data) -> String {
        var text = "sha256:"
        for byte in SHA256.hash(data: bytes) {
            text += String(format: "%02x", byte)
        }
        return text
    }
}
