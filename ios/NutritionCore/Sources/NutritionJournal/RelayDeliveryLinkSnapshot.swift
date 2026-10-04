import Foundation
import NutritionDomain

/// The link snapshot as the outbox row stores it, so a retry rebuilds the operation it first sent.
///
/// **This exists because a retry is not a fresh encode.** An upsert's `operation_id` is its delivery
/// identity, and the receiver reads the same identity with the same `client_payload_hash` as a duplicate
/// and with a different one as a conflict. Links that arrived between two attempts — a HealthKit save
/// revealing a sample UUID — would move that hash, so the retry of a lost response would come back as a
/// conflict instead of the duplicate it is. Recording the snapshot with the first attempt is what makes
/// "the same payload under the same identity" true rather than merely likely.
///
/// The text is the canonical form `IntakeContextEncoder` writes links in, member for member, so what is
/// stored is exactly what was hashed: `projection_hash` and `client_payload_hash` are computed over these
/// members, and a re-spelling of the same values would be different content.
public enum RelayDeliveryLinkSnapshot {
    /// The canonical text of one link snapshot.
    public static func encode(_ links: [IntakeContextLink]) throws -> String {
        let value = IntakeContextJSONValue.array(links.map(member))
        return String(decoding: IntakeContextCanonicalJSON.encode(value), as: UTF8.self)
    }

    /// The links a recorded snapshot holds.
    ///
    /// Refuses a snapshot this build cannot read rather than answering with an empty one: an empty snapshot
    /// is a meaningful value here — it says "this operation was sent with no links" — so a decode that
    /// quietly yielded nothing would send the retry as a different payload under the same identity, which
    /// is the exact failure the recorded snapshot exists to prevent.
    public static func decode(_ text: String) throws -> [IntakeContextLink] {
        let value = try IntakeContextJSONReader.read(Data(text.utf8))
        guard case .array(let elements) = value else {
            throw RelayDeliveryLinkSnapshotError.notAnArray
        }
        return try elements.map(link)
    }

    private static func member(_ link: IntakeContextLink) -> IntakeContextJSONValue {
        .object([
            "component_id": .string(link.componentID),
            "healthkit_sample_uuid": .string(link.sampleUUID),
            "healthkit_type": .string(link.healthKitTypeIdentifier),
            "sync_identifier": .string(link.syncIdentifier),
            "sync_version": .integer(String(link.syncVersion)),
            "disposition": .string(link.disposition.rawValue),
        ])
    }

    private static func link(_ value: IntakeContextJSONValue) throws -> IntakeContextLink {
        guard let componentID = value.string("component_id"),
              let sampleUUID = value.string("healthkit_sample_uuid"),
              let type = value.string("healthkit_type"),
              let syncIdentifier = value.string("sync_identifier"),
              let version = value.integer("sync_version"),
              let disposition = value.string("disposition"),
              let parsed = IntakeContextLinkDisposition(rawValue: disposition)
        else { throw RelayDeliveryLinkSnapshotError.malformedLink }
        return IntakeContextLink(
            componentID: componentID, sampleUUID: sampleUUID, healthKitTypeIdentifier: type,
            syncIdentifier: syncIdentifier, syncVersion: version, disposition: parsed)
    }
}

/// Why a recorded link snapshot could not be read back.
///
/// Every case means the journal holds something it cannot send as it was recorded, which is a permanent
/// failure of that operation rather than a retry: the same text would fail to decode again.
public enum RelayDeliveryLinkSnapshotError: Error, Equatable, Sendable {
    /// The recorded text is not a JSON array.
    case notAnArray
    /// A member is missing, or holds a value of another kind.
    case malformedLink
}