#if DEBUG
import Foundation
import HealthKit
import NutritionCore
import NutritionJournal
import Observation
import SwiftUI
import UIKit
import os

/// One transcript row. Every row gets its own id: rows repeat by design (the sample count is
/// reported again after every save), and a list keyed on the row text would collapse or reuse them.
struct SpikeLogEntry: Identifiable {
    let id: UUID
    let text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
    }
}

/// A DEBUG-only screen that measures how HealthKit ACTUALLY behaves when the same sync
/// identifier is saved again with a higher, an equal and a lower sync version.
///
/// NC-07's real HealthKit writer must follow the measured behavior, not the documentation, so
/// this spike runs on a device once: write synthetic samples, record which sample UUIDs survive
/// each save, then delete the samples this app wrote. Only those are deleted: the delete is
/// filtered on `HKSource.default()`, so a sample written by another app is left alone.
///
/// Water and protein each get their own sync identifier. A sync identifier identifies one piece of
/// data, so sharing one between the two quantities would let their writes resolve against each
/// other and confound the counts the transcript is for.
///
/// The steps are gated on a tracked phase, in the order authorize, version 1, version 2 (higher),
/// equal then lower, delete. An out-of-order step would make a later label describe the wrong
/// operation, so a step is only enabled once its prerequisite succeeded. Reset re-locks the whole
/// sequence.
///
/// Every row is also logged with `Logger`, so the results are readable from the device console, and
/// **Copy results** puts a redacted transcript on the clipboard, ready for pasting into
/// `docs/adr/0002-healthkit-sync.md` without leaking local deployment details.
///
/// The whole file is behind `#if DEBUG`, so no Release build of the app contains this code.
@MainActor
@Observable
final class HealthKitSpikeRunner {
    /// How far this run has got. Each step is enabled only when the phase matches its prerequisite,
    /// so the experiment cannot be run out of order.
    enum Phase: Int, Comparable {
        /// Nothing done yet: Health access has not been granted.
        case needsAuthorization
        /// Health access requested, store is clean: version 1 may be written.
        case readyForVersionOne
        /// Version 1 written: the higher-version write may follow.
        case savedVersionOne
        /// Version 2 written: the equal and lower writes may follow.
        case savedVersionTwo
        /// Equal and lower writes done: the samples may be deleted.
        case savedEqualAndLower
        /// The run finished with the delete.
        case finished

