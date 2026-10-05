import CryptoKit
import Foundation
import NutritionDomain

/// Supplies the HealthKit links one revision's upsert carries.
///
/// The journal does not know which samples exist: that is `HealthKitWritePlanner`'s business and the
/// writer's. So the links are injected, and the default is **no links at all**, which the contract reads
/// as "nothing has been linked yet" rather than as an omitted field.
///
/// Every link is a claim the receiver verifies against the sample it holds, so a link built from anything
/// other than a sample HealthKit actually saved is a permanent failure at the receiver rather than a retry
/// that could fix it.
public typealias RelayLinkProvider = @Sendable (_ intake: Intake, _ revision: IntakeRevision) -> [IntakeContextLink]

/// Supplies the tombstone a queued delete is encoded with, given the deletion instant the journal recorded.
///
/// `deleted_at` is hashed into both the domain and the client digest, so the same delete rebuilt on a
/// later attempt has to carry the same instant or the receiver reports a conflict instead of the
/// duplicate it actually is. It therefore cannot be a fresh reading of the clock, and it cannot be derived
/// from the revision: `delete(intakeID:now:)` knows when the person deleted the entry, and that is what the
/// receiver should hold. The worker reads the instant the delete row recorded and passes it here.

/// One link-only change to a revision whose facts the receiver already holds.
///
/// Sequence 1 belongs to the revision's upsert, so every projection here starts at 2 and carries the
/// complete link snapshot, never a delta. Its delivery identity is derived from the intake, the revision
/// and the sequence rather than taken from an outbox row: the row that delivered sequence 1 would report
/// a conflict for a second payload under one id, and a derived id is stable across retries.
public struct RelayLinkProjection: Sendable, Equatable {
    public let intakeID: String
    public let revision: Int
    public let sequence: Int
    public let links: [IntakeContextLink]

    public init(intakeID: String, revision: Int, sequence: Int, links: [IntakeContextLink]) {
        self.intakeID = intakeID
        self.revision = revision
        self.sequence = sequence
        self.links = links
    }

    /// The identity this projection is sent under, the same one `IntakeContextEncoder` derives.
    public var operationID: String {
        IntakeContextEncoder.linkProjectionOperationID(
            intakeID: intakeID, revision: revision, sequence: sequence)
    }
}

/// What became of one link projection.
///
/// A link projection has **no outbox row**, so the journal cannot record anything about it: there is
/// nowhere to keep an attempt count, a retry date or a suspension. The queue that offered it is therefore
/// told what happened and owns what to do next. That is the honest division — this module decides the
/// outcome, and the holder of the payload decides where it waits.
public enum RelayLinkProjectionResolution: Sendable, Equatable {
    /// The receiver holds this projection now.
    case delivered(acceptedRevision: Int?, serverCursor: Int?)
    /// The receiver already holds a newer revision, so the projection is obsolete.
    case superseded
    /// Parked until a person re-arms it; retrying cannot settle what the receiver disagreed with.
    case needsAttention(String)
    /// Worth another attempt, but not before `Date`.
    ///
    /// **A projection needs this as much as an outbox row needs `nextAttemptAt`.** Without it a queue
    /// offers the same projection on the next run whatever the receiver said, so a run triggered for
    /// unrelated work would retry it immediately and defeat both the backoff and a stated `Retry-After` —
    /// against a receiver that had just asked this producer to stop.
    case retryAfter(Date, reason: String)
}

/// Where pending link-only changes are read from and their outcomes recorded.
///
/// Injected rather than held here because the journal has no queue of its own for them: a projection
/// appears when a HealthKit save reveals a sample UUID after the facts were accepted, which is the
/// writer's knowledge and not the journal's. `RelayLinkProjectionQueueNone` is the default, so a worker
/// built with nothing else sends no projection at all.
public protocol RelayLinkProjectionQueue: Sendable {
    /// The projections to try, in the order they should be sent.
    func pendingLinkProjections() async throws -> [RelayLinkProjection]

    /// Records what happened to one projection. Awaited rather than ignored, so a queue that has to write
    /// its own record has done so before the run moves on.
    func resolve(_ projection: RelayLinkProjection, with resolution: RelayLinkProjectionResolution) async
}

/// The queue of a worker that sends no link projections at all.
///
/// This is the default, and it is part of what keeps delivery off until the HealthRelay connection ships:
/// with nothing queuing projections, a run sends upserts and deletes only.
public struct RelayLinkProjectionQueueNone: RelayLinkProjectionQueue {
    public init() {}

    public func pendingLinkProjections() async throws -> [RelayLinkProjection] { [] }

    public func resolve(
        _ projection: RelayLinkProjection, with resolution: RelayLinkProjectionResolution
    ) async {}
}

/// Supplies the intake token for one batch.
///
/// **Called once per batch, not once per run.** A token is a credential the connection refreshes, and a run
/// that captured one at initialization would keep sending a value that expired partway through — every
/// later batch refused with a 401, and its operations parked for a reason that was already stale. Asking
/// per batch costs nothing and is what lets one run straddle a rotation.
///
/// Throwing is part of the contract: a connection that cannot mint a token has not sent anything, so the
/// batch was not attempted and the worker reschedules it rather than parking operations against a
/// credential problem that may pass.
public typealias RelayTokenProvider = @Sendable () async throws -> String

/// The journal a relay delivery reads: the queue and its suspensions, the tombstones a delete is encoded
/// from, and the two durable records a hashed payload cannot be rebuilt without.
///
/// `JournalTombstoneSource` is named here rather than a new method of its own because the SwiftData store
/// already keeps tombstones for the exporter; asking for them under a second name would be two ways of
/// reading one thing. A store that cannot list tombstones cannot back this worker, which is honest: without
/// a tombstone there is no durable instant to encode a delete with.
///
/// `deletionInstant(operationID:)` and `recordedLinks(operationID:)`/`recordLinks(_:operationID:)` are the
/// same idea from the other side. `deleted_at` and `healthkit_links` are both inside the digests, so a
/// rebuild that named different values would arrive under the same `operation_id` with a different
/// `client_payload_hash` — a conflict at the receiver, where a duplicate is what it should be. A store that
/// cannot keep either cannot deliver a retry correctly, so it cannot back this worker either.
    ///
    /// `recordLinks(_:operationID:)` is called immediately before the piece carrying the operation is sent, not
    /// for a whole batch at packing time, and it reports whether it created the record — so only a record this
    /// run wrote is ever released, and an operation whose piece never carries it keeps nothing on record.
public protocol RelayDeliveryStore: JournalDeliverySuspension, JournalTombstoneSource {
    /// The instant the intake was deleted, as the queued delete row recorded it, or nil when it recorded
    /// none. A nil delete is delivered from the journal's own last-revision record rather than stranded.
    func deletionInstant(operationID: String) throws -> Date?

    /// The link snapshot this operation was first encoded with, or nil when nothing has been recorded.
    func recordedLinks(operationID: String) throws -> [IntakeContextLink]?

    /// Records the snapshot an operation is about to be sent under, keeping the first one it is given, and
    /// answers with the snapshot that is on record afterwards together with whether **this call wrote it**.
    ///
    /// A returned snapshot that is not the one offered says another run recorded a different one first, so the
    /// record does not hold what this caller is about to send. `isNew` distinguishes the case where the
    /// returned snapshot *is* the offered one because this call wrote it, from the case where it was already
    /// there: only the former may be discarded later, since the latter may be another run's.
    @discardableResult
    func recordLinks(
        _ links: [IntakeContextLink], operationID: String
    ) throws -> (snapshot: [IntakeContextLink], isNew: Bool)

