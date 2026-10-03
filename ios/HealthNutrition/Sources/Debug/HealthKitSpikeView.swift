#if DEBUG
import Foundation
import HealthKit
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
/// NC-07's real HealthKit writer must follow the measured behaviour, not the documentation, so
/// this spike runs on a device once: write synthetic samples, record which sample UUIDs survive
/// each save, then delete the samples this app wrote. Only those are deleted: the delete is
/// filtered on `HKSource.default()`, so a sample written by another app is left alone.
///
/// Water and protein each get their own sync identifier. A sync identifier identifies one piece of
/// data, so sharing one between the two quantities would let their writes resolve against each
/// other and confound the counts the transcript is for.
///
/// Every row is also logged with `Logger`, so the results are readable from the device console,
/// and the whole transcript can be copied to the clipboard for pasting into
/// `docs/adr/0002-healthkit-sync.md`.
///
/// The whole file is behind `#if DEBUG`, so no Release build of the app contains this code.
@MainActor
@Observable
final class HealthKitSpikeRunner {
    /// One row per action and its result, shown on screen and copied as a single transcript.
    private(set) var entries: [SpikeLogEntry] = []

    /// True while a step is in flight. Every button is disabled for as long as this is true, so a
    /// step cannot be silently dropped by tapping it mid-run.
    private(set) var isBusy = false

    /// What the authorization request reported, as far as HealthKit is willing to say.
    private(set) var authorizationSummary = "not requested"

    private let store = HKHealthStore()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HealthNutrition", category: "HealthKitSpike")

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

    /// The transcript, for the clipboard.
    var transcript: String {
        let header = "HealthKit write spike (synthetic samples)"
        return ([header] + entries.map(\.text)).joined(separator: "\n")
    }

    // MARK: - Steps

    /// Ask for write access to the two spike types and read access to the same two, so the spike
    /// can query back what it wrote.
    func requestAuthorization() async {
        await run {
            guard HKHealthStore.isHealthDataAvailable() else {
                self.record("HealthKit is not available on this device.")
                return
            }
            do {
                // The async requestAuthorization returns nothing: it completes once the prompt is
                // done, and HealthKit deliberately never says which types were granted.
                try await self.store.requestAuthorization(
                    toShare: [Self.waterType, Self.proteinType],
                    read: [Self.waterType, Self.proteinType]
                )
                self.authorizationSummary = "requested"
                self.record(
                    "authorization requested (write and read: dietaryWater, dietaryProtein)")
            } catch {
                self.authorizationSummary = "failed"
                self.record("authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Reset: delete any app-owned spike samples left behind by an earlier or interrupted run.
    /// Without this, a leftover version-2 sample would make this run's version 1 a *lower* write
    /// and its version 2 an *equal* one, so the labels in the transcript would be wrong.
    func resetForNewRun() async {
        await run {
            _ = await self.deleteLeftoverSamples(label: "reset")
            await self.recordExistingSamples()
        }
    }

    /// Step 1: save one water sample (250 mL) and one protein sample (10 g), each with its own sync
    /// identifier and sync version 1. It first clears leftovers, so the run starts clean.
    func saveInitialSamples() async {
        await run {
            _ = await self.deleteLeftoverSamples(label: "step 1 preflight")
            self.record(
                "step 1: saving water 250 mL and protein 10 g at syncVersion \(Self.initialSyncVersion)"
            )
            await self.saveAllTargets(syncVersion: Self.initialSyncVersion, label: "step 1")
        }
    }

    /// Step 2: save each sync identifier again with a higher sync version, then report which UUIDs
    /// exist afterwards. The question is whether the old sample is replaced, or whether both
    /// survive.
    func saveHigherVersion() async {
        await run {
            await self.saveAllTargets(
                syncVersion: Self.higherSyncVersion, label: "step 2 (higher version)")
        }
    }

    /// Step 3: save each sync identifier again with the *equal* version (2, which step 2 just
    /// wrote), then with a *lower* one (1), recording the result or error of each save in turn.
    /// The question is whether HealthKit treats an equal or a lower version as a conflict, as a
    /// no-op, or as a new sample.
    func saveEqualAndLowerVersions() async {
        await run {
            await self.saveAllTargets(
                syncVersion: Self.higherSyncVersion,
                label: "step 3a (equal version \(Self.higherSyncVersion))")
            await self.saveAllTargets(
                syncVersion: Self.initialSyncVersion,
                label: "step 3b (lower version \(Self.initialSyncVersion))")
        }
    }

    /// Step 4: delete the spike samples this app wrote, then report what is left. The query is
    /// scoped to the spike sync identifiers and filtered to `HKSource.default()`, so only this
    /// app's own writes are touched.
    func deleteOwnSamples() async {
        await run {
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
        }
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
    /// the first write. Returns the number deleted, or nil if the state could not be established.
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
    /// one quantity cannot hide the other.
    private func saveAllTargets(syncVersion: Int, label: String) async {
        for target in Self.spikeTargets {
            await save(target: target, syncVersion: syncVersion, label: label)
        }
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
            let source = sample.sourceRevision.source.bundleIdentifier
            // `sourceRevision.version` is the source's own revision counter; `productType` is
            // optional and nil for samples HealthKit itself wrote, so it is not what to log here.
            let sourceVersion = sample.sourceRevision.version
            let own = sample.sourceRevision.source == HKSource.default()
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

    private func record(_ text: String) {
        logger.info("\(text, privacy: .public)")
        entries.append(SpikeLogEntry(text: text))
    }

    /// Keeps `isBusy` honest for a step, whatever it does.
    private func run(_ work: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        await work()
        isBusy = false
    }
}

/// The DEBUG-only spike screen: authorization, reset, one button per step, the transcript, and a
/// way to copy it.
struct HealthKitSpikeView: View {
    let runner: HealthKitSpikeRunner

    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Health") {
                    Text("Authorization: \(runner.authorizationSummary)")
                    Button("Request authorization") {
                        Task { await runner.requestAuthorization() }
                    }
                    .disabled(runner.isBusy)
                }

                Section("Steps (synthetic samples)") {
                    Button("Reset: delete leftover samples from an earlier run") {
                        Task { await runner.resetForNewRun() }
                    }
                    .disabled(runner.isBusy)

                    Button("1. Save water 250 mL and protein 10 g") {
                        Task { await runner.saveInitialSamples() }
                    }
                    .disabled(runner.isBusy)

                    Button("2. Save again with a higher sync version") {
                        Task { await runner.saveHigherVersion() }
                    }
                    .disabled(runner.isBusy)

                    Button("3. Save again with the equal, then the lower, sync version") {
                        Task { await runner.saveEqualAndLowerVersions() }
                    }
                    .disabled(runner.isBusy)

                    Button("4. Delete the samples this app wrote") {
                        Task { await runner.deleteOwnSamples() }
                    }
                    .disabled(runner.isBusy)
                }

                Section("Results") {
                    if runner.entries.isEmpty {
                        Text("No results yet.").foregroundStyle(.secondary)
                    }
                    ForEach(runner.entries) { entry in
                        Text(entry.text).font(.footnote.monospaced())
                    }
                    Button("Copy results") {
                        UIPasteboard.general.string = runner.transcript
                        copied = true
                    }
                    .disabled(runner.isBusy)
                    if copied {
                        Text("Copied to the clipboard.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("HealthKit spike")
        }
    }
}
#endif