        static func < (lhs: Phase, rhs: Phase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One row per action and its result, shown on screen and copied as a single transcript.
    private(set) var entries: [SpikeLogEntry] = []

    /// True while a step is in flight. Every button is disabled for as long as this is true, so a
    /// step cannot be silently dropped by tapping it mid-run.
    private(set) var isBusy = false

    /// How far the current run has got. Reset and delete put it back to the start of the sequence.
    private(set) var phase: Phase = .needsAuthorization

    /// What the authorization request reported, as far as HealthKit is willing to say.
    private(set) var authorizationSummary = "not requested"

    /// Whether Health access has been granted in this app session. Sticky across resets: HealthKit
    /// remembers the grant, so a reset must not send the operator back through the prompt.
    private var hasAuthorization = false

    private let store = HKHealthStore()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HealthNutrition", category: "HealthKitSpike")

    /// The real delivery status, told once access has been asked for. Optional so the spike can be run
    /// on its own; the app hands it the one status the debug section also shows.
    private let deliveryStatus: HealthKitDeliveryStatus?

    init(deliveryStatus: HealthKitDeliveryStatus? = nil) {
        self.deliveryStatus = deliveryStatus
    }

    /// The namespace for the spike's sync identifiers. Fixed, so a re-run targets the same samples.
    /// Synthetic amounts only: nothing here is anyone's real intake.
    private static let syncIdentifierNamespace = "dev.example.healthnutrition.spike.nc06"

    /// Step 1 writes version 1, step 2 writes version 2 (higher), and step 3 then writes version 2
    /// again (equal) and version 1 (lower).
    private static let initialSyncVersion = 1
    private static let higherSyncVersion = 2

    /// One logical sample: a quantity type and the sync identifier for that sequence alone.
    private struct SpikeTarget {
        let label: String
        let type: HKQuantityType
        let unit: HKUnit
        let value: Double
        let syncIdentifier: String
    }

    private static let waterType = HKQuantityType(.dietaryWater)
    private static let proteinType = HKQuantityType(.dietaryProtein)

    /// Water and protein deliberately carry different sync identifiers, so each sequence measures
    /// one logical sample on its own.
    private static let waterTarget = SpikeTarget(
        label: "water",
        type: waterType,
        unit: .literUnit(with: .milli),
        value: 250,
        syncIdentifier: syncIdentifierNamespace + ".water"
    )
    private static let proteinTarget = SpikeTarget(
        label: "protein",
        type: proteinType,
        unit: .gram(),
        value: 10,
        syncIdentifier: syncIdentifierNamespace + ".protein"
    )
    private static let spikeTargets = [waterTarget, proteinTarget]

    /// The transcript for the clipboard, with the local bundle identifier and device name redacted
    /// so it can be pasted into the public repository as it stands.
    var transcript: String {
        let header = "HealthKit write spike (synthetic samples, bundle id and device name redacted)"
        return ([header] + entries.map(\.text)).joined(separator: "\n")
    }

    // MARK: - Step availability

    /// True when the operator may request authorization: any time nothing else is running.
    var canRequestAuthorization: Bool { !isBusy }

    /// True when the operator may reset: any time nothing else is running. Reset is always allowed
    /// because it is how a run is abandoned and started over.
    var canReset: Bool { !isBusy }

    /// Version 1 needs Health access first.
    var canSaveInitialSamples: Bool { !isBusy && phase == .readyForVersionOne }

    /// The higher-version write means nothing unless version 1 is already in the store.
    var canSaveHigherVersion: Bool { !isBusy && phase == .savedVersionOne }

    /// "Equal" is only equal to the version 2 that step 2 wrote.
    var canSaveEqualAndLowerVersions: Bool { !isBusy && phase == .savedVersionTwo }

    /// The delete is the last step of the run.
    var canDeleteOwnSamples: Bool { !isBusy && phase == .savedEqualAndLower }

    // MARK: - Steps

    /// Ask for write and read access to **every** type the planner maps, not only the two this spike
    /// writes.
    ///
    /// The spike measures sync-identifier behavior using water and protein, but the real writer
    /// writes whatever the planner maps, and a request that names only the spike's two leaves the
    /// rest `.notDetermined`: the writer reads that as denied, the worker parks those operations, and
    /// nothing re-arms them — which is exactly what the owner's device run saw, with only water and
    /// protein ever written. Read access is asked for the same set so the spike can still query back
    /// what it wrote.
    ///
    /// On success the real delivery status is told, so anything parked for the missing request is
    /// re-armed and one pass runs rather than waiting for the next app trigger.
    func requestAuthorization() async {
        await run {
            guard HKHealthStore.isHealthDataAvailable() else {
                self.record("HealthKit is not available on this device.")
                return
            }
            let mapped = HealthKitDeliveryStatus.mappedTypes()
            do {
                // The async requestAuthorization returns nothing: it completes once the prompt is
                // done, and HealthKit deliberately never says which types were granted.
                // Write access for every mapped type, because that is what delivery writes; read access
                // only for the two types this screen reads back, because that is all it reads and all the
                // usage description promises.
                try await self.store.requestAuthorization(
                    toShare: mapped.share, read: [Self.waterType, Self.proteinType])
                self.authorizationSummary = "requested"
                self.hasAuthorization = true
                self.record(
                    "authorization requested (write: "
                        + self.requestedIdentifiers(mapped).joined(separator: ", ")
                        + "; read: dietaryWater, dietaryProtein)")
                if !mapped.unresolved.isEmpty {
                    self.record(
                        "HealthKit does not know these mapped types: "
                            + mapped.unresolved.sorted().joined(separator: ", "))
                }
                await self.deliveryStatus?.authorizationRequested()
                await self.openRun(clearTranscript: false)
            } catch {
                self.authorizationSummary = "failed"
                self.record("authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// The identifiers asked for, in the order the planner's table lists them, so the transcript says
    /// exactly what Health was shown rather than a count.
    private func requestedIdentifiers(_ mapped: HealthKitDeliveryStatus.MappedTypes) -> [String] {
        let resolved = Set(mapped.share.map(\.identifier))
        return HealthKitWritePlanner.mappings.compactMap { mapping in
            resolved.contains(mapping.quantityTypeIdentifier) ? mapping.quantityTypeIdentifier : nil
        }
    }

    /// Reset: delete any app-owned spike samples left behind by an earlier or interrupted run, clear
    /// the transcript and re-lock the step sequence. Without the delete, a leftover version-2 sample
    /// would make this run's version 1 a *lower* write and its version 2 an *equal* one, so every
    /// label in the transcript would be wrong.
    func resetForNewRun() async {
        await run {
            _ = await self.deleteLeftoverSamples(label: "reset")
            await self.openRun(clearTranscript: true)
        }
    }

    /// Step 1: save one water sample (250 mL) and one protein sample (10 g), each with its own sync
    /// identifier and sync version 1.
    ///
    /// This also starts a fresh run: the transcript is cleared and leftovers are deleted first. If
    /// that cleanup cannot be confirmed, step 1 records the failure and does **not** write, because
    /// an unknown starting state makes every later label wrong and would add samples to an
    /// experiment already in doubt.
    func saveInitialSamples() async {
        await run {
            guard self.phase == .readyForVersionOne else {
                self.record("step 1: skipped, not the next step in the sequence")
                return
            }
            await self.openRun(clearTranscript: true)
            guard await self.deleteLeftoverSamples(label: "step 1 preflight") != nil else {
                self.record("step 1: ABORTED, the store was not confirmed empty, so nothing was written")
                return
            }
            self.record(
                "step 1: saving water 250 mL and protein 10 g at syncVersion \(Self.initialSyncVersion)"
            )
            await self.saveAllTargets(
                syncVersion: Self.initialSyncVersion, label: "step 1", next: .savedVersionOne)
        }
    }

    /// Step 2: save each sync identifier again with a higher sync version, then report which UUIDs
    /// exist afterwards. The question is whether the old sample is replaced, or whether both
    /// survive.
    func saveHigherVersion() async {
        await run {
            guard self.phase == .savedVersionOne else {
                self.record("step 2: skipped, run step 1 first")
                return
            }
            await self.saveAllTargets(
                syncVersion: Self.higherSyncVersion, label: "step 2 (higher version)",
                next: .savedVersionTwo)
        }
    }

    /// Step 3: save each sync identifier again with the *equal* version (2, which step 2 just
    /// wrote), then with a *lower* one (1), recording the result or error of each save in turn.
    /// The question is whether HealthKit treats an equal or a lower version as a conflict, as a
    /// no-op, or as a new sample.
    func saveEqualAndLowerVersions() async {
        await run {
            guard self.phase == .savedVersionTwo else {
                self.record("step 3: skipped, run step 2 first")
                return
            }
            await self.saveAllTargets(
                syncVersion: Self.higherSyncVersion,
                label: "step 3a (equal version \(Self.higherSyncVersion))",
                next: .savedEqualAndLower)
            await self.saveAllTargets(
                syncVersion: Self.initialSyncVersion,
                label: "step 3b (lower version \(Self.initialSyncVersion))",
                next: .savedEqualAndLower)
        }
    }

    /// Step 4: delete the spike samples this app wrote, then report what is left. The query is
    /// scoped to the spike sync identifiers and filtered to `HKSource.default()`, so only this
    /// app's own writes are touched.
    func deleteOwnSamples() async {
        await run {
            guard self.phase == .savedEqualAndLower else {
                self.record("step 4: skipped, run step 3 first")
                return
            }
            do {
                let mine = try await self.ownSpikeSamples()
                if mine.isEmpty {
                    self.record("step 4: nothing to delete, no app-owned spike samples found")
                } else {
                    try await self.store.delete(mine)
                    self.record("step 4: deleted \(mine.count) app-owned spike sample(s)")
                }
            } catch {
                self.record("step 4: FAILED, whether anything was deleted is unknown: \(error.localizedDescription)")
            }
            await self.recordExistingSamples()
            // The run is over: re-lock the sequence so a stray tap cannot reuse the phase.
            self.phase = .finished
        }
    }

    // MARK: - Run bookkeeping

    /// Put the sequence back to its first experimental step and show what is in the store now.
    ///
    /// `clearTranscript` is used when a new run begins: a transcript that mixes two runs has counts
    /// and UUID transitions that cannot be attributed to one experiment.
    private func openRun(clearTranscript: Bool) async {
        if clearTranscript {
            entries.removeAll()
        }
        phase = hasAuthorization ? .readyForVersionOne : .needsAuthorization
        await recordExistingSamples()
    }

    // MARK: - HealthKit work

    private static func quantitySample(
        target: SpikeTarget, syncVersion: Int
    ) -> HKQuantitySample {
        let now = Date()
        return HKQuantitySample(
            type: target.type,
            quantity: HKQuantity(unit: target.unit, doubleValue: target.value),
            start: now,
            end: now,
            metadata: spikeMetadata(target: target, syncVersion: syncVersion)
        )
    }

    private static func spikeMetadata(
        target: SpikeTarget, syncVersion: Int
    ) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: target.syncIdentifier,
            // HealthKit reads the sync version as a number, so it cannot be a plain Swift Int.
            HKMetadataKeySyncVersion: NSNumber(value: syncVersion),
        ]
    }

    private static func spikePredicate(syncIdentifier: String) -> NSPredicate {
        HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            operatorType: .equalTo,
            value: syncIdentifier
        )
    }

    /// Every sample carrying one of the spike sync identifiers, whichever app wrote it.
    ///
    /// A failed query throws instead of returning an empty array: an unsuccessful observation must
    /// never be recorded as "the store is empty", or it can be copied into the ADR as an apparent
    /// dedupe or delete result.
    private func spikeSamples() async throws -> [HKQuantitySample] {
        var found: [HKQuantitySample] = []
        for target in Self.spikeTargets {
            let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: target.type,
                    predicate: Self.spikePredicate(syncIdentifier: target.syncIdentifier),
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result ?? [])
                    }
                }
                store.execute(query)
            }
            found.append(contentsOf: samples.compactMap { $0 as? HKQuantitySample })
        }
        return found
    }

    /// Only the samples this app wrote, matched on `HKSource`. A sample from another app, or one
    /// written by another device of this app, is left alone.
    private func ownSpikeSamples() async throws -> [HKQuantitySample] {
        let all = try await spikeSamples()
        return all.filter { $0.sourceRevision.source == HKSource.default() }
    }

    /// Delete any app-owned spike samples from an earlier run, so this run's version 1 really is
    /// the first write. Returns the number deleted, or nil if the clean state could not be
    /// established, which the caller must treat as "do not write".
    private func deleteLeftoverSamples(label: String) async -> Int? {
        do {
            let mine = try await ownSpikeSamples()
            if mine.isEmpty {
                record("\(label): no leftover app-owned spike samples found")
                return 0
            }
            try await store.delete(mine)
            record("\(label): deleted \(mine.count) leftover app-owned spike sample(s) from an earlier run")
            return mine.count
        } catch {
            record(
                "\(label): leftover cleanup FAILED, the counts in this transcript cannot be trusted: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Save both spike targets at `syncVersion` and record each save separately, so a failure on
    /// one quantity cannot hide the other. `next` is the phase this step unlocks.
    private func saveAllTargets(syncVersion: Int, label: String, next: Phase) async {
        for target in Self.spikeTargets {
            await save(target: target, syncVersion: syncVersion, label: label)
        }
        phase = next
        await recordExistingSamples()
    }

    private func save(target: SpikeTarget, syncVersion: Int, label: String) async {
        do {
            let sample = Self.quantitySample(target: target, syncVersion: syncVersion)
            try await store.save(sample)
            record(
                "\(label): saved \(target.label) \(sample.quantity) syncVersion=\(syncVersion) uuid=\(sample.uuid.uuidString)"
            )
        } catch {
            record(
                "\(label): save of \(target.label) at syncVersion=\(syncVersion) failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Results

    /// Log every sample that exists for the spike sync identifiers, with its UUID, sync version,
    /// timestamps and source, so a replaced sample shows up as a changed UUID.
    private func recordExistingSamples() async {
        let samples: [HKQuantitySample]
        do {
            samples = try await spikeSamples()
        } catch {
            record(
                "existing spike samples: QUERY FAILED, the store is NOT known to be empty: \(error.localizedDescription)"
            )
            return
        }
        if samples.isEmpty {
            record("existing spike samples: none")
            return
        }
        record("existing spike samples: \(samples.count)")
        for sample in samples.sorted(by: { $0.startDate < $1.startDate }) {
            // Each field is bound to its own `let` and the line is one interpolation: a long chain
            // of concatenations here is slow for the type checker to resolve.
            let id = sample.uuid.uuidString
            let sync = syncVersion(of: sample)
            // `sourceRevision.version` is the source's own revision counter; `productType` is
            // optional and nil for samples HealthKit itself wrote, so it is not what to log here.
            let sourceVersion = sample.sourceRevision.version
            let own = sample.sourceRevision.source == HKSource.default()
            // The source is never printed: on a sideloaded build its bundle identifier can differ from
            // Bundle.main's (case or a signing-tool suffix), so text redaction would miss it. "this
            // app" or "another app" is all the transcript needs.
            let source = own ? "this app" : "another app"
            record("  \(sample.sampleType.identifier) \(sample.quantity) uuid=\(id) syncVersion=\(sync) start=\(stamp(sample.startDate)) end=\(stamp(sample.endDate)) source=\(source) sourceVersion=\(sourceVersion) own=\(own)")
        }
    }

    private func syncVersion(of sample: HKQuantitySample) -> String {
        guard let version = sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber else {
            return "none"
        }
        return version.intValue.description
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Replace the local deployment details with placeholders, so a transcript copied off the phone
    /// can go into the public repository without carrying a private bundle identifier or the
    /// operator's device name.
    private func redact(_ text: String) -> String {
        // The tested implementation lives in NutritionCore (TranscriptRedactionTests).
        TranscriptRedaction.redact(
            text, bundleIdentifier: Bundle.main.bundleIdentifier, deviceName: UIDevice.current.name)
    }

    private func record(_ text: String) {
        let redacted = redact(text)
        logger.info("\(redacted, privacy: .public)")
        entries.append(SpikeLogEntry(text: redacted))
    }

    /// Keeps `isBusy` honest for a step, whatever it does.
    private func run(_ work: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        await work()
        isBusy = false
    }
}

/// The DEBUG-only spike sections: authorization, reset, one button per step, the transcript, and a
/// way to copy it. Each step is enabled only once its prerequisite has succeeded.
///
/// Sections rather than a screen of its own, so the HealthKit tab can show the real delivery driver
/// (`HealthKitDeliveryDebugSection`) above these synthetic-sample steps in one list. Nothing about the
/// experiment changed: it still writes its own two samples under its own sync identifiers, separate from
/// anything the app's real writer does with real entries.
struct HealthKitSpikeSteps: View {
    let runner: HealthKitSpikeRunner

    @State private var copied = false

    /// What to tell the operator to do next, derived from the completed phase.
    private var nextStep: String {
        switch runner.phase {
        case .needsAuthorization: return "Request Health access to begin."
        case .readyForVersionOne: return "Run step 1."
        case .savedVersionOne: return "Run step 2."
        case .savedVersionTwo: return "Run step 3."
        case .savedEqualAndLower: return "Run step 4, then reset for the next run."
        case .finished: return "Run finished. Copy the results, or reset."
        }
    }

    var body: some View {
        Group {
            Section("Health") {
                Text("Authorization: \(runner.authorizationSummary)")
                Text("Next: \(nextStep)")
                Button("Request authorization") {
                    Task { await runner.requestAuthorization() }
                }
                .disabled(!runner.canRequestAuthorization)
            }

            Section("Steps (synthetic samples)") {
                Button("Reset: clear the transcript and delete leftover samples") {
                    Task { await runner.resetForNewRun() }
                }
                .disabled(!runner.canReset)

                Button("1. Save water 250 mL and protein 10 g") {
                    Task { await runner.saveInitialSamples() }
                }
                .disabled(!runner.canSaveInitialSamples)

                Button("2. Save again with a higher sync version") {
                    Task { await runner.saveHigherVersion() }
                }
                .disabled(!runner.canSaveHigherVersion)

                Button("3. Save again with the equal, then the lower, sync version") {
                    Task { await runner.saveEqualAndLowerVersions() }
                }
                .disabled(!runner.canSaveEqualAndLowerVersions)

                Button("4. Delete the samples this app wrote") {
                    Task { await runner.deleteOwnSamples() }
                }
                .disabled(!runner.canDeleteOwnSamples)
            }

            Section("Results") {
                if runner.entries.isEmpty {
                    Text("No results yet.").foregroundStyle(.secondary)
                }
                ForEach(runner.entries) { entry in
                    Text(entry.text).font(.footnote.monospaced())
                }
                Button("Copy results (redacted)") {
                    UIPasteboard.general.string = runner.transcript
                    copied = true
                }
                if copied {
                    Text("Copied, with the bundle id and device name redacted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