    /// Forgets the snapshot recorded for an operation whose **split** request the receiver refused for size.
    ///
    /// A 413 applies none of its body, so nothing was committed under those delivery identities and there is
    /// nothing for a later attempt to reproduce. Forgetting the snapshot is what lets each split piece record
    /// the links current when it goes out, and leaves an operation whose piece never carried it with nothing
    /// on record.
    ///
    /// **Only a record this run wrote may be passed here.** One already on record belongs to an earlier attempt
    /// whose answer may have been lost, or to an overlapping run that is about to send it, and the receiver may
    /// already hold that payload under the operation id.
    ///
    /// **A sole operation refused with 413 is not released.** There is no split: the payload was sent, read and
    /// refused for its size, and it is parked. A re-armed attempt has to repeat that same payload.
    func releaseLinks(operationID: String) throws
}

/// Delivers queued journal operations to the HealthRelay receiver as intake-context batches (NC-09C).
///
/// One run (`runOnce(now:)`) walks the journal's pending outbox in queue order — oldest revision first, so
/// an edit is sent after the revision it supersedes — and handles the operations addressed to `.relay`.
/// Operations for any other destination are left exactly as they are: a HealthKit operation is not this
/// worker's business, and acknowledging one would record another destination's delivery.
///
/// **Order is the receiver's to apply in, so it is the worker's to send in.** An operation that is still
/// pending, suspended or not due holds back every later operation for the same intake, and so does one
/// whose batch came back unresolved. The receiver applies a batch in array order and refuses an operation
/// whose revision is below one it already holds, so a revision that went past its predecessor would come
/// back `stale_revision` — the ordering rule is not tidiness, it is the delivery succeeding.
///
/// **Nothing here opens a connection.** The transport is injected, the batch limits come from the
/// receiver's own capabilities document, and the token is passed per call. The outcome mapping is on
/// `RelayDeliveryOutcome`; `docs/relay-delivery.md` has the rest.
///
/// **Delivery is off.** Nothing in the app enables the relay destination, so nothing is ever queued for
/// this worker and every run finds an empty queue. The worker exists and is tested; turning it on is a
/// separate decision, made when the HealthRelay connection ships.
public struct RelayDeliveryWorker: Sendable {
    /// The retry schedule after a transient failure: 1, 5 and 30 minutes, then every 2 hours.
    ///
    /// Backoff, not a fixed interval: a receiver failing once is usually a deployment or a proxy, while a
    /// failure that never clears is a network that is down, and an hourly retry costs nothing then.
    public static let backoffSchedule: [Int] = [60, 300, 1800, 7200]

    /// How long to wait after the `attemptNumber`th failure, counting from 1.
    ///
    /// Indexed by the count this failure will leave behind once `recordFailure` has run, and failures past
    /// the end reuse the last step, so the wait never shrinks.
    public static func backoffSeconds(afterAttempt attemptNumber: Int) -> Int {
        let index = min(max(attemptNumber - 1, 0), backoffSchedule.count - 1)
        return backoffSchedule[index]
    }

    private let store: any RelayDeliveryStore
    /// How a batch reaches the receiver. Injected: this module holds no session, no URL and no client.
    private let transport: any IntakeContextTransport
    /// Builds the canonical bytes and the three digests the receiver recomputes.
    private let encoder: IntakeContextEncoder
    /// Where pending link-only changes come from, and who records what became of them.
    private let projections: any RelayLinkProjectionQueue
    private let links: RelayLinkProvider
    /// The tombstone for one queued delete, given the instant the journal recorded when the intake was
    /// deleted.
    ///
    /// Three arguments rather than two because the deletion instant is the journal's to know: it is what
    /// `delete(intakeID:now:)` was given, and the worker reads it back rather than deriving one from a
    /// revision. A caller that wanted to override the record could, which is the point of injecting it.
    private let tombstones: @Sendable (Intake, IntakeRevision, Date) -> IntakeContextTombstone
    /// The intake token, asked for once per batch so a rotation mid-run is not a stale credential.
    private let token: RelayTokenProvider

    public init(
        store: any RelayDeliveryStore,
        transport: any IntakeContextTransport,
        encoder: IntakeContextEncoder,
        token: @escaping RelayTokenProvider,
        projections: any RelayLinkProjectionQueue = RelayLinkProjectionQueueNone(),
        links: @escaping RelayLinkProvider = { _, _ in [] },
        tombstones: @escaping @Sendable (Intake, IntakeRevision, Date) -> IntakeContextTombstone = {
            intake, _, deletedAt in IntakeContextTombstone(intakeID: intake.id, deletedAt: deletedAt)
        }
    ) {
        self.store = store
        self.transport = transport
        self.encoder = encoder
        self.token = token
        self.projections = projections
        self.links = links
        self.tombstones = tombstones
    }

