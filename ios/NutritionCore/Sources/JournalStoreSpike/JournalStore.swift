import Foundation

/// Which schema generation a store file is opened with.
enum SpikeSchemaVersion: Sendable {
    case v1
    case v2
}

/// Whether opening a v1 file with the v2 schema may migrate it.
enum MigrationBehavior: Sendable {
    case migrate
    case failForTesting
}

enum SpikeError: Error, Equatable {
    case closed
    case injectedSaveFailure
    case injectedMigrationFailure
    case storeLoadFailed(String)
}

/// One revision of an intake. Amounts are decimal text, never binary floating point.
struct IntakeRevision: Equatable, Sendable {
    var intakeID: String
    var number: Int
    var payload: String
    var amountText: String
    /// Added in schema v2. A v1 store reads it back as an empty string.
    var note: String
}

/// A pending sync operation that must exist if and only if its revision exists.
struct OutboxOperation: Equatable, Sendable {
    var operationID: String
    var intakeID: String
    var revisionNumber: Int
    var kind: String
}

protocol JournalStore: AnyObject {
    /// When true, the next save inserts its rows and then fails before committing.
    var failNextSaveForTesting: Bool { get set }

    /// Saves a revision and its outbox operation in one transaction.
    func save(revision: IntakeRevision, outbox: OutboxOperation) throws
    /// Revisions sorted by intake id then revision number.
    func revisions() throws -> [IntakeRevision]
    /// Outbox operations sorted by operation id.
    func outboxOperations() throws -> [OutboxOperation]
    /// Reads revisions through a context created on a background executor.
    func revisionsFromBackground() async throws -> [IntakeRevision]
    /// Releases the store; a new instance can reopen the same file.
    func close()
}

func sortedRevisions(_ items: [IntakeRevision]) -> [IntakeRevision] {
    items.sorted { ($0.intakeID, $0.number) < ($1.intakeID, $1.number) }
}

func sortedOutbox(_ items: [OutboxOperation]) -> [OutboxOperation] {
    items.sorted { $0.operationID < $1.operationID }
}
