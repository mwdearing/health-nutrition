import Foundation
import NutritionDomain

/// Supplies the nutrient totals one revision contributes, keyed by intake id and revision number.
///
/// The worker does not compute totals: how much protein an entry carries is the journal's business,
/// and the planner only maps whatever it is handed. Injected, so the worker can be tested without a
/// store and so a future totals source does not change the delivery rules.
///
/// **Throwing is part of the contract.** A source that cannot read the revision must throw rather than
/// answer with nothing: the worker treats empty totals as "this revision states no nutrient", deletes
/// everything the earlier revisions wrote as stale, saves an empty plan and acknowledges the
/// operation. A failed read must never become a successful empty revision, so the failure has to reach
/// the worker, which then leaves the operation pending.
public typealias NutrientTotalsProvider = @Sendable (_ intakeID: String, _ revision: Int) async throws -> [String: NutrientValue]

/// The nutrient totals one journal revision contributes, read from what the revision itself recorded.
///
/// This is the default answer `AppServices` wires in, and it states **very little on purpose**:
///
/// - **Snapshot nutrients are omitted.** `ProductDefinition.nutrients` is stated on `labelBasis`
///   (typically per 100 g), not for the amount the component records. A 40 g component of a product
///   whose label states 13 g of protein per 100 g carries 5.2 g, and writing 13 g would put a wrong
///   number into Health. Scaling needs to know the basis exactly — a serving, a yield and a count all
///   scale differently — so until that arithmetic exists this provider contributes no snapshot nutrient
///   at all rather than an unscaled one. The planner then plans no sample for it, which is the honest
///   outcome. See `docs/healthkit-writer.md`.
/// - **Water comes from the components, and only for a water-category intake.** Volume is dietary
///   water when the entry is a drink; 250 mL of milk, juice or oil is not. A component measured in
///   another unit contributes nothing rather than a guess, because mass to volume needs a density the
///   journal does not record.
/// - A revision that cannot be read **throws**, so the delivery is retried rather than acknowledged as
///   an empty revision.
public struct JournalSnapshotTotals: Sendable {
    /// The intake category whose volume components count as dietary water.
    static let waterCategory = "water"

    private let store: any JournalStore

    public init(store: any JournalStore) {
        self.store = store
    }

    public func totals(intakeID: String, revision: Int) async throws -> [String: NutrientValue] {
        try totalsNow(intakeID: intakeID, revision: revision)
    }

    private func totalsNow(intakeID: String, revision: Int) throws -> [String: NutrientValue] {
        guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }) else {
            throw JournalError.unknownIntake(intakeID)
        }
        guard let entry = try store.revisions(of: intakeID).first(where: { $0.number == revision }) else {
            throw JournalError.unknownIntake("\(intakeID)@\(revision)")
        }
        var totals: [String: NutrientValue] = [:]
        // No snapshot nutrient is carried here on purpose: see the type's documentation. The snapshot
        // is not read at all rather than read and discarded, so a reader cannot mistake this for an
        // oversight.
        if let water = Self.recordedWater(in: entry.components, category: intake.category) {
            totals["water"] = water
        }
        return totals
    }

    /// The millilitres the revision's components record, summed, and only for a drink.
    private static func recordedWater(in components: [IntakeComponent], category: String) -> NutrientValue? {
        guard category == waterCategory else { return nil }
        var millilitres = Decimal(0)
        var found = false
        for component in components {
            guard component.unit.dimension == .volume else { continue }
            guard let converted = try? Quantity(value: component.amount, unit: component.unit).converted(to: .mL)
            else { continue }
            millilitres += converted.value
            found = true
        }
        return found ? .known(millilitres, .mL) : nil
    }
}