    /// Processes every due `.relay` operation once and reports what each one did.
    ///
    /// `now` is the run's clock: it decides whether an operation is due, when a retry is scheduled and
    /// when a recorded delivery happened. It is a parameter rather than a read of `Date()` so a test, and a
    /// replay after a restart, both see the same decision.
    @discardableResult
    public func runOnce(now: Date) async -> [RelayDeliveryOutcome] {
        let operations: [OutboxOperation]
        let suspended: Set<String>
        do {
            operations = try store.pendingOutbox()
            suspended = try store.suspendedOperationIDs()
        } catch {
            // A store that cannot be read delivers nothing. The operations stay pending, so the next run
            // picks them up; reporting an error here would say less than the store already knows.
            return []
        }
        var outcomes: [RelayDeliveryOutcome] = []
        // The sendable prefix of each intake, in the order the queue offered the intakes.
        var sendable: [RelayEncodedOperation] = []
        // Intakes stopped by something, and the operation that stopped them.
        var blocking: [String: String] = [:]

        // **One walk per intake, and the first thing that cannot be sent is the end of the road.**
        // Whether an operation can go out is decided here and nowhere else: not due, suspended, or an
        // encoding failure. The first of those becomes that intake's blocker and every later operation of
        // the same intake is reported as blocked by it — including one that would itself have encoded
        // cleanly. The receiver applies a batch in array order and refuses a revision below one it holds,
        // so a sound revision offered after a broken one would come back stale; and deciding this per
        // operation is how the earlier attempts got it wrong, treating each failure independently and
        // letting a later one be judged against the wrong reference.
        //
        // An encoding failure is **rescheduled rather than parked**, because it is local and may be
        // correctable: a link snapshot naming a component the revision does not state is wrong once, not
        // wrong forever, and parking it would mean a correction could never be delivered. A conflict the
        // *receiver* reports is different, and is parked — see `resolve`.
        var queuedByIntake: [String: [OutboxOperation]] = [:]
        var intakeOrder: [String] = []
        // The newest upsert this run finds queued for each intake, with the identity it would be
        // sent under. It is what tells a link projection that a later revision is waiting behind it in the
        // same run, and what the projection is reported as blocked by until that upsert is accepted.
        var newestUpsert: [String: (revision: Int, operationID: String)] = [:]
        for operation in operations where operation.destination == .relay {
            if queuedByIntake[operation.intakeID] == nil { intakeOrder.append(operation.intakeID) }
            queuedByIntake[operation.intakeID, default: []].append(operation)
            if operation.kind == .upsert,
                newestUpsert[operation.intakeID].map({ $0.revision < operation.revision }) ?? true {
                newestUpsert[operation.intakeID] = (revision: operation.revision, operationID: operation.operationID)
            }
        }
        for intakeID in intakeOrder {
            // The operations this delete retracts: everything queued before it for the same intake. A
            // suspended one among them is finished with rather than parked — see the branch below.
            let retracted = Self.retractedByQueuedDelete(queuedByIntake[intakeID] ?? [])
            for operation in queuedByIntake[intakeID] ?? [] {
                if let blocker = blocking[intakeID] {
                    outcomes.append(.blocked(operationID: operation.operationID, blockedBy: blocker))
                    continue
                }
                if suspended.contains(operation.operationID), retracted.contains(operation.operationID) {
                    // **A delete queued behind a suspended upsert supersedes it.** The tombstone retracts
                    // exactly what the upsert would have put into the receiver, so leaving the upsert parked
                    // holds the retraction behind a suspension nothing releases: the person deleted the
                    // entry, and the receiver would keep it until someone re-armed an operation that is no
                    // longer worth sending. The delete decides what the receiver holds, and acknowledging
                    // the upsert is what takes it out of the queue and clears the suspension with it.
                    let superseded = acknowledge(
                        operation, now: now, outcome: .superseded(
                            operationID: operation.operationID,
                            detail: "a delete queued behind it retracts what it would have sent"))
                    outcomes.append(superseded)
                    // **A failed acknowledgement holds the intake back, and the delete with it.** Nothing was
                    // written, so the upsert is still queued and still suspended: the queue will offer it
                    // again and this run would keep deciding it is superseded. Sending the tombstone anyway
                    // would retract what the receiver holds while the journal still claims an upsert is
                    // outstanding for the same intake — and the receiver applies in array order, so the
                    // ordering rule depends on that claim being true. Reporting the intake as blocked leaves
                    // both for the next run, when the write may succeed.
                    if !superseded.isResolved {
                        blocking[intakeID] = operation.operationID
                    }
                    continue
                }
                if suspended.contains(operation.operationID) {
                    // Parked for a person: no automatic run retries it, and nothing later for this intake may
                    // go past it either, since it was never delivered.
                    //
                    // The reason comes from the store rather than from a phrase rebuilt here: this branch runs
                    // on every later pass and after every relaunch, and a rejected token and a domain conflict
                    // are parked in the same state while needing opposite corrections.
                    outcomes.append(.needsAttention(
                        operationID: operation.operationID,
                        reason: (try? store.suspensionReason(operationID: operation.operationID))
                            ?? "waiting to be re-armed"))
                    blocking[intakeID] = operation.operationID
                    continue
                }
                if let attemptAt = operation.nextAttemptAt, attemptAt > now {
                    outcomes.append(.notDue(operationID: operation.operationID, nextAttemptAt: attemptAt))
                    blocking[intakeID] = operation.operationID
                    continue
                }
                switch encode(operation) {
                case .superseded(let detail):
                    outcomes.append(acknowledge(
                        operation, now: now, outcome: .superseded(
                            operationID: operation.operationID, detail: detail)))
                case .failed(let reason):
                    outcomes.append(retry(operation, reason: reason, now: now))
                    blocking[intakeID] = operation.operationID
                case .encoded(let item):
                    sendable.append(item)
                }
            }
        }
        // Projections behind a newer upsert, settled once this run knows whether the receiver took it.
        var deferred: [(projection: RelayLinkProjection, supersededBy: String, detail: String)] = []
        // Projections come after an intake's queued operations, so the same rule applies to them and the
        // same `blocking` map decides: an intake stopped by a queued operation cannot send a projection, and
        // a projection that cannot be encoded stops the ones after it. They are later sequences of the same
        // revision, so letting them past an earlier one the receiver never accepted would ask it to
        // reconcile a state that was never established.
        for projection in (try? await projections.pendingLinkProjections()) ?? [] {
            if let blocker = blocking[projection.intakeID] {
                outcomes.append(.blocked(operationID: projection.operationID, blockedBy: blocker))
                continue
            }
            // **A projection of an older revision waits on the newer upsert queued beside it**, and is settled
            // after this run's sends rather than here. A newer revision's upsert carries a complete link
            // snapshot for its own revision and never a delta, so the older projection has nothing left to
            // say *once the receiver holds that revision* — which is a fact about the receiver, not about the
            // queue. Resolving it now would claim the newer revision is held on the strength of the newer
            // upsert merely being queued, and a run where that upsert is never sent, or comes back
            // unresolved, would discard a projection the receiver is still able to take.
            //
            // So it is deferred, and `settle(_:accepted:)` decides once this run knows what the upsert's
            // answer was. Until then it is neither sent nor resolved: sending it before the newer revision
            // would offer the receiver a projection for a revision it may not hold yet.
            if let newer = newestUpsert[projection.intakeID], newer.revision > projection.revision {
                deferred.append((
                    projection: projection,
                    supersededBy: newer.operationID,
                    detail: "revision \(projection.revision) is behind the revision \(newer.revision) queued "
                        + "for the same intake, whose upsert carries its own complete link snapshot"))
                continue
            }
            switch encode(projection) {
            case .superseded(let detail):
                // **Resolved in the queue and reported here.** The queue is told, because it owns where the
                // payload waits; the run reports it too, because an outcome list that silently drops
                // something the queue offered no longer reconciles with the queue, and a caller reading the
                // run would not know the projection had been settled.
                await projections.resolve(projection, with: .superseded)
                outcomes.append(.superseded(operationID: projection.operationID, detail: detail))
            case .failed:
                // A projection that cannot be encoded is the queue's problem to hear about: it offered a
                // payload this module refuses, and recording a failure here would be recording it with
                // nowhere to keep it.
                await projections.resolve(
                    projection,
                    with: .needsAttention("the link projection could not be encoded for delivery"))
                outcomes.append(.needsAttention(
                    operationID: projection.operationID,
                    reason: "the link projection could not be encoded for delivery"))
                blocking[projection.intakeID] = projection.operationID
            case .encoded(let item):
                sendable.append(item)
            }
        }
        // Nothing is going out, so no deferred projection can have been superseded by an accepted upsert.
        guard !sendable.isEmpty else {
            await settle(deferred, into: &outcomes)
            return outcomes
        }
        let capabilities: IntakeContextCapabilities
        do {
            capabilities = try await transport.capabilities()
        } catch {
            // The batch limits are the receiver's own numbers. Guessing them would produce the very 413
            // this run exists to avoid, so nothing is sent and every operation is rescheduled instead.
            //
            // **Only the operations that were eligible to send count as a failed attempt.** `sendable` is
            // exactly those — anything held back above never reached this point — so recording against all
            // of it advances the backoff only for operations that were genuinely going out.
            for item in sendable {
                outcomes.append(await retry(
                    item, reason: "the receiver's capabilities could not be read", now: now))
            }
            await settle(deferred, into: &outcomes)
            return outcomes
        }
        // **Both halves of the contract name are checked, and each has its own reason.** A receiver whose
        // `schema` is not ours is not a receiver of this contract at all — it may well speak a
        // compatible-looking version of something else — so its `supported_versions` says nothing about
        // whether it accepts our payloads. Checking the version alone would read that other endpoint's list
        // as agreement and send.
        //
        // The two are reported differently because they are different problems: one is a wrong endpoint,
        // the other is the right endpoint at a version this build does not speak. Either way the operations
        // are parked rather than retried, because retrying cannot change what a receiver understands, and
        // both are configuration facts a person settles rather than failures of the operations themselves.
        let mismatch: String?
        if capabilities.schema != IntakeContextEncoder.schema {
            mismatch =
                "the receiver is not an \(IntakeContextEncoder.schema) endpoint: it answered schema "
                + "\"\(capabilities.schema)\""
        } else if !capabilities.supports(schemaVersion: IntakeContextEncoder.schemaVersion) {
            mismatch =
                "the receiver does not accept \(IntakeContextEncoder.schema) "
                + "\(IntakeContextEncoder.schemaVersion); it supports "
                + capabilities.supportedVersions.joined(separator: ", ")
        } else {
            mismatch = nil
        }
        if let mismatch {
            for item in sendable {
                outcomes.append(await park(item, reason: mismatch, now: now))
            }
            await settle(deferred, into: &outcomes)
            return outcomes
        }
        var stopped = false
        // What the sends of this run left unresolved, by intake. Kept apart from `blocking`: that map holds
        // back what is *behind* a blocker found while walking the queue, and those operations never reach
        // here, while an operation *before* it is sendable and must not be held back by it. This one only
        // ever holds back operations that come after the unresolved one, because batches go out in order.
        var held: [String: String] = [:]
        // Batches are built only from the sendable prefixes, and every batch is filtered again before it
        // goes: a previous batch, or a split half of one, may have left an intake unresolved, and the
        // receiver never accepted that operation, so its later revisions cannot go now.
        for batch in Self.batches(sendable, capabilities: capabilities, encoder: encoder) {
            var candidates: [RelayEncodedOperation] = []
            for item in batch {
                if let blocker = held[item.intakeID] {
                    outcomes.append(.blocked(operationID: item.operationID, blockedBy: blocker))
                    continue
                }
                candidates.append(item)
            }
            guard !candidates.isEmpty else { continue }
            // The credential comes before anything is sent, and the snapshot is recorded only once a
            // piece carrying it has been answered — so a token that cannot be read leaves nothing on
            // record, and the next attempt encodes against the links current then.
            let credential: String
            do {
                credential = try await token()
            } catch {
                let failed = await result(
                    of: candidates, now: now, stopsTheRun: false, refused: nil,
                    failed: "the intake token could not be read")
                outcomes.append(contentsOf: failed.deliveries.map(\.outcome))
                for delivery in failed.deliveries where !delivery.outcome.isResolved {
                    held[delivery.intakeID] = delivery.outcome.operationID
                }
                continue
            }
            let sent = await transmit(candidates, credential: credential, now: now)
            outcomes.append(contentsOf: sent.deliveries.map(\.outcome))
            for delivery in sent.deliveries where !delivery.outcome.isResolved {
                held[delivery.intakeID] = delivery.outcome.operationID
            }
            if sent.stopsTheRun {
                stopped = true
                break
            }
        }
        guard !stopped else {
            // Whatever the run never reached is reported as unattempted rather than quietly dropped, so a
            // run that stopped on a rejected token or a rate limit says which operations it did not try.
            let reported = Set(outcomes.map(\.operationID))
            for item in sendable where !reported.contains(item.operationID) {
                outcomes.append(.notAttempted(
                    operationID: item.operationID,
                    reason: "the run stopped when the receiver asked this producer to stop"))
            }
            await settle(deferred, into: &outcomes)
            return outcomes
        }
        await settle(deferred, into: &outcomes)
        return outcomes
    }

