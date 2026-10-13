import Foundation

/// Bounds the amount of work a journal import may ask the device to do.
///
/// These limits apply to imports only. Export remains an unrestricted description of the local journal.
public struct JournalImportLimits: Sendable, Equatable {
    public static let `default` = JournalImportLimits(
        maxImportBytes: 20 * 1024 * 1024,
        maxAggregateElements: 100_000)

    /// Largest accepted encoded document, in bytes.
    public let maxImportBytes: Int
    /// Largest combined number of elements across all collections the export schema defines.
    public let maxAggregateElements: Int

    public init(maxImportBytes: Int, maxAggregateElements: Int) {
        precondition(maxImportBytes >= 0)
        precondition(maxAggregateElements >= 0)
        self.maxImportBytes = maxImportBytes
        self.maxAggregateElements = maxAggregateElements
    }

    /// Checks byte size before parsing, then counts raw collection entries before the typed export is built.
    /// Invalid shapes are left to the importer's schema validation; only a valid collection shape can
    /// consume the aggregate budget here.
    func validate(_ data: Data) throws {
        guard data.count <= maxImportBytes else { throw JournalImportError.tooLarge }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var remaining = maxAggregateElements
        try consume(root["intakes"], from: &remaining)
        try consume(root["tombstones"], from: &remaining)
        try consume(root["favorites"], from: &remaining)
        try consume(root["products"], from: &remaining)

        guard let intakes = root["intakes"] as? [Any] else { return }
        for intakeItem in intakes {
            guard let intake = intakeItem as? [String: Any],
                  let revisions = intake["revisions"] as? [Any]
            else { continue }
            try consume(revisions.count, from: &remaining)
            for revisionItem in revisions {
                guard let revision = revisionItem as? [String: Any] else { continue }
                try consume(revision["components"], from: &remaining)
            }
        }

        guard let favorites = root["favorites"] as? [Any] else { return }
        for favoriteItem in favorites {
            guard let favorite = favoriteItem as? [String: Any] else { continue }
            try consume(favorite["components"], from: &remaining)
        }
    }

    private func consume(_ value: Any?, from remaining: inout Int) throws {
        guard let collection = value as? [Any] else { return }
        try consume(collection.count, from: &remaining)
    }

    /// Subtraction keeps the sum safe even when untrusted arrays are individually very large.
    private func consume(_ count: Int, from remaining: inout Int) throws {
        guard count <= remaining else { throw JournalImportError.tooLarge }
        remaining -= count
    }
}