/// What one delivery run did, per operation, so a caller (or a log) can see it without re-reading the
/// store. The `operationID` is in every case, because one run may touch several operations.
public enum HealthKitDeliveryOutcome: Sendable, Equatable {
    /// An upsert was written and the operation acknowledged. The count is the plan's size.
    case delivered(operationID: String, samples: Int)
    /// A delete removed every sample this app wrote for the intake; the count is what went.
    case retracted(operationID: String, samples: Int)
    /// A delete removed the samples it was authorized to remove, but some quantity types were denied,
    /// so their samples are still in Health. The operation stays queued and the projection is left for
    /// a person; `denied` names the type identifiers that could not be written.
    case partlyRetracted(operationID: String, samples: Int, denied: [String])
    /// The upsert is stale: a delete for the same intake has already been delivered, so its samples
    /// are gone. The operation is acknowledged rather than written.
    case superseded(operationID: String)
    /// The operation is not due yet; `nextAttemptAt` says when it becomes due.
    case notDue(operationID: String, nextAttemptAt: Date)
    /// An earlier operation for the same intake is unresolved, so this one was not attempted. Delivering
    /// it out of order would let an obsolete sample overwrite a newer revision, because the nutrient it
    /// dropped has no higher-version sample protecting it. `blockedBy` is that earlier operation.
    case blocked(operationID: String, blockedBy: String)
    /// Access is denied and the operation is suspended until someone re-arms it. No automatic run will
    /// retry it, because retrying cannot grant Health access.
    case needsAttention(operationID: String, reason: String)
    /// A retryable failure; the operation is due again at `nextAttemptAt`.
    case retryScheduled(operationID: String, nextAttemptAt: Date, reason: String)
    /// The samples reached HealthKit but the journal could not record the delivery, so the operation is
    /// still queued. Unresolved on purpose: until the queue is consistent, nothing later for this
    /// intake may be delivered, or a redelivery of this revision could recreate an obsolete value.
    case notAcknowledged(operationID: String, detail: String)

    /// True when this operation is finished with and must not hold up the next one for its intake.
    ///
    /// Only a resolved outcome releases the intake. An operation that is deferred, blocked or waiting
    /// for a person keeps every later operation for the same intake waiting behind it, because the
    /// samples they would write depend on what it was going to write.
    var isResolved: Bool {
        switch self {
        case .delivered, .retracted, .superseded:
            return true
        case .partlyRetracted, .notDue, .blocked, .needsAttention, .retryScheduled, .notAcknowledged:
            return false
        }
    }
}

/// Delivers queued journal operations to HealthKit (NC-07B).
///
/// One run (`runOnce(now:)`) walks the journal's pending outbox and handles the operations addressed
/// to `.healthKit` in queue order — the store's own order, oldest revision first, so an edit is
/// written after the revision it supersedes. Operations for any other destination are left exactly as
/// they are: a relay operation is not this worker's business, and touching it would acknowledge
/// another destination's delivery.
///
/// **What an upsert writes.** The revision's totals go through `HealthKitWritePlanner`, which decides
/// the samples, the sync identifiers and the sync version (ADR 0002). Then, in this order:
///
/// 1. delete the samples this app wrote for nutrients the current plan does not write, and
/// 2. save the plan.
///
/// The deletion comes first on purpose. An edit can drop a nutrient — an unknown total plans no
/// sample — so nothing would replace the sample an earlier revision left behind and Health would keep
/// showing a stale value. Deleting it first and writing the current revision after is the only way to
/// retract it. The identifiers deleted are exactly `HealthKitWritePlanner.deletion(intakeID:keys:)`
/// over the mapped keys the plan does not name.
///
/// **What a delete does.** Every mapped key for the intake is deleted, whether or not the current
/// revision ever wrote it, because an earlier revision may have. The journal keys nothing off a
/// HealthKit UUID (ADR 0002), so this is a deletion by sync identifier.
///
/// **Failure handling.** `HealthSampleWriterError.authorizationDenied` needs a person, so the
/// operation is marked `needsAttention` with no retry scheduled: a scheduler that retried it would
/// fail forever and hide the real problem. Every other error is transient and is retried on the
/// backoff below. Either way the operation stays pending, because a delivery that was not recorded as
/// successful must not be forgotten.
public struct HealthKitDeliveryWorker: Sendable {
    /// The retry schedule after a transient failure: 1, 5 and 30 minutes, then every 2 hours.
    ///
    /// Backoff, not a fixed interval: HealthKit failing once is usually a store error, while a
    /// failure that never clears is a device that is asleep, out of coverage or out of battery, and
    /// an hourly retry costs nothing then. The list is indexed by the failure being handled, so it
    /// never grows and never retries more often than a minute.
    public static let backoffSchedule: [Int] = [60, 300, 1800, 7200]

    /// How long to wait after the `attemptNumber`th failure, counting from 1.
    ///
    /// The number is the count **including** the failure being handled, not the count already stored:
    /// `recordFailure` has not run yet when this is chosen, so indexing by the stored count made the
    /// first and second failures both wait a minute and pushed the documented 5 minute step to the
    /// third. Failures past the end of the schedule reuse its last step, so the wait never shrinks.
    public static func backoffSeconds(afterAttempt attemptNumber: Int) -> Int {
        let index = min(max(attemptNumber - 1, 0), backoffSchedule.count - 1)
        return backoffSchedule[index]
    }

    private let store: any JournalOutboxDelivery
    private let writer: any HealthSampleWriter
    private let totals: NutrientTotalsProvider

