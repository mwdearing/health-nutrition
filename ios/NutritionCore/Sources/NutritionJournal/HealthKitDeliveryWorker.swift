import Foundation
import NutritionDomain

/// A sample the writer built that HealthKit will never accept, raised for `HKError.errorInvalidArgument`
/// on a **save**.
///
/// **Permanent, not transient.** Apple's save contract counts an invalid argument as a save failure,
/// and a retry rebuilds the same specs from the same immutable journal revision, so the same save
/// fails the same way every time. The app target's writer raises this instead of a transient error so
/// the worker parks the operation with the reason HealthKit gave, rather than backing off against
/// something no amount of waiting will fix.
///
/// **A rejected save only.** Apple defines this code as the app passing an invalid argument to a
/// HealthKit API, not specifically as a rejected sample, so a conformer must raise it only where an
/// immutable sample it built is what was refused. On a query or a deletion there is no sample to
/// correct, an app update may well fix the call, and nothing can be retracted by editing the entry —
/// those stay transient, on the backoff, because that is the direction a later fix can recover from.
///
/// It is a separate type rather than a third case of `HealthSampleWriterError` because that enum is
/// the writer's protocol-level "denied or worth another attempt" pair: a rejected sample is neither,
/// and naming it as its own type keeps the retry decision readable at the `catch`.
public struct HealthSampleRejectedError: Error, Sendable, Equatable {
    /// What HealthKit refused, kept for the reason a person is shown.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// The delivery bookkeeping that has to carry **which** failure needs a person.
///
/// A refinement of `JournalOutboxDelivery` rather than part of it: recording that an operation is
/// suspended is something any store can do, but recording *why* — and reading that reason back on a
/// later run — is what lets a rejected sample stop being reported as a refused authorization. A store
/// that cannot persist a reason still satisfies `JournalOutboxDelivery`, and the worker falls back to
/// naming the state rather than the cause.
///
/// **The reason is stored, never recomputed.** It is written once, when the suspension is recorded, and
/// read back on every subsequent run and after every relaunch. Recomputing it from the state would
/// report the same generic phrase for both permanent failures, which are parked identically and need
/// opposite corrections: one needs a person to grant Health access, the other needs the plan or the
/// entry to change.
public protocol JournalDeliverySuspension: JournalOutboxDelivery {
    /// Records one failed attempt that needs a person, with the reason to report from now on.
    ///
    /// The projection becomes `needsAttention`, including the one belonging to this operation when a
    /// later edit has already superseded it, and so does the current projection for the destination, so
    /// the app shows the condition.
    func recordFailure(
        operationID: String, retryAt: Date?, needsAttention: Bool, reason: String?
    ) throws
    /// Why an operation is suspended, or nil when it is not suspended.
    func suspensionReason(operationID: String) throws -> String?
}

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
/// This is the default answer `AppServices` wires in, and it states two things: the water a drink
/// records, and the product's own nutrients scaled to the amount that was logged.
///
/// - **Snapshot nutrients are scaled, not copied.** `ProductDefinition.nutrients` is stated on
///   `labelBasis` (typically per 100 g), not for the amount the component records, so a 40 g
///   component of a product whose label states 13 g of protein per 100 g carries 5.2 g. The factor
///   comes from `IntakeContextSnapshotBasis.scalingFactor(labelBasis:logged:)`, the same arithmetic the
///   relay encoder uses, and the multiplication is exact decimal: no float, no rounding. **Nothing is
///   written when that factor cannot be resolved** — a basis the journal cannot answer ("per 100 kcal",
///   "per 100 g or mL") or components that cannot scale it. An unscaled label value states the whole
///   package rather than the portion eaten, which is a wrong number in Health, and a guessed one
///   worse; the planner then plans no sample for the nutrient, which is the honest outcome. See
///   `docs/healthkit-writer.md`.
/// - **A nutrient with no stated amount is omitted.** `.unknown`, `.notApplicable` and
///   `.belowReportingThreshold` say there is nothing to scale, so they contribute no total rather than
///   a zero.
/// - **Water comes from the components, and only for a water-category intake.** Volume is dietary
///   water when the entry is a drink; 250 mL of milk, juice or oil is not. A component measured in
///   another unit contributes nothing rather than a guess, because mass to volume needs a density the
///   journal does not record. A snapshot's own water never replaces it: what was poured is recorded,
///   and a label's per-100 mL figure is not.
/// - A key the planner has no mapping for is passed through; deciding which keys are writeable is the
///   planner's business, not this provider's.
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
        if let water = Self.recordedWater(in: entry.components, category: intake.category) {
            totals["water"] = water
        }
        // The water the components record wins a contested key: it is what was actually poured, where
        // the snapshot states the product's own water on the label's basis.
        totals.merge(
            try scaledSnapshotNutrients(of: entry)) { recorded, _ in recorded }
        return totals
    }

    /// The nutrients the revision's product snapshot states, each scaled to the amount that was logged.
    ///
    /// **Nothing is returned when the basis cannot be applied**, rather than the unscaled value or a
    /// guess: the snapshot states the product, not the portion, so a number that reaches Health
    /// unscaled is the wrong number. A revision with no product snapshot — an entry logged by hand —
    /// has nothing to scale and returns nothing, which is an answer and not a failed read.
    private func scaledSnapshotNutrients(of revision: IntakeRevision) throws -> [String: NutrientValue] {
        guard let snapshotID = revision.productSnapshotID,
            let product = try store.product(snapshotID: snapshotID)
        else { return [:] }
        guard let factor = IntakeContextSnapshotBasis.scalingFactor(
            labelBasis: product.labelBasis, logged: revision.components)
        else { return [:] }
        var scaled: [String: NutrientValue] = [:]
        for (key, value) in product.nutrients {
            // Only a stated amount can be scaled. The other cases say the product states no amount for
            // this nutrient, and passing one on would state a value the label declined to state.
            guard case .known(let amount, let unit) = value else { continue }
            scaled[key] = .known(amount * factor, unit)
        }
        return scaled
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
/// **Failure handling.** Two failures need a person and are marked `needsAttention` with no retry
/// scheduled: `HealthSampleWriterError.authorizationDenied`, because retrying cannot grant Health
/// access, and `HealthSampleRejectedError`, because a sample HealthKit will never accept is rebuilt
/// identically by every retry. A scheduler that retried either would fail forever and hide the real
/// problem behind a queue that never drains. Every other error is transient and is retried on the
/// backoff below. Either way the operation stays pending, because a delivery that was not recorded as
/// successful must not be forgotten. The reason is **stored** with the suspension and read back on
/// every later run, so a rejected sample is never reported as a refused authorization.
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

    /// `JournalDeliverySuspension` rather than `JournalOutboxDelivery`: the worker reports **why** an
    /// operation is parked, so a store that cannot persist that reason cannot back this worker.
    private let store: any JournalDeliverySuspension
    private let writer: any HealthSampleWriter
    private let totals: NutrientTotalsProvider

    public init(
        store: any JournalDeliverySuspension, writer: any HealthSampleWriter,
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
                // **A correction takes over from a suspension.** Blocking every later operation for this
                // intake made both of a person's remedies useless: an edit queues a revision nothing
                // would deliver, and a retraction strands the samples a deletion is meant to remove.
                // Re-arming is for retrying this same revision, which is the other half — so when the
                // queue already holds the work that replaces this one, it goes ahead and this operation
                // is acknowledged as superseded rather than retried or left to hold the intake.
                if let replacement = replacement(for: operation, in: operations) {
                    let outcome = acknowledge(
                        operation, now: now, outcome: .superseded(operationID: operation.operationID))
                    outcomes.append(outcome)
                    if !outcome.isResolved {
                        blocking[operation.intakeID] = operation.operationID
                    }
                    continue
                }
                // Parked for a person: no automatic run retries it, and nothing later for this intake
                // may go past it either, since it was never delivered.
                //
                // The reason comes from the store rather than from a phrase rebuilt here: this branch runs
                // on every later pass and after every relaunch, and a refused authorization and a
                // rejected sample are parked in the same state while needing opposite corrections.
                let outcome = HealthKitDeliveryOutcome.needsAttention(
                    operationID: operation.operationID,
                    reason: (try? store.suspensionReason(operationID: operation.operationID)) ?? "waiting to be re-armed")
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

    /// The queued operation that replaces a suspended one, or nil when nothing has.
    ///
    /// **A newer revision, or a retraction of the same intake.** Both are a person's correction of the
    /// entry the suspension is about, and both deliver the state the suspended operation could not: the
    /// corrected revision writes what the entry now says, and the retraction removes what was written
    /// for an entry that no longer exists. A retraction counts at the *same* revision, because deleting
    /// an intake does not bump it.
    ///
    /// Only operations the store still offers count, so an already-delivered retraction does not
    /// release anything. An earlier operation of the same intake does not either: it is the one being
    /// delivered before this one, and letting it out of order is the stale-sample failure the ordering
    /// rule exists to prevent.
    private func replacement(
        for operation: OutboxOperation, in operations: [OutboxOperation]
    ) -> OutboxOperation? {
        operations.first { candidate in
            candidate.operationID != operation.operationID
                && candidate.destination == operation.destination
                && candidate.intakeID == operation.intakeID
                && (candidate.revision > operation.revision || candidate.kind == .delete)
        }
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
        } catch let error as HealthSampleRejectedError {
            return rejectedSample(error, for: operation, now: now)
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
    ///
    /// **Every mapped type is classified as exactly one of three things, and the classification never
    /// reads the journal.** An authorized type is deleted; an explicitly denied one cannot be deleted
    /// and keeps the operation for a person; a type that was never asked (`.notDetermined`) holds
    /// nothing in Health and would refuse a delete, so it is skipped rather than counted as denied.
    /// The retraction therefore asks two questions of the writer — `canWrite` to decide what may go,
    /// `deniedWriteTypes` to decide what needs a person — and treats a type that is neither as never
    /// asked.
    private func retract(_ operation: OutboxOperation, now: Date) async -> HealthKitDeliveryOutcome {
        let identifiers = HealthKitWritePlanner.deletion(intakeID: operation.intakeID, keys: Self.mappedKeys)
        let allowed = await writer.canWrite(identifiers: Self.mappedTypeIdentifiers)
        let denied = await writer.deniedWriteTypes(identifiers: Self.mappedTypeIdentifiers)
        // A type that is neither writable nor denied was never asked (`.notDetermined`), so nothing
        // can exist for it and it is silently skipped: no delete is attempted for it.
        let removable = identifiers.filter { allowed[Self.typeIdentifier(for: $0)] == true }
        do {
            let deleted = removable.isEmpty ? 0 : try await writer.deleteSamples(syncIdentifiers: removable)
            if denied.isEmpty {
                return acknowledge(
                    operation, now: now, outcome: .retracted(operationID: operation.operationID, samples: deleted))
            }
            do {
                try store.recordFailure(
                    operationID: operation.operationID, retryAt: nil, needsAttention: true,
                    reason: "HealthKit access is not granted for \(denied.sorted().joined(separator: ", "))")
            } catch {
                // Not recorded, so the operation stays due and the next run tries the retraction again.
                // It is idempotent, and re-delivering it is better than dropping the stranded samples.
            }
            return .partlyRetracted(
                operationID: operation.operationID, samples: deleted, denied: denied.sorted())
        } catch let error as HealthSampleWriterError {
            return handle(error, for: operation, now: now)
        } catch let error as HealthSampleRejectedError {
            return rejectedSample(error, for: operation, now: now)
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

    /// Every quantity type the mapping table names, so a retraction can ask the writer about all of
    /// them at once and still tell an authorized type from an explicitly denied one.
    private static let mappedTypeIdentifiers: [String] = HealthKitWritePlanner.mappings.map(\.quantityTypeIdentifier)

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
            return needsAttention(
                operation, now: now, reason: "HealthKit access is not granted, so it cannot be written")
        case .transient(let message):
            return transient(operation, now: now, reason: message)
        }
    }

    /// A rejected sample needs a person too, for the same reason a denial does: the plan is rebuilt
    /// from the stored revision on every attempt, so retrying writes the identical sample and fails
    /// the identical way. Parking it says what has to change, where backing off would only hide it.
    private func rejectedSample(
        _ error: HealthSampleRejectedError, for operation: OutboxOperation, now: Date
    ) -> HealthKitDeliveryOutcome {
        needsAttention(operation, now: now, reason: error.reason)
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
            try store.recordFailure(
                operationID: operation.operationID, retryAt: nil, needsAttention: true, reason: reason)
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
            try store.recordFailure(
                operationID: operation.operationID, retryAt: nextAttemptAt, needsAttention: false, reason: nil)
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
