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

/// Supplies the tombstone a queued delete is encoded with.
///
/// `deleted_at` is hashed into both the domain and the client digest, so the same delete rebuilt on a
/// later attempt has to carry the same instant or the receiver reports a conflict instead of the
/// duplicate it actually is. It therefore cannot be a fresh reading of the clock.
///
/// **The journal records no deletion instant.** `delete(intakeID:now:)` marks the lifecycle and queues
/// the row, and nothing persists the instant it was given, so the default anchors the tombstone to the
/// `createdAt` of the revision the delete retracts: durable, immutable, and identical on every rebuild.
/// This is also where a store that does persist the instant plugs in — the worker never reads a clock
/// itself, so the substitution is one closure.
public typealias RelayTombstoneProvider =
    @Sendable (_ intake: Intake, _ retractedRevision: IntakeRevision) -> IntakeContextTombstone

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

/// The journal a relay delivery reads: the queue and its suspensions, plus the tombstones a delete is
/// encoded from.
///
/// `JournalTombstoneSource` is named here rather than a new method of its own because the SwiftData store
/// already keeps tombstones for the exporter; asking for them under a second name would be two ways of
/// reading one thing. A store that cannot list tombstones cannot back this worker, which is honest: without
/// a tombstone there is no durable instant to encode a delete with.
public protocol RelayDeliveryStore: JournalDeliverySuspension, JournalTombstoneSource {}

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
    private let tombstones: RelayTombstoneProvider
    /// The intake token, passed per call so rotating it is the caller's decision.
    private let token: String

    public init(
        store: any RelayDeliveryStore,
        transport: any IntakeContextTransport,
        encoder: IntakeContextEncoder,
        token: String,
        projections: any RelayLinkProjectionQueue = RelayLinkProjectionQueueNone(),
        links: @escaping RelayLinkProvider = { _, _ in [] },
        tombstones: @escaping RelayTombstoneProvider = { intake, revision in
            IntakeContextTombstone(intakeID: intake.id, deletedAt: revision.createdAt)
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
        // The intake each unresolved operation is holding up. Revisions are sent oldest first, so the
        // first operation seen for an intake is the one everything later depends on.
        var blocking: [String: String] = [:]
        var due: [OutboxOperation] = []
        for operation in operations {
            guard operation.destination == .relay else { continue }
            if let blocker = blocking[operation.intakeID] {
                outcomes.append(.blocked(operationID: operation.operationID, blockedBy: blocker))
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
                blocking[operation.intakeID] = operation.operationID
                continue
            }
            if let attemptAt = operation.nextAttemptAt, attemptAt > now {
                outcomes.append(.notDue(operationID: operation.operationID, nextAttemptAt: attemptAt))
                blocking[operation.intakeID] = operation.operationID
                continue
            }
            due.append(operation)
        }
        var pending: [RelayEncodedOperation] = []
        for operation in due {
            switch encode(operation) {
            case .superseded(let detail):
                outcomes.append(acknowledge(
                    operation, now: now, outcome: .superseded(
                        operationID: operation.operationID, detail: detail)))
            case .failed(let reason):
                outcomes.append(park(operation, reason: reason, now: now))
                blocking[operation.intakeID] = operation.operationID
            case .encoded(let item):
                pending.append(item)
            }
        }
        for projection in (try? await projections.pendingLinkProjections()) ?? [] {
            if let blocker = blocking[projection.intakeID] {
                outcomes.append(.blocked(operationID: projection.operationID, blockedBy: blocker))
                continue
            }
            switch encode(projection) {
            case .superseded:
                await projections.resolve(projection, with: .superseded)
            case .failed:
                // A projection that cannot be encoded is the queue's problem: it offered a payload this
                // module refuses, and parking it here would be recording a failure with nowhere to keep it.
                await projections.resolve(
                    projection,
                    with: .needsAttention("the link projection could not be encoded for delivery"))
            case .encoded(let item):
                pending.append(item)
            }
        }
        guard !pending.isEmpty else { return outcomes }
        let capabilities: IntakeContextCapabilities
        do {
            capabilities = try await transport.capabilities()
        } catch {
            // The batch limits are the receiver's own numbers. Guessing them would produce the very 413
            // this run exists to avoid, so nothing is sent and every operation is rescheduled instead.
            for item in pending {
                outcomes.append(retry(item, reason: "the receiver's capabilities could not be read", now: now))
            }
            return outcomes
        }
        guard capabilities.supports(schemaVersion: IntakeContextEncoder.schemaVersion) else {
            // A receiver that does not know this schema version refuses the batch while parsing it, which
            // would look like a permanent failure of every operation rather than of the version.
            for item in pending {
                outcomes.append(await park(
                    item,
                    reason: "the receiver does not accept \(IntakeContextEncoder.schema) \(IntakeContextEncoder.schemaVersion)",
                    now: now))
            }
            return outcomes
        }
        var stopped = false
        for batch in Self.batches(pending, capabilities: capabilities, encoder: encoder) {
            // An earlier batch may have left an operation of one of these intakes unresolved, and the
            // receiver applies in array order: sending the later revision now would have it refused as
            // stale. Those operations are held back and reported, exactly as an earlier suspended operation
            // holds back the revisions behind it.
            var sendable: [RelayEncodedOperation] = []
            for item in batch {
                if let blocker = blocking[item.intakeID] {
                    outcomes.append(.blocked(operationID: item.operationID, blockedBy: blocker))
                    continue
                }
                sendable.append(item)
            }
            guard !sendable.isEmpty else { continue }
            let sent = await send(sendable, now: now, canSplit: true)
            outcomes.append(contentsOf: sent.deliveries.map(\.outcome))
            for delivery in sent.deliveries where !delivery.outcome.isResolved {
                blocking[delivery.intakeID] = delivery.outcome.operationID
            }
            if sent.stopsTheRun {
                stopped = true
                break
            }
        }
        guard !stopped else {
            // Whatever the run never reached is reported as unattempted rather than quietly dropped, so a
            // run that stopped on a rejected token says which operations it did not try.
            let reported = Set(outcomes.map(\.operationID))
            for item in pending where !reported.contains(item.operationID) {
                outcomes.append(.notAttempted(
                    operationID: item.operationID,
                    reason: "the run stopped when the receiver rejected the intake token"))
            }
            return outcomes
        }
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
        do {
            return .encoded(RelayEncodedOperation(
                origin: .outbox(operation),
                intakeID: operation.intakeID,
                value: try encoder.upsert(
                    intake: intake, revision: revision, product: product, operation: operation,
                    links: links(intake, revision))))
        } catch {
            return .failed(reason: "the revision does not encode as an intake-context upsert")
        }
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
        do {
            return .encoded(RelayEncodedOperation(
                origin: .outbox(operation),
                intakeID: operation.intakeID,
                value: try encoder.delete(
                    intake: intake, revision: revision, tombstone: tombstones(intake, revision),
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

    /// Sends one batch and maps what came back.
    ///
    /// `canSplit` is false on the retry after a 413, so the split happens once: an operation too large by
    /// itself is not made smaller by halving a list of one, and a second split would be looping over a
    /// payload the receiver has already refused twice.
    private func send(_ items: [RelayEncodedOperation], now: Date, canSplit: Bool) async -> RelayBatchResult {
        let bytes: Data
        do {
            bytes = try encoder.batch(
                batchID: Self.batchID(for: items), operations: items.map(\.value)
            ).canonicalBytes
        } catch {
            return await result(
                of: items, now: now, stopsTheRun: false, refused: "the batch could not be encoded for delivery")
        }
        let response: IntakeContextTransportResponse
        do {
            response = try await transport.send(batch: bytes, token: token)
        } catch {
            // Nothing arrived, so there is no status to read. Transient by definition: the same bytes are
            // worth sending again.
            return await result(
                of: items, now: now, stopsTheRun: false, refused: nil,
                failed: "the batch could not be sent")
        }
        switch response.statusCode {
        case 200...299:
            return RelayBatchResult(
                deliveries: await apply(response, to: items, now: now), stopsTheRun: false)
        case 401:
            // The token is refused. Retrying cannot mint a new one, and every later batch would be refused
            // the same way, so the run stops and these operations are parked until someone re-arms them.
            return await result(
                of: items, now: now, stopsTheRun: true,
                refused: "the receiver rejected the intake token, so nothing was delivered")
        case 429:
            // The receiver stated the wait, so it is used rather than the backoff: a rate limit answered
            // with its own interval is the receiver telling this producer exactly how long to stop.
            let wait = response.retryAfterSeconds ?? Self.backoffSeconds(afterAttempt: 1)
            return await result(
                of: items, now: now, stopsTheRun: false, refused: nil,
                failed: "the receiver asked this producer to wait \(wait) seconds",
                failedAt: now.addingTimeInterval(TimeInterval(wait)))
        case 413:
            if canSplit, items.count > 1 {
                let half = items.count / 2
                let head = await send(Array(items[..<half]), now: now, canSplit: false)
                let tail = await send(Array(items[half...]), now: now, canSplit: false)
                return RelayBatchResult(
                    deliveries: head.deliveries + tail.deliveries,
                    stopsTheRun: head.stopsTheRun || tail.stopsTheRun)
            }
            // One operation, or one split already spent: the payload itself is what the receiver refuses,
            // and no further halving makes it smaller.
            return await result(
                of: items, now: now, stopsTheRun: false,
                refused: "the receiver refused this operation's payload as too large")
        case 400, 403:
            // Permanent for these operations: the payload or the producer binding is refused, and the same
            // bytes are refused again on every attempt.
            return await result(
                of: items, now: now, stopsTheRun: false,
                refused: Self.errorText(in: response.body) ?? "the receiver refused the batch")
        default:
            // 5xx and anything else the receiver did not name: transient, because a later run may well find
            // it back. The status is in the reason so the queue is not silent about why it waited.
            return await result(
                of: items, now: now, stopsTheRun: false, refused: nil,
                failed: "the receiver answered \(response.statusCode)")
        }
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
                outcome = retry(item, reason: failed, now: now, due: failedAt)
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
            return retry(
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
    ) -> RelayDeliveryOutcome {
        switch item.origin {
        case .outbox(let operation):
            return retry(operation, reason: reason, now: now, due: due)
        case .projection:
            return .retryScheduled(
                operationID: item.operationID,
                nextAttemptAt: due
                    ?? now.addingTimeInterval(TimeInterval(Self.backoffSeconds(afterAttempt: 1))),
                reason: reason)
        }
    }
}