    public init(
        store: any JournalOutboxDelivery, writer: any HealthSampleWriter,
        totals: @escaping NutrientTotalsProvider
    ) {
        self.store = store
        self.writer = writer
        self.totals = totals
    }

    /// Processes every due `.healthKit` operation once and reports what each one did.
    ///
    /// `now` is the run's clock: it decides whether an operation is due and when a retry is
    /// scheduled. It is a parameter rather than a read of `Date()` so a test, and a replay after a
    /// restart, both see the same decision.
    @discardableResult
    public func runOnce(now: Date) async -> [HealthKitDeliveryOutcome] {
        let operations: [OutboxOperation]
        let suspended: Set<String>
        do {
            operations = try store.pendingOutbox()
            suspended = try store.suspendedOperationIDs()
        } catch {
            // A store that cannot be read delivers nothing. The operations stay pending, so the next
            // run picks them up; reporting an error here would say less than the store already knows.
            return []
        }
        var outcomes: [HealthKitDeliveryOutcome] = []
        // The intake each unresolved operation is holding up. Revisions are delivered oldest first, so
        // the first operation seen for an intake is the one everything later depends on.
        var blocking: [String: String] = [:]
        for operation in operations {
            guard operation.destination == .healthKit else { continue }
            if let blocker = blocking[operation.intakeID] {
                outcomes.append(.blocked(operationID: operation.operationID, blockedBy: blocker))
                continue
            }
            if suspended.contains(operation.operationID) {
                // Parked for a person: no automatic run retries it, and nothing later for this intake
                // may go past it either, since it was never delivered.
                let outcome = HealthKitDeliveryOutcome.needsAttention(
                    operationID: operation.operationID, reason: "waiting to be re-armed after a denial")
                outcomes.append(outcome)
                blocking[operation.intakeID] = operation.operationID
                continue
            }
            if let due = operation.nextAttemptAt, due > now {
                let outcome = HealthKitDeliveryOutcome.notDue(
                    operationID: operation.operationID, nextAttemptAt: due)
                outcomes.append(outcome)
                blocking[operation.intakeID] = operation.operationID
                continue
            }
            let outcome = await deliver(operation, now: now)
            outcomes.append(outcome)
            if !outcome.isResolved {
                blocking[operation.intakeID] = operation.operationID
            }
            // A delete that succeeded stops later upserts for the same intake: the samples are gone,
            // so writing them again would put back what was just retracted. Stale upserts are
            // acknowledged rather than written, and the store keeps them out of `pendingOutbox()`.
            if case .retracted = outcome {
                outcomes.append(contentsOf: await acknowledgeSupersededUpserts(for: operation.intakeID, upTo: operation.revision, now: now))
            }
        }
        return outcomes
    }

    private func deliver(_ operation: OutboxOperation, now: Date) async -> HealthKitDeliveryOutcome {
        switch operation.kind {
        case .upsert: return await upsert(operation, now: now)
        case .delete: return await retract(operation, now: now)
        }
    }

    private func upsert(_ operation: OutboxOperation, now: Date) async -> HealthKitDeliveryOutcome {
        let intake: Intake?
        do {
            intake = try store.activeIntakes().first { $0.id == operation.intakeID }
        } catch {
            return transient(operation, now: now, reason: "the intake could not be read")
        }
        guard let intake else {
            // The intake was deleted after this revision was queued. The delete that went with it is
            // in the same queue, so its samples are removed; writing this revision now would put back
            // what the delete removes.
            return acknowledge(operation, now: now, outcome: .superseded(operationID: operation.operationID))
        }
        // The totals are read before anything is written, and a failure here aborts the delivery. An
        // empty plan is not a fallback: it would mean deleting every previously written nutrient as
        // stale, saving nothing and acknowledging the operation, which records a failed read as a
        // successful empty revision.
        let plan: [HealthKitSampleSpec]
        do {
            plan = HealthKitWritePlanner.plan(
                intakeID: operation.intakeID,
                revision: operation.revision,
                occurredAt: intake.occurredAt,
                totals: try await totals(operation.intakeID, operation.revision)
            )
        } catch {
            return transient(operation, now: now, reason: "the totals for this revision could not be read")
        }
        do {
            try await requireAccess(for: plan.map(\.quantityTypeIdentifier))
            try await deleteStaleSamples(for: operation, plan: plan)
            try await writer.save(plan)
        } catch let error as HealthSampleWriterError {
            return handle(error, for: operation, now: now)
        } catch {
            // An error the writer did not type is still a delivery failure. Treating it as transient
            // is the safe direction: it retries, and a typed denial arrives as the typed error.
            return transient(operation, now: now, reason: "the samples could not be written")
        }
        return acknowledge(
            operation, now: now, outcome: .delivered(operationID: operation.operationID, samples: plan.count))
    }

