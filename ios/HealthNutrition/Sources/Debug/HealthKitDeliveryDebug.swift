#if DEBUG
import Foundation
import HealthKit
import NutritionJournal
import Observation
import SwiftUI

/// DEBUG-only status for the real HealthKit delivery worker (NC-08 device acceptance).
///
/// `HealthKitDeliveryWorker` is built in every build but has no caller in a release one, because the
/// journal store enables no destinations there. This model is what makes the worker reachable on a
/// debug device: it runs one delivery pass, asks HealthKit for write access to every mapped type,
/// and holds enough state for a screen to say plainly what is queued, what is waiting for a person
/// and what the last run did.
///
/// **The status is read from the store, not remembered.** Pending, needing-attention and suspended
/// are counted from the outbox every time they are shown, so a number on screen is the queue as it
/// stands rather than what an earlier run left behind.
///
/// Nothing here changes the worker, the writer or any journal behaviour: it calls `runOnce(now:)`,
/// asks for authorization, and reads the store's own counts. The whole file is behind `#if DEBUG`,
/// so a release build does not contain it and requests no Health access at all.
@MainActor
@Observable
final class HealthKitDeliveryStatus {
    /// How much is queued, split the way a person needs to read it: what will be attempted, what is
    /// waiting for them, and what is parked.
    struct Counts: Equatable {
        /// Queued `.healthKit` operations, suspended ones included.
        var pending = 0
        /// Current projections left in `needsAttention`, which is the condition a person has to clear.
        var needsAttention = 0
        /// Operations whose failure was recorded, so no automatic run will retry them.
        var suspended = 0

        static let none = Counts()
    }
    /// What Health has been asked about, for every type in the planner's table.
    ///
    /// `partial` is the case that broke the first device run: a request covering only some of the
    /// mapped types leaves the rest `.notDetermined`, which a `contains` gate reads as "asked" and
    /// the worker reads as a denial it then parks forever.
    enum AuthorizationState: Equatable {
        /// Health has not been asked, or cannot be asked on this device.
        case notRequested
        /// Some mapped types are still `.notDetermined`.
        case partial
        /// Every mapped type that resolves has left `.notDetermined`.
        case requested
    }

    /// The mapped types a request covers, resolved from the planner's table so a row added there is
    /// requested and checked without anything here being edited.
    struct MappedTypes {
        /// Every mapped type that resolves, for writing.
        var share = Set<HKSampleType>()
        /// The same types, for reading: a request asks for both so the spike can query back what it
        /// wrote and the app can see its own samples.
        var read = Set<HKObjectType>()
        /// Mapping keys whose identifier HealthKit does not resolve, named rather than dropped.
        var unresolved: [String] = []
    }

