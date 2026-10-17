import Foundation

/// What the phone hands an Apple Watch: the Today summary the widgets already show, in an envelope that says which
/// erase it follows. Nothing else crosses: no entry names, meal times, supplements or account data.
struct WatchSnapshotEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1
    /// The key the encoded envelope is stored under in the application context.
    static let contextKey = "todaySummary"
    /// A payload larger than this is not decoded; an envelope is a few hundred bytes.
    static let maximumPayloadBytes = 4_096

    var schemaVersion: Int
    /// Moves on every Erase all data on the phone; a context from before an erase can then be recognised.
    var eraseGeneration: Int
    /// The summary, or nil after an erase.
    var snapshot: WidgetSnapshot?
    /// Names this install of the phone app. The erase generation is only comparable within one epoch: after a
    /// reinstall or a new phone the counter starts again, and the Watch restarts its own comparison when the epoch
    /// it sees changes. Absent in an envelope from a build that did not send one.
    var epoch: String?

    init(
        eraseGeneration: Int, snapshot: WidgetSnapshot?, epoch: String? = nil,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.eraseGeneration = eraseGeneration
        self.snapshot = snapshot
        self.epoch = epoch
    }

    /// The application context for this envelope.
    func context() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [Self.contextKey: try encoder.encode(self)]
    }

    enum Decoded: Equatable {
        case envelope(WatchSnapshotEnvelope)
        /// An envelope from a newer or older format than this build reads: shown as dashes, never a crash.
        case unsupportedSchema
        /// Missing, malformed or oversized: shown as dashes.
        case invalid
    }

    /// Reads a context a phone sent. Unknown fields are tolerated; an unknown schema version, a malformed payload
    /// and an oversized payload are reported, not thrown.
    static func decode(context: [String: Any]) -> Decoded {
        guard let data = context[contextKey] as? Data, data.count <= maximumPayloadBytes else { return .invalid }
        struct Header: Decodable { var schemaVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return .invalid }
        guard header.schemaVersion == currentSchemaVersion else { return .unsupportedSchema }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(WatchSnapshotEnvelope.self, from: data) else { return .invalid }
        return .envelope(envelope)
    }
}

/// Where an envelope goes. The phone's real implementation sits on WatchConnectivity, which does not exist on every
/// platform the package tests build on, so everything above it is written against this and tested with a fake.
protocol WatchSnapshotTransport: AnyObject, Sendable {
    /// True when a context can be sent now: the session is active, a Watch is paired and the Watch app installed.
    var canSend: Bool { get }
    /// Replaces the context the Watch will receive. The last one wins.
    func send(context: [String: Any]) throws
}