    /// Refuses the delivery when this app may not write one of the types involved.
    ///
    /// Asked once per type rather than once per sample, because write access is a property of the
    /// type. A type that is not authorized raises the same typed denial a failed save would, so both
    /// routes end in `needsAttention` and neither schedules a retry: only a person can grant Health
    /// access. This is also cheaper than discovering it from a save, and ADR 0002's run is why the
    /// permission sheet cannot be trusted to have reported what was granted.
    private func requireAccess(for identifiers: [String]) async throws {
        let allowed = await writer.canWrite(identifiers: identifiers)
        guard identifiers.allSatisfy({ allowed[$0] == true }) else {
            throw HealthSampleWriterError.authorizationDenied
        }
    }

    /// Removes the samples of the mapped nutrients this plan does not write, so an edit cannot leave
    /// a stale value in Health.
    ///
    /// A failure here is the caller's to handle: deleting and saving is one delivery, so if the
    /// deletion fails the save is not attempted and the whole operation is retried.
    private func deleteStaleSamples(for operation: OutboxOperation, plan: [HealthKitSampleSpec]) async throws {
        // Revision 1 has nothing to retract: no earlier revision wrote anything for this intake, so
        // there is no stale sample to remove and asking HealthKit to delete 16 identifiers that were
        // never written would be 16 pointless queries.
        guard operation.revision > 1 else { return }
        let planned = Set(plan.map(\.syncIdentifier))
        let stale = HealthKitWritePlanner.deletion(intakeID: operation.intakeID, keys: Self.mappedKeys)
            .filter { !planned.contains($0) }
        guard !stale.isEmpty else { return }
        _ = try await writer.deleteSamples(syncIdentifiers: stale)
    }

    /// Removes the samples this app may remove, and reports the types it may not.
    ///
    /// A denial on one type must not strand the others. Someone can authorize water and refuse
    /// protein, and aborting the whole retraction would leave the authorized water sample in Health
    /// after the journal entry is gone — a sample nobody can remove from the app, attached to an entry
    /// that no longer exists. So the retraction is per type: everything authorized goes, and only the
    /// denied types keep the operation queued, with the projection left for a person and the denied
    /// identifiers named so the app can say which ones are stranded.
    private func retract(_ operation: OutboxOperation, now: Date) async -> HealthKitDeliveryOutcome {
        let identifiers = HealthKitWritePlanner.deletion(intakeID: operation.intakeID, keys: Self.mappedKeys)
        let types = HealthKitWritePlanner.mappings.map(\.quantityTypeIdentifier)
        let allowed = await writer.canWrite(identifiers: types)
        let denied = Set(types.filter { allowed[$0] != true })
        let removable = identifiers.filter { !denied.contains(Self.typeIdentifier(for: $0)) }
        do {
            let deleted = removable.isEmpty ? 0 : try await writer.deleteSamples(syncIdentifiers: removable)
            if denied.isEmpty {
                return acknowledge(
                    operation, now: now, outcome: .retracted(operationID: operation.operationID, samples: deleted))
            }
            do {
                try store.recordFailure(operationID: operation.operationID, retryAt: nil, needsAttention: true)
            } catch {
                // Not recorded, so the operation stays due and the next run tries the retraction again.
                // It is idempotent, and re-delivering it is better than dropping the stranded samples.
            }
            return .partlyRetracted(
                operationID: operation.operationID, samples: deleted, denied: denied.sorted())
        } catch let error as HealthSampleWriterError {
            return handle(error, for: operation, now: now)
        } catch {
            return transient(operation, now: now, reason: "the samples could not be deleted")
        }
    }

    /// The quantity type a sync identifier belongs to, through the planner's own mapping.
    ///
    /// The writer resolves the same way; this is the journal half, used to decide which identifiers a
    /// denial covers.
    private static func typeIdentifier(for syncIdentifier: String) -> String {
        let key = syncIdentifier.split(separator: ":").last.map(String.init) ?? ""
        let canonical = HealthKitWritePlanner.canonicalKey(for: key)
        return HealthKitWritePlanner.mappings.first { $0.nutrientKey == canonical }?.quantityTypeIdentifier ?? ""
    }

    /// Every key the mapping table names, so a delete covers every sample this app could have written
    /// for the intake, not only the ones the current revision happens to state.
    private static let mappedKeys: [String] = HealthKitWritePlanner.mappings.map(\.nutrientKey)