    /// The mapped types HealthKit resolves, read once so the request, the gate and the spike all
    /// agree on what "every mapped type" means.
    static func mappedTypes() -> MappedTypes {
        var mapped = MappedTypes()
        for mapping in HealthKitWritePlanner.mappings {
            guard
                let type = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: mapping.quantityTypeIdentifier))
            else {
                mapped.unresolved.append(mapping.nutrientKey)
                continue
            }
            mapped.share.insert(type)
            mapped.read.insert(type)
        }
        return mapped
    }

    private(set) var counts: Counts = .none
    /// When the last run started, or nil when this launch has not run one.
    private(set) var lastRunAt: Date?
    /// One plain line per operation the last run handled, in the order the worker reported them.
    private(set) var lastRunLines: [String] = []
    /// What the authorization request reported. HealthKit never says which types it granted, so this
    /// says what was asked for rather than pretending to know the answer.
    private(set) var authorizationSummary = "not requested"
    /// What the last re-arm reported. Separate from `authorizationSummary` so that field keeps
    /// answering only what it is named for; a denial and a re-arm are different events.
    private(set) var rearmSummary: String?
    /// True while a request or a delivery run is in flight, so a second tap cannot start a second one.
    private(set) var isBusy = false
    /// Why the counts could not be read, when they could not be.
    private(set) var readError: String?

    /// The one worker the app runs, handed in rather than built again: two workers over one store
    /// would each try to deliver the same operation.
    private let healthKitDelivery: HealthKitDeliveryWorker
    private let store: any JournalDeliverySuspension
    private let healthStore = HKHealthStore()
    /// How the gate reads Health's answer. Injectable so the app tests can drive it without a device;
    /// production reads `HKHealthStore`, which is the only authority on what was granted.
    private let authorizationProbe: () -> AuthorizationState

    init(
        healthKitDelivery: HealthKitDeliveryWorker,
        store: any JournalDeliverySuspension,
        authorizationProbe: @escaping () -> AuthorizationState = HealthKitDeliveryStatus.readHealthKitAuthorization
    ) {
        self.healthKitDelivery = healthKitDelivery
        self.store = store
        self.authorizationProbe = authorizationProbe
    }

    /// Whether every mapped type that resolves has been asked about, read from Health itself rather
    /// than remembered: a type that has been through the request sheet is no longer `.notDetermined`,
    /// whatever the person chose. Asking Health keeps the answer true across relaunches and
    /// reinstalls without storing anything of our own, and requiring **all** of them is what stops a
    /// partial request from parking the types it left out.
    ///
    /// A mapped type that does not resolve is not counted as undetermined, because Health cannot
    /// answer for it and the request reports it by name instead.
    static func readHealthKitAuthorization() -> AuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else { return .notRequested }
        let mapped = mappedTypes()
        guard !mapped.share.isEmpty else { return .notRequested }
        let store = HKHealthStore()
        let undetermined = mapped.share.contains { store.authorizationStatus(for: $0) == .notDetermined }
        return undetermined ? .partial : .requested
    }

    /// The one line Today shows: how much is queued, waiting for a person and parked.
    var summaryLine: String {
        "Health delivery: \(counts.pending) pending, "
            + "\(counts.needsAttention) needing attention, \(counts.suspended) suspended"
    }

    /// Whether a run or a request may start.
    var canAct: Bool { !isBusy }

    // MARK: - Actions

    /// Asks HealthKit for write access to every type in the planner's mapping table, and for no read
    /// access at all: the writer only ever saves and deletes its own samples, so nothing here needs to
    /// read anything out of Health.
    ///
    /// The types come from `HealthKitWritePlanner.mappings` rather than from a list written here, so a
    /// row added to the table is requested too. An identifier HealthKit does not know is named on
    /// screen instead of being dropped, because a mapping the planner uses and this request cannot
    /// reach would fail every delivery with a denial nobody can fix.
    /// Answering the sheet also re-arms what was suspended and runs a pass, for the same reason the
    /// spike's request does: a request is the person's answer to a denial, and the queue should not
    /// have to wait for the next launch to act on it.
    func requestAuthorizationForMappedTypes() async {
        guard await requestAuthorizationSheet() else { return }
        await authorizationRequested()
    }

    /// The request itself, reporting what it asked for. Returns whether the sheet was answered: only
    /// then is there a new authorization to act on, and `isBusy` is down by the time it returns so
    /// the re-arm and the pass that follow are not refused as a run already in flight.
    private func requestAuthorizationSheet() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationSummary = "HealthKit is not available on this device"
            return false
        }
        let mapped = Self.mappedTypes()
        do {
            // The async request returns nothing: it completes once the sheet is done and HealthKit
            // deliberately never says which types were granted.
            try await healthStore.requestAuthorization(toShare: mapped.share, read: [])
            var summary = "requested write access for \(mapped.share.count) mapped type(s), no read access"
            if !mapped.unresolved.isEmpty {
                summary += "; HealthKit does not know \(mapped.unresolved.sorted().joined(separator: ", "))"
            }
            authorizationSummary = summary
            return true
        } catch {
            authorizationSummary = "request failed: \(error.localizedDescription)"
            return false
        }
    }

    /// The request sheet has been answered, so anything parked for the missing request is worth
    /// another attempt and one pass is worth running now rather than at the next app trigger.
    ///
    /// **Every suspended operation is re-armed, not only the ones parked for a denial.** The
    /// suspension does not record which cause parked it, and a single person's answer to the sheet is
    /// a reasonable moment to retry the lot: a rejected sample either passes now or parks again with
    /// the same stored reason. Re-arming stays something a person causes, as the store requires, and
    /// this is that person.
    func authorizationRequested(now: Date = Date()) async {
        guard !isBusy else { return }
        // Read the queue first: the re-arm acts on what is suspended now, not on what the last
        // refresh happened to see.
        refresh()
        rearmSuspended()
        let rearmed = rearmSummary
        await run(now: now, automatic: false)
        // The pass clears `rearmSummary` as it starts; what this action re-armed is still what the
        // person needs to read afterwards.
        rearmSummary = rearmed
    }

    /// One delivery pass, then the counts and the outcome list are read again so the screen shows what
    /// this run did rather than what the one before it did.
    ///
    /// `automatic` is true for the runs the app starts itself (foreground, add, edit, delete). Those wait
    /// until Health has been asked about **every** mapped type: a worker that runs first would find no
    /// permission, suspend the very first entry and report a denial that is only the missing request,
    /// and a partial request is the same trap with more types in it — the types it never mentioned stay
    /// `.notDetermined`, which the writer reads as denied and the worker then parks for good. The "Run
    /// now" button is never automatic. A run requested while another is in flight is remembered and
    /// repeated when that one ends, so a change made after the running pass read the queue is not left
    /// waiting for the next trigger.
    func run(now: Date = Date(), automatic: Bool = false) async {
        if automatic && authorizationProbe() != .requested {
            refresh()
            return
        }
        guard !isBusy else {
            rerunRequested = true
            return
        }
        isBusy = true
        defer { isBusy = false }
        var passTime = now
        repeat {
            rerunRequested = false
            rearmSummary = nil
            let outcomes = await healthKitDelivery.runOnce(now: passTime)
            lastRunAt = passTime
            lastRunLines = outcomes.map(Self.line(for:))
            refresh()
            passTime = Date()
        } while rerunRequested
    }

    private var rerunRequested = false

    /// The suspended operation ids read by the last `refresh()`, kept so the re-arm action knows what
    /// it is clearing. Not shown: the ids are opaque, and the count on the summary line is the part a
    /// person reads.
    private var suspendedIDs: Set<String> = []

    /// Whether the re-arm action has anything to do. False while a run is in flight, so a re-arm cannot
    /// race the pass that is deciding the same operations' fate.
    var canRearmSuspended: Bool { !isBusy && !suspendedIDs.isEmpty }

    /// Clears every suspension, making those operations due again.
    ///
    /// The store's own `rearmDelivery(operationID:)` does the work and is already covered by the
    /// package's tests; this only exposes it, because without it the acceptance run stops at the first
    /// denial with nothing on screen that can clear it (health-nutrition #103). Re-arming is
    /// deliberately a person pressing a button rather than something a run does on its own, which is
    /// the same reasoning the store gives for making the call explicit.
    func rearmSuspended() {
        guard !isBusy, !suspendedIDs.isEmpty else { return }
        let targets = suspendedIDs.sorted()
        var failures: [String] = []
        for operationID in targets {
            do {
                try store.rearmDelivery(operationID: operationID)
            } catch {
                failures.append("\(operationID): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            rearmSummary = "Re-armed \(targets.count) suspended operation(s); run delivery again."
        } else {
            rearmSummary = "Re-arm failed for \(failures.count) of \(targets.count): "
                + failures.joined(separator: "; ")
        }
        refresh()
    }

    /// Re-read the queue, so the counts are correct after a change made anywhere in the app.
    func refresh() {
        do {
            let operations = try store.pendingOutbox().filter { $0.destination == .healthKit }
            let needingAttention = try Self.needsAttentionCount(store: store, operations: operations)
            let parked = try store.suspendedOperationIDs()
            suspendedIDs = parked
            counts = Counts(pending: operations.count, needsAttention: needingAttention, suspended: parked.count)
            readError = nil
        } catch {
            counts = .none
            suspendedIDs = []
            readError = "the queue could not be read: \(error.localizedDescription)"
        }
    }

    // MARK: - Counting

    /// How many current projections are left in `needsAttention` for HealthKit.
    ///
    /// Read off the projections rather than off the suspended operations, because the two answer
    /// different questions: a suspension belongs to the operation that failed, while the projection is
    /// what an entry shows. Both are reported, so the difference between them stays visible.
    private static func needsAttentionCount(
        store: any JournalDeliverySuspension, operations: [OutboxOperation]
    ) throws -> Int {
        // Deleted intakes are not in `activeIntakes()`, so the queued operations bring their ids in too:
        // a retraction that is parked still has to be counted.
        var intakeIDs = Set(try store.activeIntakes().map(\.id))
        for operation in operations { intakeIDs.insert(operation.intakeID) }
        var count = 0
        for intakeID in intakeIDs {
            let marked = try store.projections(of: intakeID).filter {
                $0.destination == .healthKit && $0.isCurrent && $0.state == .needsAttention
            }
            count += marked.count
        }
        return count
    }

    // MARK: - Reporting

    /// One outcome in plain text, naming the operation so a row can be matched to an entry.
    ///
    /// Every case is spelled out rather than falling through to a default, so a case added to
    /// `HealthKitDeliveryOutcome` has to be given a wording here instead of printing nothing.
    static func line(for outcome: HealthKitDeliveryOutcome) -> String {
        switch outcome {
        case .delivered(let operationID, let samples):
            return "delivered \(operationID): \(samples) sample(s) written"
        case .retracted(let operationID, let samples):
            return "retracted \(operationID): \(samples) sample(s) removed"
        case .partlyRetracted(let operationID, let samples, let denied):
            return "partly retracted \(operationID): \(samples) removed, still in Health for "
                + denied.sorted().joined(separator: ", ")
        case .superseded(let operationID):
            return "superseded \(operationID): nothing was written for it"
        case .notDue(let operationID, let nextAttemptAt):
            return "not due \(operationID): due again at \(stamp(nextAttemptAt))"
        case .blocked(let operationID, let blockedBy):
            return "blocked \(operationID): waiting for \(blockedBy)"
        case .needsAttention(let operationID, let reason):
            return "needs attention \(operationID): \(reason)"
        case .retryScheduled(let operationID, let nextAttemptAt, let reason):
            return "retry scheduled \(operationID): \(reason); next attempt at \(stamp(nextAttemptAt))"
        case .notAcknowledged(let operationID, let detail):
            return "not acknowledged \(operationID): \(detail)"
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The DEBUG section that drives the real writer: request access, run a delivery pass, and read the
/// queue. It sits at the top of the debug tab, above the spike's own steps, because everything here is
/// about the app's real entries while the spike below it is about synthetic samples.
struct HealthKitDeliveryDebugSection: View {
    let status: HealthKitDeliveryStatus

    var body: some View {
        Section("Health delivery (debug)") {
            Text(status.summaryLine)
                .font(.footnote)
            if let readError = status.readError {
                Text(readError)
                    .font(.footnote)
            }
            if let lastRunAt = status.lastRunAt {
                Text("Last run \(lastRunAt.formatted(date: .omitted, time: .shortened)):")
                    .font(.footnote)
                if status.lastRunLines.isEmpty {
                    Text("Nothing was due.")
                        .font(.footnote)
                }
                ForEach(status.lastRunLines, id: \.self) { line in
                    Text(line).font(.footnote.monospaced())
                }
            } else {
                Text("No delivery run yet in this launch.")
                    .font(.footnote)
            }
            Button("Request Health access for all mapped types") {
                Task { await status.requestAuthorizationForMappedTypes() }
            }
            .disabled(!status.canAct)
            Button("Run Health delivery now") {
                Task { await status.run() }
            }
            .disabled(!status.canAct)
            if status.canRearmSuspended {
                Button("Re-arm suspended deliveries") {
                    Task { status.rearmSuspended() }
                }
                .disabled(!status.canAct)
                Text("A suspended delivery is not retried by any run. Clear it, then run delivery again.")
                    .font(.footnote)
            }
            if let rearmSummary = status.rearmSummary {
                Text(rearmSummary)
                    .font(.footnote)
            }
            Text(status.authorizationSummary)
                .font(.footnote)
        }
    }
}
#endif