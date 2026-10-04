import Foundation
import NutritionDomain

/// Supplies the nutrient totals one revision contributes, keyed by intake id and revision number.
///
/// The worker does not compute totals: how much protein an entry carries is the journal's business,
/// and the planner only maps whatever it is handed. Injected, so the worker can be tested without a
/// store and so a future totals source does not change the delivery rules.
public typealias NutrientTotalsProvider = @Sendable (_ intakeID: String, _ revision: Int) async -> [String: NutrientValue]

/// The nutrient totals one journal revision contributes, read from what the revision itself recorded.
///
/// This is the default answer `AppServices` wires in, and it is deliberately narrow:
///
/// - A revision recorded from a looked-up product or a recipe carries a product snapshot, and the
///   values that snapshot **states** are what is reported. The snapshot states them for a whole basis
///   (`labelBasis`, typically 100 g) and applying the amount a component records is arithmetic that
///   needs to know the basis exactly. Reporting the stated values unscaled would put a wrong number
///   into Health, so scaling arrives with the totals source that can do it exactly; until then this
///   provider is the honest one and says so.
/// - A hand-typed revision has no snapshot and therefore states nothing, which reads as unknown and
///   never as zero. `HealthKitWritePlanner` skips an unknown total, so no sample is written for it.
/// - **Water is the exception**: it is not a label value but the volume the components record, so it
///   is summed from them. A component measured in another unit contributes nothing rather than a
///   guess, because mass to volume needs a density the journal does not record.
///
/// A revision that cannot be read yields no totals rather than an error: the caller is a delivery
/// worker, and an empty plan is a safe thing to write.
public struct JournalSnapshotTotals: Sendable {
    private let store: any JournalStore

    public init(store: any JournalStore) {
        self.store = store
    }

    public func totals(intakeID: String, revision: Int) async -> [String: NutrientValue] {
        (try? totalsNow(intakeID: intakeID, revision: revision)) ?? [:]
    }

    private func totalsNow(intakeID: String, revision: Int) throws -> [String: NutrientValue] {
        guard let entry = try store.revisions(of: intakeID).first(where: { $0.number == revision }) else {
            return [:]
        }
        var totals: [String: NutrientValue] = [:]
        if let snapshotID = entry.productSnapshotID, let snapshot = try store.product(snapshotID: snapshotID) {
            for (nutrient, value) in snapshot.nutrients {
                totals[nutrient] = value
            }
        }
        if let water = Self.recordedWater(in: entry.components) {
            totals["water"] = water
        }
        return totals
    }

    private static func recordedWater(in components: [IntakeComponent]) -> NutrientValue? {
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
    /// The upsert is stale: a delete for the same intake has already been delivered, so its samples
    /// are gone. The operation is acknowledged rather than written.
    case superseded(operationID: String)
    /// The operation is not due yet; `nextAttemptAt` says when it becomes due.
    case notDue(operationID: String, nextAttemptAt: Date)
    /// Access is denied, so no retry is scheduled and the projection is left for a person.
    case needsAttention(operationID: String, reason: String)
    /// A retryable failure; the operation is due again at `nextAttemptAt`.
    case retryScheduled(operationID: String, nextAttemptAt: Date, reason: String)
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
    /// an hourly retry costs nothing then. The list is indexed by the attempts already made, so it
    /// never grows and never retries more often than a minute.
    public static let backoffSchedule: [Int] = [60, 300, 1800, 7200]

    /// How long to wait after `attempts` failed attempts. Attempts beyond the schedule reuse its last
    /// step, so the wait never shrinks again.
    public static func backoffSeconds(afterAttempts attempts: Int) -> Int {
        let index = min(max(attempts - 1, 0), backoffSchedule.count - 1)
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
        do {
            operations = try store.pendingOutbox()
        } catch {
            // A store that cannot be read delivers nothing. The operations stay pending, so the next
            // run picks them up; reporting an error here would say less than the store already knows.
            return []
        }
        var outcomes: [HealthKitDeliveryOutcome] = []
        for operation in operations {
            guard operation.destination == .healthKit else { continue }
            if let due = operation.nextAttemptAt, due > now {
                outcomes.append(.notDue(operationID: operation.operationID, nextAttemptAt: due))
                continue
            }
            let outcome = await deliver(operation, now: now)
            outcomes.append(outcome)
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
        let plan = HealthKitWritePlanner.plan(
            intakeID: operation.intakeID,
            revision: operation.revision,
            occurredAt: intake.occurredAt,
            totals: await totals(operation.intakeID, operation.revision)
        )
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

    private func retract(_ operation: OutboxOperation, now: Date) async -> HealthKitDeliveryOutcome {
        let identifiers = HealthKitWritePlanner.deletion(intakeID: operation.intakeID, keys: Self.mappedKeys)
        let types = HealthKitWritePlanner.mappings.map(\.quantityTypeIdentifier)
        do {
            try await requireAccess(for: types)
            let deleted = try await writer.deleteSamples(syncIdentifiers: identifiers)
            return acknowledge(
                operation, now: now, outcome: .retracted(operationID: operation.operationID, samples: deleted))
        } catch let error as HealthSampleWriterError {
            return handle(error, for: operation, now: now)
        } catch {
            return transient(operation, now: now, reason: "the samples could not be deleted")
        }
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
    private func transient(_ operation: OutboxOperation, now: Date, reason: String) -> HealthKitDeliveryOutcome {
        let next = now.addingTimeInterval(TimeInterval(Self.backoffSeconds(afterAttempts: operation.attempts)))
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
    /// A failed acknowledgement returns the outcome anyway: the samples were written, and a redelivery
    /// is harmless because the plan is rebuilt from the stored revision and HealthKit replaces an
    /// equal-version sample. Reporting the failure as if nothing had been written would be wrong.
    private func acknowledge(
        _ operation: OutboxOperation, now: Date, outcome: HealthKitDeliveryOutcome
    ) -> HealthKitDeliveryOutcome {
        try? store.acknowledge(operationID: operation.operationID, at: now)
        return outcome
    }
}