    /// Marks every still-pending upsert for the intake at or below `revision` as superseded, because
    /// a delivered delete has retracted their samples.
    private func acknowledgeSupersededUpserts(
        for intakeID: String, upTo revision: Int, now: Date
    ) async -> [HealthKitDeliveryOutcome] {
        let operations: [OutboxOperation]
        do {
            operations = try store.pendingOutbox()
        } catch {
            return []
        }
        var outcomes: [HealthKitDeliveryOutcome] = []
        for operation in operations where operation.destination == .healthKit
            && operation.kind == .upsert && operation.intakeID == intakeID && operation.revision <= revision {
            outcomes.append(acknowledge(operation, now: now, outcome: .superseded(operationID: operation.operationID)))
        }
        return outcomes
    }

    /// Typed failures: a denied authorization needs a person, anything else is worth another attempt.
    private func handle(
        _ error: HealthSampleWriterError, for operation: OutboxOperation, now: Date
    ) -> HealthKitDeliveryOutcome {
        switch error {
        case .authorizationDenied:
            return needsAttention(operation, now: now, reason: "HealthKit access is not granted")
        case .transient(let message):
            return transient(operation, now: now, reason: message)
        }
    }

    /// Schedules the next attempt on the backoff and leaves the operation pending.
    ///
    /// The schedule is indexed by `attempts + 1`, the count this failure will leave behind once
    /// `recordFailure` has run, so the first failure waits a minute and the second waits five.
    private func transient(_ operation: OutboxOperation, now: Date, reason: String) -> HealthKitDeliveryOutcome {
        let attempt = operation.attempts + 1
        let next = now.addingTimeInterval(TimeInterval(Self.backoffSeconds(afterAttempt: attempt)))
        return retry(operation, nextAttemptAt: next, reason: reason)
    }

    /// Records a failure only a person can resolve: `attempts` grows, but no retry is scheduled, so
    /// the operation waits in the queue instead of failing on a timer forever.
    private func needsAttention(_ operation: OutboxOperation, now: Date, reason: String) -> HealthKitDeliveryOutcome {
        do {
            try store.recordFailure(operationID: operation.operationID, retryAt: nil, needsAttention: true)
            return .needsAttention(operationID: operation.operationID, reason: reason)
        } catch {
            // The queue could not record the failure. The operation stays pending and due, so the next
            // run tries it again; that is the same retry storm this case exists to avoid, but only
            // until the store is writable again.
            return transient(operation, now: now, reason: reason)
        }
    }

    private func retry(
        _ operation: OutboxOperation, nextAttemptAt: Date, reason: String
    ) -> HealthKitDeliveryOutcome {
        let outcome = HealthKitDeliveryOutcome.retryScheduled(
            operationID: operation.operationID, nextAttemptAt: nextAttemptAt, reason: reason)
        do {
            try store.recordFailure(operationID: operation.operationID, retryAt: nextAttemptAt, needsAttention: false)
            return outcome
        } catch {
            // The schedule could not be recorded, so nothing was deferred: the operation stays due and
            // pending, and the next run tries it again immediately rather than losing it. The attempt
            // count did not grow either, so the backoff restarts — the queue is not writable, and the
            // next run is the thing that has to notice.
            return .retryScheduled(
                operationID: operation.operationID, nextAttemptAt: nextAttemptAt,
                reason: "\(reason); the retry could not be recorded")
        }
    }

    /// Acknowledges a delivered operation, so `pendingOutbox()` stops offering it.
    ///
    /// **A failed acknowledgement is unresolved, not delivered.** The samples are in HealthKit but the
    /// journal does not know it, so the operation is still queued. Reporting the outcome as resolved
    /// would let this run deliver a newer revision for the same intake, and the next run would then
    /// redeliver this older one — and if the newer revision dropped a nutrient, the stale-sample
    /// deletion has left no higher-version sample protecting that identifier, so the obsolete value can
    /// be recreated. Returning an unresolved outcome keeps the intake blocked until the queue is
    /// consistent again.
    private func acknowledge(
        _ operation: OutboxOperation, now: Date, outcome: HealthKitDeliveryOutcome
    ) -> HealthKitDeliveryOutcome {
        do {
            try store.acknowledge(operationID: operation.operationID, at: now)
            return outcome
        } catch {
            // Deliberately not `try?`: the write happened and the record did not, and only the caller
            // can decide what that means for the rest of the queue.
            return .notAcknowledged(
                operationID: operation.operationID,
                detail: "the samples were written but the journal could not record the delivery")
        }
    }
}