    // MARK: - What one encoded operation came from

    /// Where an encoded operation came from, because only one of the two has a row to record anything in.
    private enum RelayOrigin {
        /// A queued outbox row, with the attempt count that indexes the backoff.
        case outbox(OutboxOperation)
        /// A link-only change with a queue of its own and no attempts to count.
        case projection(RelayLinkProjection)
    }

    /// One operation, encoded and ready to be packed into a batch.
    private struct RelayEncodedOperation {
        let origin: RelayOrigin
        let intakeID: String
        let value: IntakeContextValue
        /// The sequence-1 link snapshot this item is carrying, set only on an upsert's first attempt.
        ///
        /// Carried rather than written during encoding, and written by `record(_:)` once the piece carrying
        /// this item has been answered. Encoding decides only whether the item is sendable at all: an
        /// operation can be encoded and then never sent, because its intake was blocked behind an earlier
        /// one, because the capabilities read failed, or because a 413 split it off into a piece that a rate
        /// limit, a refused token or an unresolved intake kept from carrying it. The snapshot is a durable
        /// record of what went on the wire, so it belongs to the piece that actually put it there — recording
        /// it earlier would leave on record links no request carried, and go on missing every link that
        /// arrived while the item waited to be sent.
        let snapshotToRecord: [IntakeContextLink]?

        init(
            origin: RelayOrigin, intakeID: String, value: IntakeContextValue,
            snapshotToRecord: [IntakeContextLink]? = nil
        ) {
            self.origin = origin
            self.intakeID = intakeID
            self.value = value
            self.snapshotToRecord = snapshotToRecord
        }

        var operationID: String { value.operations.first?.operationID ?? "" }
    }

    /// Why an operation could not join this run.
    private enum RelayEncoding {
        /// Nothing to send: the receiver already holds something newer, or the intake is gone and the
        /// delete queued beside it is the operation that decides what the receiver holds.
        case superseded(detail: String?)
        /// A refusal the receiver would make anyway, caught here before a batch was built.
        case failed(reason: String)
        case encoded(RelayEncodedOperation)
    }

    // MARK: - Encoding

    /// The operations a delete queued in this intake's own queue retracts: everything before it.
    ///
    /// One intake's queue is walked in the store's order — oldest revision first, an upsert before a
    /// delete within a revision — so a delete stands above every operation ahead of it and nothing after
    /// it. Only the delete's own delivery identity is used to decide; the operations it retracts are
    /// recognised by position, which is what the receiver would see.
    private static func retractedByQueuedDelete(_ queued: [OutboxOperation]) -> Set<String> {
        guard let index = queued.firstIndex(where: { $0.kind == .delete }) else { return [] }
        return Set(queued[..<index].map(\.operationID))
    }

    /// Encodes one queued row as the operation it is.
    ///
    /// A row whose intake is gone is **superseded, not sent**: the delete queued in the same run is what
    /// decides what the receiver holds, and sending the upsert would put back exactly what it retracts.
    private func encode(_ operation: OutboxOperation) -> RelayEncoding {
        switch operation.kind {
        case .upsert: return encodeUpsert(operation)
        case .delete: return encodeDelete(operation)
        }
    }

    private func encodeUpsert(_ operation: OutboxOperation) -> RelayEncoding {
        let intake: Intake?
        let revisions: [IntakeRevision]
        do {
            intake = try store.activeIntakes().first { $0.id == operation.intakeID }
            revisions = try store.revisions(of: operation.intakeID)
        } catch {
            return .failed(reason: "the intake could not be read")
        }
        guard let intake else { return .superseded(detail: nil) }
        guard let revision = revisions.first(where: { $0.number == operation.revision }) else {
            return .failed(reason: "the journal no longer holds revision \(operation.revision)")
        }
        let product: ProductDefinition?
        do {
            product = try revision.productSnapshotID.flatMap { try store.product(snapshotID: $0) }
        } catch {
            return .failed(reason: "the product snapshot could not be read")
        }
        // The links are read back, not rebuilt. An upsert's `operation_id` is its delivery identity, so a
        // retry has to carry the same snapshot under it: links that arrived in between would move the
        // projection and client digests, and the receiver would read the retry as a conflict rather than
        // the duplicate it is.
        //
        // A snapshot nobody has recorded yet is read from the provider and **carried, not written**. Encoding
        // decides whether it is sendable at all — the encoder is the authority, and the store keeps the first
        // snapshot it is given for the life of the operation, so an invalid one written here would be frozen
        // permanently, with every later attempt reading the same bad links back. Recording waits for
        // `record(_:)`, which runs once the piece carrying the operation has been answered.
        let recorded: [IntakeContextLink]?
        do {
            recorded = try store.recordedLinks(operationID: operation.operationID)
        } catch {
            return .failed(reason: "the recorded link snapshot could not be read")
        }
        let snapshot = recorded ?? links(intake, revision)
        let value: IntakeContextValue
        do {
            value = try encoder.upsert(
                intake: intake, revision: revision, product: product, operation: operation,
                links: snapshot)
        } catch {
            return .failed(reason: "the revision does not encode as an intake-context upsert")
        }
        return .encoded(RelayEncodedOperation(
            origin: .outbox(operation), intakeID: operation.intakeID,
            value: value, snapshotToRecord: recorded == nil ? snapshot : nil))
    }

