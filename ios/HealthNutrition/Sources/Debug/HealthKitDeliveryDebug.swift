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

    private(set) var counts: Counts = .none
    /// When the last run started, or nil when this launch has not run one.
    private(set) var lastRunAt: Date?
    /// One plain line per operation the last run handled, in the order the worker reported them.
    private(set) var lastRunLines: [String] = []
    /// What the authorization request reported. HealthKit never says which types it granted, so this
    /// says what was asked for rather than pretending to know the answer.
    private(set) var authorizationSummary = "not requested"
    /// True while a request or a delivery run is in flight, so a second tap cannot start a second one.
    private(set) var isBusy = false
    /// Why the counts could not be read, when they could not be.
    private(set) var readError: String?

    /// The one worker the app runs, handed in rather than built again: two workers over one store
    /// would each try to deliver the same operation.
    private let healthKitDelivery: HealthKitDeliveryWorker
    private let store: any JournalDeliverySuspension
    private let healthStore = HKHealthStore()

    init(healthKitDelivery: HealthKitDeliveryWorker, store: any JournalDeliverySuspension) {
        self.healthKitDelivery = healthKitDelivery
        self.store = store
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
    func requestAuthorizationForMappedTypes() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationSummary = "HealthKit is not available on this device"
            return
        }
        var share = Set<HKSampleType>()
        var unresolved: [String] = []
        for mapping in HealthKitWritePlanner.mappings {
            if let type = HKObjectType.quantityType(forIdentifier: mapping.quantityTypeIdentifier) {
                share.insert(type)
            } else {
                unresolved.append(mapping.nutrientKey)
            }
        }
        do {
            // The async request returns nothing: it completes once the sheet is done and HealthKit
            // deliberately never says which types were granted.
            try await healthStore.requestAuthorization(toShare: share, read: [])
            var summary = "requested write access for \(share.count) mapped type(s), no read access"
            if !unresolved.isEmpty {
                summary += "; HealthKit does not know \(unresolved.sorted().joined(separator: ", "))"
            }
            authorizationSummary = summary
        } catch {
            authorizationSummary = "request failed: \(error.localizedDescription)"
        }
    }

    /// One delivery pass, then the counts and the outcome list are read again so the screen shows what
    /// this run did rather than what the one before it did.
    func run(now: Date = Date()) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let outcomes = await healthKitDelivery.runOnce(now: now)
        lastRunAt = now
        lastRunLines = outcomes.map(Self.line(for:))
        refresh()
    }

    /// Re-reads the queue, so the counts are correct after a change made anywhere in the app.
    func refresh() {
        do {
            let operations = try store.pendingOutbox().filter { $0.destination == .healthKit }
            let needingAttention = try Self.needsAttentionCount(store: store, operations: operations)
            let parked = try store.suspendedOperationIDs().count
            counts = Counts(pending: operations.count, needsAttention: needingAttention, suspended: parked)
            readError = nil
        } catch {
            counts = .none
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
            Text(status.authorizationSummary)
                .font(.footnote)
        }
    }
}
#endif