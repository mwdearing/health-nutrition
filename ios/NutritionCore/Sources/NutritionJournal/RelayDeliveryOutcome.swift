import Foundation

/// Reading the receiver's reply, which is JSON but not a payload this module ever encodes.
///
/// The contract has no floating-point numbers anywhere, and its integers arrive as the literal text the
/// receiver wrote, so an integer is parsed from that text rather than through a binary floating point type
/// that would round it and quietly change what a revision or a cursor says.
extension IntakeContextJSONValue {
    /// This value as an integer, or nil when it is not one.
    var relayIntegerValue: Int? {
        guard case .integer(let text) = self else { return nil }
        return Int(text)
    }

    /// A member of an object as an integer, or nil when it is missing or is not one.
    func integer(_ key: String) -> Int? {
        member(key)?.relayIntegerValue
    }
}

/// What the receiver answered for one operation of a batch.
///
/// The receiver reports a result per operation, in the order the batch sent them, and these are its seven
/// spellings. The raw values are the contract's own, not Swift's spelling of them, because they travel
/// over the wire and a renamed case would be a renamed protocol value.
public enum RelayOperationResult: String, Sendable, Equatable, Hashable, CaseIterable {
    /// The receiver applied the operation and holds it as its current state.
    case accepted
    /// The receiver already holds exactly this operation: the same `operation_id` with the same
    /// `client_payload_hash`. A retry after a lost response lands here, which is why a lost response is
    /// harmless rather than a conflict.
    case duplicate
    /// The receiver already holds a newer revision of this intake, so this operation is obsolete and
    /// was not applied.
    case staleRevision = "stale_revision"
    /// What the operation says about the intake disagrees with what the receiver already holds. Both
    /// sides are durable records of the same facts, so no retry can settle it.
    case domainConflict = "domain_conflict"
    /// The link snapshot disagrees with the projection the receiver already holds, for the same reason.
    case projectionConflict = "projection_conflict"
    /// The receiver could not apply the operation this time and expects the same one again later.
    case retryableFailure = "retryable_failure"
    /// The receiver will never apply this operation: the payload itself is refused.
    case permanentFailure = "permanent_failure"

    /// Whether this result is a success, in the sense that the receiver now holds what was sent.
    ///
    /// A duplicate counts: the receiver holding the operation twice is not a different state from holding
    /// it once, so a redelivery after a lost response has nothing left to do either way.
    public var isAccepted: Bool {
        switch self {
        case .accepted, .duplicate: return true
        case .staleRevision, .domainConflict, .projectionConflict, .retryableFailure, .permanentFailure:
            return false
        }
    }

    /// Whether this result is resolved, meaning nothing later for the same intake may go out until a
    /// person intervenes.
    ///
    /// A stale revision is resolved: the receiver has a newer one, so this operation is finished with and
    /// every later operation for the intake is newer still. A conflict and a permanent failure are not:
    /// they are parked for a person, and a scheduler that retried either would fail on a timer forever and
    /// hide the real disagreement behind a queue that never drains.
    public var isResolved: Bool {
        switch self {
        case .accepted, .duplicate, .staleRevision: return true
        case .domainConflict, .projectionConflict, .retryableFailure, .permanentFailure: return false
        }
    }

    /// What this result is called when it is reported to a person.
    ///
    /// The raw value with `_` read as a space, so the reason a suspension is stored under names the
    /// receiver's own answer rather than a phrase invented here that would have to be kept in step with it.
    public var reasonText: String {
        switch self {
        case .accepted: return "accepted"
        case .duplicate: return "duplicate"
        case .staleRevision: return "stale revision"
        case .domainConflict: return "domain conflict"
        case .projectionConflict: return "projection conflict"
        case .retryableFailure: return "retryable failure"
        case .permanentFailure: return "permanent failure"
        }
    }
}

/// What the receiver reported about one operation, as its own answer read back.
///
/// Every optional member is nullable in the receiver's reply and stays optional here: an `accepted`
/// upsert carries an accepted revision, a `stale_revision` carries the revision that superseded it, and a
/// failure may carry only a detail. Reading them as present whether or not the receiver sent them would
/// put an invented revision in the journal's own record.
public struct RelayOperationResponse: Sendable, Equatable {
    /// The delivery identity this answer is about, which is how it is matched back to a queued operation.
    public let operationID: String
    public let result: RelayOperationResult
    /// The revision the receiver now holds for this intake, on an accepted operation.
    public let acceptedRevision: Int?
    /// The projection sequence the receiver now holds, on an accepted link snapshot.
    public let projectionSequence: Int?
    /// The receiver's position in its own stream, which is what a later run resumes from.
    public let serverCursor: Int?
    /// The revision the receiver holds instead, on a stale revision.
    public let currentRevision: Int?
    /// The receiver's own words, when it gave any.
    public let detail: String?