    private func encodeDelete(_ operation: OutboxOperation) -> RelayEncoding {
        let intake: Intake?
        let revisions: [IntakeRevision]
        do {
            intake = try store.deletedIntakes().first { $0.id == operation.intakeID }
            revisions = try store.revisions(of: operation.intakeID)
        } catch {
            return .failed(reason: "the tombstone could not be read")
        }
        guard let intake else { return .superseded(detail: nil) }
        guard let revision = revisions.first(where: { $0.number == operation.revision }) else {
            return .failed(reason: "the journal no longer holds revision \(operation.revision)")
        }
        // The deletion instant the row recorded, never the clock: it is hashed into the tombstone, so a
        // different reading would make this retry a conflict rather than a duplicate. A row queued before
        // the column existed carries none, and falls back to the revision's own instant rather than
        // stranding a deletion that is otherwise perfectly deliverable.
        let deletedAt: Date
        do {
            deletedAt = try store.deletionInstant(operationID: operation.operationID) ?? revision.createdAt
        } catch {
            return .failed(reason: "the deletion instant could not be read")
        }
        do {
            return .encoded(RelayEncodedOperation(
                origin: .outbox(operation),
                intakeID: operation.intakeID,
                value: try encoder.delete(
                    intake: intake, revision: revision, tombstone: tombstones(intake, revision, deletedAt),
                    operation: operation)))
        } catch {
            return .failed(reason: "the deletion does not encode as an intake-context tombstone")
        }
    }

    /// Encodes a link-only change as the contract's `link_projection`, which takes no outbox row.
    private func encode(_ projection: RelayLinkProjection) -> RelayEncoding {
        let intake: Intake?
        let revisions: [IntakeRevision]
        do {
            intake = try store.activeIntakes().first { $0.id == projection.intakeID }
            revisions = try store.revisions(of: projection.intakeID)
        } catch {
            return .failed(reason: "the intake could not be read")
        }
        guard let intake, let revision = revisions.first(where: { $0.number == projection.revision })
        else { return .superseded(detail: nil) }
        let product: ProductDefinition?
        do {
            product = try revision.productSnapshotID.flatMap { try store.product(snapshotID: $0) }
        } catch {
            return .failed(reason: "the product snapshot could not be read")
        }
        do {
            return .encoded(RelayEncodedOperation(
                origin: .projection(projection),
                intakeID: projection.intakeID,
                value: try encoder.linkProjection(
                    intake: intake, revision: revision, product: product, sequence: projection.sequence,
                    links: projection.links, operationID: projection.operationID)))
        } catch {
            return .failed(reason: "the link projection does not encode as an intake-context operation")
        }
    }

    // MARK: - Batches

