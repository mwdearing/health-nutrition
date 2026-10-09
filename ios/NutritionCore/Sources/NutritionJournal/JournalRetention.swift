import Foundation

/// How long journal data is kept once it is no longer needed for delivery.
public enum JournalRetention {
    /// An acknowledged outbox row is pruned once it was acknowledged more than this many days before the
    /// pass runs. Unacknowledged rows, tombstones, revisions, snapshots and projections are never pruned.
    public static let acknowledgedOutboxDays = 30
}