    public init(
        operationID: String,
        result: RelayOperationResult,
        acceptedRevision: Int? = nil,
        projectionSequence: Int? = nil,
        serverCursor: Int? = nil,
        currentRevision: Int? = nil,
        detail: String? = nil
    ) {
        self.operationID = operationID
        self.result = result
        self.acceptedRevision = acceptedRevision
        self.projectionSequence = projectionSequence
        self.serverCursor = serverCursor
        self.currentRevision = currentRevision
        self.detail = detail
    }

    /// One entry of the receiver's `results` array, or nil when it names no known result.
    ///
    /// Refused rather than defaulted for the one thing that must not be guessed: an entry whose `result` is
    /// a spelling this build does not know could be a success or a permanent failure, and reading it as one
    /// of them would either lose an operation or record a failure that never happened. Every other member
    /// is nullable in the receiver's reply and stays optional here, so an absent `accepted_revision` is
    /// reported as absent rather than as zero.
    init?(entry: IntakeContextJSONValue) {
        guard let operationID = entry.string("operation_id"),
              let raw = entry.string("result"),
              let result = RelayOperationResult(rawValue: raw)
        else { return nil }
        self.init(
            operationID: operationID,
            result: result,
            acceptedRevision: entry.integer("accepted_revision"),
            projectionSequence: entry.integer("projection_sequence"),
            serverCursor: entry.integer("server_cursor"),
            currentRevision: entry.integer("current_revision"),
            detail: entry.string("detail"))
    }
}

/// What one delivery run did, per operation, so a caller (or a log) can see it without re-reading the
/// store.
///
/// `operationID` is in every case, because one run may touch several operations. Which cases are *resolved*
/// is what decides whether a later operation for the same intake may go out: only a resolved outcome
/// releases the intake, because an operation that is deferred, blocked or waiting for a person holds up
/// everything queued behind it — the receiver applies a batch in array order, so an operation that skipped
/// ahead would be applied before the revision it supersedes.
public enum RelayDeliveryOutcome: Sendable, Equatable {
    /// The receiver holds this operation: `accepted`, or `duplicate` on a retry after a lost response.
    ///
    /// `acceptedRevision` and `serverCursor` are what the receiver reported, kept exactly as reported and
    /// possibly absent. They are returned rather than written here on purpose: the journal's outbox stores
    /// what it delivered and when, and the receiver's accepted revision and cursor are its own stream
    /// position, which belongs to the HealthRelay connection that will read them back.
    case delivered(operationID: String, acceptedRevision: Int?, serverCursor: Int?)
    /// The receiver already holds a newer revision of this intake, so this operation is acknowledged
    /// rather than sent again. `detail` is the receiver's own wording when it gave any.
    case superseded(operationID: String, detail: String?)
    /// The operation is parked until someone re-arms it, because retrying cannot settle what happened.
    /// No automatic run will send it again: `reason` names the receiver's answer, or the status that
    /// carried it.
    case needsAttention(operationID: String, reason: String)
    /// The receiver took the batch but would not apply the operation yet, or the attempt failed in a way
    /// worth another try. The operation stays pending and is due again at `nextAttemptAt`.
    case retryScheduled(operationID: String, nextAttemptAt: Date, reason: String)
    /// The operation is not due yet; `nextAttemptAt` says when it becomes due.
    case notDue(operationID: String, nextAttemptAt: Date)
    /// An earlier operation for the same intake is unresolved, so this one was not attempted.
    case blocked(operationID: String, blockedBy: String)
    /// The receiver's answer could not be matched to what was sent, so nothing was recorded for the
    /// operation and it stays pending. Deliberately unresolved: an operation whose delivery is unknown
    /// must not release the revisions queued behind it.
    case notAcknowledged(operationID: String, detail: String)
    /// The run stopped before this operation was attempted, because the receiver rejected the token.
    /// Nothing was sent for it and it is untouched: a run that stops on a rejected token says so rather
    /// than reporting a delivery it did not attempt.
    case notAttempted(operationID: String, reason: String)

    /// True when this operation is finished with and must not hold up the next one for its intake.
    public var isResolved: Bool {
        switch self {
        case .delivered, .superseded: return true
        case .needsAttention, .retryScheduled, .notDue, .blocked, .notAcknowledged, .notAttempted:
            return false
        }
    }

    /// The operation this outcome is about, so a caller can line outcomes up with its own queue.
    public var operationID: String {
        switch self {
        case .delivered(let id, _, _), .superseded(let id, _), .needsAttention(let id, _),
             .retryScheduled(let id, _, _), .notDue(let id, _), .blocked(let id, _),
             .notAcknowledged(let id, _), .notAttempted(let id, _):
            return id
        }
    }
}