    /// Packs the operations into batches the receiver's own limits allow, in the order they were read.
    ///
    /// `maxOperations` and `maxBodyBytes` are the receiver's numbers, so the limit is checked against the
    /// batch that would actually be sent rather than an estimate of it: the body is measured as canonical
    /// bytes, and an operation that would not fit opens the next batch.
    ///
    /// An operation too large on its own still goes in a batch of its own. Packing it differently cannot
    /// make it smaller, and dropping it would lose a revision silently; a receiver that refuses it answers
    /// 413, which is the split path below.
    private static func batches(
        _ items: [RelayEncodedOperation], capabilities: IntakeContextCapabilities, encoder: IntakeContextEncoder
    ) -> [[RelayEncodedOperation]] {
        // A receiver that states no usable operation limit is read as one operation per batch: the smallest
        // batch there is, and its own answer decides whether even that fits.
        let limit = max(capabilities.maxOperations, 1)
        let ceiling = max(capabilities.maxBodyBytes, 0)
        var batches: [[RelayEncodedOperation]] = []
        var current: [RelayEncodedOperation] = []
        for item in items {
            if current.isEmpty {
                current = [item]
                continue
            }
            let candidate = current + [item]
            if candidate.count > limit || bodyBytes(candidate, encoder: encoder) > ceiling {
                batches.append(current)
                current = [item]
                continue
            }
            current = candidate
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// The canonical bytes a batch would be sent as, or `Int.max` when it cannot be built at all.
    ///
    /// Unbuildable is read as "does not fit", because a batch that cannot be encoded cannot be sent either;
    /// `send` reports that as the refusal it is rather than hiding it behind a size limit.
    private static func bodyBytes(_ items: [RelayEncodedOperation], encoder: IntakeContextEncoder) -> Int {
        (try? encoder.batch(
            batchID: batchID(for: items), operations: items.map(\.value)
        ).canonicalBytes.count) ?? Int.max
    }

    /// The delivery identity of one batch, derived from the operations it carries.
    ///
    /// Derived rather than random so that a retry after a lost response sends the identical batch: no
    /// digest covers `batch_id`, so reusing one costs nothing, while a fresh id would make two
    /// byte-identical attempts look like two unrelated deliveries in the receiver's own log.
    private static func batchID(for items: [RelayEncodedOperation]) -> String {
        let seed = "intake-context-batch:" + items.map(\.operationID).joined(separator: ",")
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        // Version 5 and the RFC 4122 variant, so the derived text is a well-formed name-based UUID, which is
        // the form the schema requires of `batch_id`.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        var text = ""
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 { text += "-" }
            text += String(format: "%02x", byte)
        }
        return text
    }

    // MARK: - Sending

    /// One outcome, with the intake it belongs to, so a later operation for that intake can be held back.
    private struct RelayDelivery {
        let intakeID: String
        let outcome: RelayDeliveryOutcome
    }

    /// What one batch did, and whether the run has to stop.
    private struct RelayBatchResult {
        let deliveries: [RelayDelivery]
        /// Set when the receiver rejected the token: every later batch would be refused the same way, and a
        /// run that kept going would report one refusal per batch instead of the single cause.
        let stopsTheRun: Bool
    }

    /// Puts one piece on the wire and maps what came back, splitting it again if the receiver says the body
    /// was too large.
    ///
    /// **The link snapshot is recorded immediately before the request that carries it**, never after the
    /// answer and never for a prepared batch as a whole. Two things follow, and both matter:
    ///
    /// - A piece that is actually put on the wire has its snapshot on record *before* it goes, so a process
    ///   death between the send and anything else cannot leave a sent operation with no snapshot. That retry
    ///   would reuse the same `operation_id` with a different `client_payload_hash`, which the receiver reads
    ///   as a permanent conflict rather than the duplicate it should be.
    /// - A piece that is never put on the wire records nothing. A prepared batch is not one request: a 413
    ///   splits it, and the halves can fail apart. A rate limit or a refused token on the head stops the
    ///   split, and an intake the head left unresolved has its tail items filtered out of it, so those items
    ///   were never sent and must keep nothing on record — otherwise they would be sent carrying whatever
    ///   links happened to be current when the oversized batch was packed, missing every link that arrived
    ///   while they waited.
    ///
    /// **A record write that fails means this piece is not sent.** The alternative is putting a payload on the
    /// wire whose snapshot is not on record, which is exactly the conflict above; rescheduling keeps the
    /// operation pending and the next attempt encodes against the links current then.
    ///
    /// **A 413 releases what this request recorded, but only when the piece is split.** The receiver applied none
    /// of the refused body, so nothing was committed under those delivery identities and there is nothing to
    /// reproduce — each piece the split produces records its own, and an item whose piece never carries it is
    /// left with nothing. `releaseLinks(_:)` forgets only a record this run created, so a snapshot from an
    /// earlier attempt or from an overlapping run keeps it: those may already be at the receiver.
    ///
    /// **A sole operation refused with 413 keeps its snapshot**, because there is no split and the payload was
    /// sent and read. It is parked for a person, and a re-armed attempt has to repeat that same payload — the
    /// refusal is about this payload's size, and a different snapshot would be a different payload.
    ///
    /// Recursive rather than one split, because how large a single operation is on its own is not knowable
    /// here: an operation with a long link snapshot may need to travel alone while a bare facts-only one
    /// would have fitted. Parking whatever survives a single halving would refuse operations that were
    /// perfectly sendable, and the recursion stops on its own at one operation the receiver still refuses.
    private func transmit(
        _ items: [RelayEncodedOperation], credential: String, now: Date
    ) async -> RelayBatchResult {
        // The snapshot goes on record before the request, not after the answer.
        let prepared = prepare(items, now: now)
        let ready = prepared.ready
        guard !ready.isEmpty else {
            return RelayBatchResult(deliveries: prepared.deliveries, stopsTheRun: false)
        }
        let bytes: Data
        do {
            bytes = try encoder.batch(
                batchID: Self.batchID(for: ready), operations: ready.map(\.value)
            ).canonicalBytes
        } catch {
            // Nothing was sent, so what was recorded for this request is released: it describes bytes that
            // never went out, and keeping it would freeze links for an operation that has not been attempted.
            release(prepared)
            var deliveries = prepared.deliveries
            let refused = await result(
                of: ready, now: now, stopsTheRun: false,
                refused: "the batch could not be encoded for delivery")
            deliveries.append(contentsOf: refused.deliveries)
            return RelayBatchResult(deliveries: deliveries, stopsTheRun: false)
        }
        let response: IntakeContextTransportResponse
        do {
            response = try await transport.send(batch: bytes, token: credential)
        } catch {
            // Nothing arrived, so there is no status to read, and the bytes may still have reached the
            // receiver. Transient by definition: the same bytes are worth sending again — which is exactly
            // what the snapshot already on record has to reproduce.
            let failed = await result(
                of: ready, now: now, stopsTheRun: false, refused: nil, failed: "the batch could not be sent")
            return RelayBatchResult(
                deliveries: prepared.deliveries + failed.deliveries, stopsTheRun: failed.stopsTheRun)
        }
        switch response.statusCode {
        case 200...299:
            let delivered = await apply(response, to: ready, now: now)
            return RelayBatchResult(
                deliveries: prepared.deliveries + delivered, stopsTheRun: false)
        case 401:
            // The token is refused. Retrying cannot mint a new one, and every later batch would be refused
            // the same way, so the run stops and these operations are parked until someone re-arms them.
            let refused = await result(
                of: ready, now: now, stopsTheRun: true,
                refused: "the receiver rejected the intake token, so nothing was delivered")
            return RelayBatchResult(
                deliveries: prepared.deliveries + refused.deliveries, stopsTheRun: true)
        case 429:
            // **A rate limit stops the run.** The receiver is telling this producer to send less, and the
            // other batches of this run are more of exactly what it just asked for of it — including the
            // smaller ones a split would produce, since the limit is on traffic and not on size. Rescheduling
            // this batch and carrying straight on to the next would spend the whole run walking into the same
            // wall, so the operations after it are reported as unattempted and the next run starts fresh.
            //
            // A stated wait is honoured as given. Without one, the per-operation backoff ladder decides —
            // the same one every other transient failure uses, indexed by that operation's own attempt
            // count. Hard-coding the first step here would hold a repeatedly throttled producer at one
            // minute forever, which is the opposite of what a receiver asking for less traffic wants.
            let wait = response.retryAfterSeconds
            let reason = wait.map { "the receiver asked this producer to wait \($0) seconds" }
                ?? "the receiver rate limited this producer without stating a wait"
            let throttled = await result(
                of: ready, now: now, stopsTheRun: true, refused: nil,
                failed: reason,
                failedAt: wait.map { now.addingTimeInterval(TimeInterval($0)) })
            return RelayBatchResult(
                deliveries: prepared.deliveries + throttled.deliveries, stopsTheRun: true)
        case 413:
            // **Split until there is nothing left to split.** A 413 says the body was too large, and how
            // large a given operation is on its own is not something this module can know in advance: an
            // operation with a long link snapshot may need to travel alone while a bare facts-only one would
            // have fitted. Halving once and parking whatever still does not fit would refuse operations that
            // were perfectly sendable, so the split recurses and only a **single** operation still coming back
            // 413 is the payload itself being too large. That case is permanent: no smaller request exists.
            //
            if ready.count > 1 {
                // **What this request recorded is released, because nothing in it was applied.** Each piece
                // the split produces records its own, and an item whose piece never carries it is left with
                // nothing on record.
                release(prepared)
                let half = ready.count / 2
                let head = await transmit(Array(ready[..<half]), credential: credential, now: now)
                // **A refused token or a rate limit on the head stops the split there.** The rest of the run
                // carries the same token to the same receiver, so sending the tail would be one more request
                // refused for the same reason, and its operations would be recorded against a credential or a
                // rate limit already known to be in force. They are reported as unattempted, which is what
                // happened.
                // **Preparation outcomes survive a head that stops the run.** This piece recorded snapshots and may have
                // held items back before it ever reached the wire — a record write that failed, or an item
                // behind an intake this piece could not send. Those outcomes are facts about operations that
                // were dealt with, and dropping them would report a held-back operation as `notAttempted`
                // above, which is a different thing: nothing was attempted *because preparation resolved it*.
                guard !head.stopsTheRun else {
                    return RelayBatchResult(
                        deliveries: prepared.deliveries + head.deliveries, stopsTheRun: true)
                }
                // **The tail goes through the same blocker check the batches after this one would.** The head
                // has been sent and answered, so its result is a fact about the receiver: an intake left
                // unresolved by it — retryable, permanent, an unrecorded acknowledgement or no result at all —
                // has not had its earlier operation delivered, and the receiver applies in array order.
                // Sending that intake's later operations now would offer the receiver a newer revision whose
                // predecessor it never accepted, which it refuses as stale. Filtering here rather than only
                // between batches is what makes the split transparent: it must not weaken the ordering rule
                // the batches themselves obey.
                let (blocked, sendable) = Self.partitioning(
                    Array(ready[half...]), behind: head.deliveries)
                var deliveries = prepared.deliveries + head.deliveries
                deliveries.append(contentsOf: blocked)
                if !sendable.isEmpty {
                    let sent = await transmit(sendable, credential: credential, now: now)
                    deliveries.append(contentsOf: sent.deliveries)
                    return RelayBatchResult(deliveries: deliveries, stopsTheRun: sent.stopsTheRun)
                }
                return RelayBatchResult(deliveries: deliveries, stopsTheRun: false)
            }
            // A single operation still refused for size: the payload itself is what the receiver will not
            // take, so its snapshot stays on record — it was sent, and a re-armed attempt must repeat it.
            let tooLarge = await result(
                of: ready, now: now, stopsTheRun: false,
                refused: "the receiver refused this operation's payload as too large")
            return RelayBatchResult(
                deliveries: prepared.deliveries + tooLarge.deliveries, stopsTheRun: false)
        case 400, 403:
            // Permanent for these operations: the payload or the producer binding is refused, and the same
            // bytes are refused again on every attempt.
            let refused = await result(
                of: ready, now: now, stopsTheRun: false,
                refused: Self.errorText(in: response.body) ?? "the receiver refused the batch")
            return RelayBatchResult(
                deliveries: prepared.deliveries + refused.deliveries, stopsTheRun: false)
        default:
            // 5xx and anything else the receiver did not name: transient, because a later run may well find
            // it back. The status is in the reason so the queue is not silent about why it waited.
            let failed = await result(
                of: ready, now: now, stopsTheRun: false, refused: nil,
                failed: "the receiver answered \(response.statusCode)")
            return RelayBatchResult(
                deliveries: prepared.deliveries + failed.deliveries, stopsTheRun: false)
        }
    }

    /// Settles the projections that were waiting on a newer upsert, once this run knows what became of it.
    ///
    /// **Only an accepted or duplicate upsert supersedes the projection.** That is the fact the decision turns
    /// on: a newer revision's upsert carries a complete link snapshot for its own revision and never a delta,
    /// so the older projection has nothing left to say *once the receiver holds that revision*. An upsert that
    /// was never sent, or that came back as a conflict, a permanent or retryable failure, or an answer that
    /// could not be matched, leaves the receiver where it was — so the projection stays queued, and the run
    /// reports it as blocked by that upsert rather than discarding something still deliverable.
    ///
    /// A resolved outcome is what counts as accepted: `delivered` is `accepted` or `duplicate`, and both mean
    /// the receiver holds the operation. Nothing else releases the projection.
    ///
    /// **A superseded upsert settles it too**, for a different reason. That upsert was never sent — the intake
    /// is gone, so it left the queue without the receiver holding anything — and there is nothing queued under
    /// its id for the projection to wait behind. Reporting `blocked` by an id that no longer names a queued
    /// operation would leave the projection waiting on something that will never come, so it is resolved.
    private func settle(
        _ deferred: [(projection: RelayLinkProjection, supersededBy: String, detail: String)],
        into outcomes: inout [RelayDeliveryOutcome]
    ) async {
        var accepted: Set<String> = []
        var withdrawn: Set<String> = []
        for outcome in outcomes {
            switch outcome {
            case .delivered(let id, _, _):
                accepted.insert(id)
            case .superseded(let id, _):
                withdrawn.insert(id)
            default:
                break
            }
        }
        for entry in deferred {
            guard accepted.contains(entry.supersededBy) || withdrawn.contains(entry.supersededBy) else {
                outcomes.append(.blocked(
                    operationID: entry.projection.operationID, blockedBy: entry.supersededBy))
                continue
            }
            await projections.resolve(entry.projection, with: .superseded)
            outcomes.append(.superseded(
                operationID: entry.projection.operationID, detail: entry.detail))
        }
    }

    /// What one piece's send is made of: the items that go on the wire, and what became of the ones that do not.
    private struct RelayPreparation {
        /// The items whose snapshot is on record and which are about to be put on the wire, in batch order.
        let ready: [RelayEncodedOperation]
        /// The outcomes of the items held back: a record write that failed, or an item behind an intake the
        /// piece itself left unable to send.
        let deliveries: [RelayDelivery]
        /// The operations whose record this preparation created, so `release(_:)` can forget exactly
        /// those and nothing that was already on record.
        let written: [String]
    }

    /// Writes the sequence-1 snapshot of each item and returns what is ready to go on the wire.
    ///
    /// A delete, a projection and an operation whose snapshot is already on record have nothing to write. The
    /// store keeps the first snapshot it is given for the life of the operation, and this is the write that
    /// makes the next attempt of these operations a duplicate rather than a conflict.
    ///
    /// **A write that fails means the item is not sent.** Its outcome is a retry, and a later item of the
    /// same intake is held back behind it: the receiver applies a batch in array order, so a later revision
    /// cannot go out past one whose payload was never sent.
    ///
    /// A store that answers with a different snapshot than the one offered is another run's record winning,
    /// and this item is re-encoded from what is on record so it sends the same payload that record describes.
    private func prepare(
        _ items: [RelayEncodedOperation], now: Date
    ) -> RelayPreparation {
        var ready: [RelayEncodedOperation] = []
        var deliveries: [RelayDelivery] = []
        var written: [String] = []
        var blockedBy: [String: String] = [:]
        for item in items {
            if let blocker = blockedBy[item.intakeID] {
                deliveries.append(RelayDelivery(
                    intakeID: item.intakeID,
                    outcome: .blocked(operationID: item.operationID, blockedBy: blocker)))
                continue
            }
            guard let snapshot = item.snapshotToRecord, case .outbox(let operation) = item.origin else {
                ready.append(item)
                continue
            }
            let recorded: (snapshot: [IntakeContextLink], isNew: Bool)
            do {
                recorded = try store.recordLinks(snapshot, operationID: operation.operationID)
            } catch {
                deliveries.append(RelayDelivery(
                    intakeID: item.intakeID,
                    outcome: retry(
                        operation,
                        reason: "the link snapshot for this operation could not be recorded, so it was not "
                            + "sent and a retry must re-encode it",
                        now: now)))
                blockedBy[item.intakeID] = item.operationID
                continue
            }
            // **Only a record this call created is this piece's to discard.** `isNew` is what says so: a
            // snapshot already on record — from an earlier attempt of this operation, or written by an
            // overlapping run — comes back equal to the one offered and is not ours to release.
            if recorded.isNew { written.append(operation.operationID) }
            if recorded.snapshot == snapshot {
                ready.append(item)
                continue
            }
            // Another run recorded a different snapshot first and won, so what goes out is what is on record.
            switch encodeUpsert(operation) {
            case .encoded(let rebuilt):
                ready.append(rebuilt)
            case .failed(let reason):
                deliveries.append(RelayDelivery(
                    intakeID: item.intakeID, outcome: retry(operation, reason: reason, now: now)))
                blockedBy[item.intakeID] = item.operationID
            case .superseded(let detail):
                deliveries.append(RelayDelivery(
                    intakeID: item.intakeID,
                    outcome: acknowledge(
                        operation, now: now,
                        outcome: .superseded(operationID: operation.operationID, detail: detail))))
            }
        }
        return RelayPreparation(ready: ready, deliveries: deliveries, written: written)
    }

    /// Forgets the snapshots this piece introduced, after the receiver refused its body for size.
    ///
    /// `written` holds exactly the records this piece created, so nothing already on record is touched: a
    /// snapshot from an earlier attempt belongs to a request whose answer may have been lost, and the receiver
    /// may already hold that payload under the operation id.
    ///
    /// A release that fails is not fatal. The operation keeps a snapshot it did not strictly need, which costs a
    /// later attempt the links that arrived in between — a smaller wrongness than refusing to release what can
    /// be released, and the next attempt still sends what is on record rather than nothing.
    private func release(_ prepared: RelayPreparation) {
        for operationID in prepared.written {
            try? store.releaseLinks(operationID: operationID)
        }
    }

    /// Splits the tail of a split batch into the operations to hold back and the ones still to send.
    ///
    /// An intake the head left unresolved blocks its later operations here, exactly as it would between two
    /// batches. Every tail item is later than every head item of the same intake — the split is in queue
    /// order — so an intake lookup is enough and no position comparison is needed.
    private static func partitioning(
        _ items: [RelayEncodedOperation], behind deliveries: [RelayDelivery]
    ) -> (blocked: [RelayDelivery], sendable: [RelayEncodedOperation]) {
        var blocking: Set<String> = []
        for delivery in deliveries where !delivery.outcome.isResolved {
            blocking.insert(delivery.intakeID)
        }
        var blocked: [RelayDelivery] = []
        var sendable: [RelayEncodedOperation] = []
        for item in items {
            if blocking.contains(item.intakeID) {
                blocked.append(RelayDelivery(
                    intakeID: item.intakeID,
                    outcome: .blocked(
                        operationID: item.operationID,
                        blockedBy: firstUnresolved(of: item.intakeID, in: deliveries))))
                continue
            }
            sendable.append(item)
        }
        return (blocked, sendable)
    }

    /// The operation that left an intake unresolved, which is what a held-back operation names as its blocker.
    private static func firstUnresolved(of intakeID: String, in deliveries: [RelayDelivery]) -> String {
        deliveries.first { $0.intakeID == intakeID && !$0.outcome.isResolved }?.outcome.operationID
            ?? intakeID
    }

    /// One outcome per operation of a batch, where the whole batch has the same answer.
    ///
    /// A status applies to the batch as a whole, so every operation in it gets the same outcome — but a
    /// 429's wait and a park's recording are per operation, which is why this walks the list rather than
    /// mapping one result over it.
    ///
    /// Exactly one of `refused` and `failed` is given. `refused` parks the operations until someone
    /// re-arms them; `failed` schedules another attempt, `failedAt` saying when, which defaults to the
    /// backoff for each operation's own attempt count.
    private func result(
        of items: [RelayEncodedOperation], now: Date, stopsTheRun: Bool,
        refused: String?, failed: String? = nil, failedAt: Date? = nil
    ) async -> RelayBatchResult {
        var deliveries: [RelayDelivery] = []
        for item in items {
            let outcome: RelayDeliveryOutcome
            if let refused {
                outcome = await park(item, reason: refused, now: now)
            } else if let failed {
                outcome = await retry(item, reason: failed, now: now, due: failedAt)
            } else {
                outcome = .notAttempted(operationID: item.operationID, reason: "the batch was not attempted")
            }
            deliveries.append(RelayDelivery(intakeID: item.intakeID, outcome: outcome))
        }
        return RelayBatchResult(deliveries: deliveries, stopsTheRun: stopsTheRun)
    }

    /// Maps the receiver's per-operation results onto outcomes.
    ///
    /// **An operation the reply does not mention is unresolved.** A 200 that omits a result leaves the
    /// journal unable to say whether the receiver holds the operation, and reporting that as delivered would
    /// release the revisions queued behind it; a body that cannot be read at all is the same situation.
    private func apply(
        _ response: IntakeContextTransportResponse, to items: [RelayEncodedOperation], now: Date
    ) async -> [RelayDelivery] {
        let payload = try? IntakeContextJSONReader.read(response.body)
        let entries = payload?.array("results") ?? []
        var deliveries: [RelayDelivery] = []
        for item in items {
            guard let answer = entries.compactMap(RelayOperationResponse.init(entry:)).first(where: {
                $0.operationID == item.operationID
            }) else {
                deliveries.append(RelayDelivery(
                    intakeID: item.intakeID,
                    outcome: .notAcknowledged(
                        operationID: item.operationID,
                        detail: "the receiver's answer carried no result for this operation")))
                continue
            }
            deliveries.append(RelayDelivery(
                intakeID: item.intakeID, outcome: await resolve(item, answer, now: now)))
        }
        return deliveries
    }

    /// One receiver result, mapped onto what it means for the journal.
    private func resolve(
        _ item: RelayEncodedOperation, _ response: RelayOperationResponse, now: Date
    ) async -> RelayDeliveryOutcome {
        switch response.result {
        case .accepted, .duplicate:
            let outcome = RelayDeliveryOutcome.delivered(
                operationID: item.operationID, acceptedRevision: response.acceptedRevision,
                serverCursor: response.serverCursor)
            if case .outbox(let operation) = item.origin {
                return acknowledge(operation, now: now, outcome: outcome)
            }
            if case .projection(let projection) = item.origin {
                await projections.resolve(
                    projection,
                    with: .delivered(
                        acceptedRevision: response.acceptedRevision, serverCursor: response.serverCursor))
            }
            return outcome
        case .staleRevision:
            let outcome = RelayDeliveryOutcome.superseded(
                operationID: item.operationID, detail: response.detail)
            if case .outbox(let operation) = item.origin {
                return acknowledge(operation, now: now, outcome: outcome)
            }
            if case .projection(let projection) = item.origin {
                await projections.resolve(projection, with: .superseded)
            }
            return outcome
        case .domainConflict, .projectionConflict, .permanentFailure:
            return await park(
                item,
                reason: "the receiver reported a \(response.result.reasonText): "
                    + (response.detail ?? "no detail"),
                now: now)
        case .retryableFailure:
            return await retry(
                item, reason: "the receiver reported a retryable failure: "
                    + (response.detail ?? "no detail"),
                now: now)
        }
    }

    /// The `error` member of a refused batch, when the receiver sent one.
    ///
    /// Read defensively: the body is whatever arrived, and a reason a person reads has to survive a reply
    /// that is not the document this module expects.
    private static func errorText(in body: Data) -> String? {
        guard let payload = try? IntakeContextJSONReader.read(body) else { return nil }
        return payload.string("error")
    }

    // MARK: - Recording

    /// Acknowledges a delivered row, so `pendingOutbox()` stops offering it.
    ///
    /// **A failed acknowledgement is unresolved, not delivered.** The receiver holds the operation but the
    /// journal does not know it, so the row is still queued. Reporting that as resolved would let this run
    /// send a later revision for the same intake while the earlier one is still pending — and the receiver
    /// would then answer the newer one as stale on the attempt after that.
    private func acknowledge(
        _ operation: OutboxOperation, now: Date, outcome: RelayDeliveryOutcome
    ) -> RelayDeliveryOutcome {
        do {
            try store.acknowledge(operationID: operation.operationID, at: now)
            return outcome
        } catch {
            return .notAcknowledged(
                operationID: operation.operationID,
                detail: "the operation was delivered but the journal could not record it")
        }
    }

    /// Parks one operation until someone re-arms it, with the receiver's own reason.
    private func park(_ operation: OutboxOperation, reason: String, now: Date) -> RelayDeliveryOutcome {
        do {
            try store.recordFailure(
                operationID: operation.operationID, retryAt: nil, needsAttention: true, reason: reason)
            return .needsAttention(operationID: operation.operationID, reason: reason)
        } catch {
            // The queue could not record the failure, so the operation stays due and the next run tries it
            // again. That is the retry storm this case exists to avoid, but only until the journal is
            // writable again, and losing the operation would be worse.
            return .retryScheduled(
                operationID: operation.operationID,
                nextAttemptAt: now.addingTimeInterval(
                    TimeInterval(Self.backoffSeconds(afterAttempt: 1))),
                reason: "\(reason); the failure could not be recorded")
        }
    }

    /// Parks an encoded operation, or hands the refusal to the queue that offered a projection.
    ///
    /// A projection has no row to defer or suspend, so the queue is told the reason and owns what happens
    /// next; the outcome still says the operation needs a person, because that is what the receiver said.
    private func park(_ item: RelayEncodedOperation, reason: String, now: Date) async -> RelayDeliveryOutcome {
        switch item.origin {
        case .outbox(let operation):
            return park(operation, reason: reason, now: now)
        case .projection(let projection):
            await projections.resolve(projection, with: .needsAttention(reason))
            return .needsAttention(operationID: item.operationID, reason: reason)
        }
    }

    /// Schedules the next attempt and leaves the operation pending.
    ///
    /// `due` is the wait the receiver asked for, and it wins over the backoff when it is there: a 429 that
    /// answered with `Retry-After` has told this producer exactly how long to stop, and substituting a
    /// guessed interval for a stated one would send sooner than the receiver permits.
    private func retry(
        _ operation: OutboxOperation, reason: String, now: Date, due: Date? = nil
    ) -> RelayDeliveryOutcome {
        let attempt = operation.attempts + 1
        let next = due ?? now.addingTimeInterval(TimeInterval(Self.backoffSeconds(afterAttempt: attempt)))
        let outcome = RelayDeliveryOutcome.retryScheduled(
            operationID: operation.operationID, nextAttemptAt: next, reason: reason)
        do {
            try store.recordFailure(
                operationID: operation.operationID, retryAt: next, needsAttention: false, reason: nil)
            return outcome
        } catch {
            // The schedule could not be recorded, so nothing was deferred: the operation stays due and the
            // next run tries again rather than losing it. The attempt count did not grow either, so the
            // backoff restarts — the queue is not writable, and the next run is what has to notice.
            return .retryScheduled(
                operationID: operation.operationID, nextAttemptAt: next,
                reason: "\(reason); the retry could not be recorded")
        }
    }

    /// Schedules the next attempt of an encoded operation.
    ///
    /// A projection has no attempts to count and no row to defer, so its wait is the first backoff step, or
    /// the receiver's own when it stated one, and nothing is written: its queue is not told about a retry,
    /// because there is nothing for it to record and it will offer the projection again on the next run
    /// regardless.
    private func retry(
        _ item: RelayEncodedOperation, reason: String, now: Date, due: Date? = nil
    ) async -> RelayDeliveryOutcome {
        switch item.origin {
        case .outbox(let operation):
            return retry(operation, reason: reason, now: now, due: due)
        case .projection(let projection):
            let next = due ?? now.addingTimeInterval(TimeInterval(Self.backoffSeconds(afterAttempt: 1)))
            // The queue is told, because otherwise it offers the projection again on the next run whatever
            // the receiver said — and a run triggered for unrelated work would retry it immediately,
            // against a receiver that had just asked this producer to stop. Reporting the date without
            // recording it would be the same as not reporting it.
            await projections.resolve(projection, with: .retryAfter(next, reason: reason))
            return .retryScheduled(operationID: item.operationID, nextAttemptAt: next, reason: reason)
        }
    }
}