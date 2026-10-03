#if DEBUG
import Foundation
import HealthKit
import Observation
import SwiftUI
import UIKit
import os

/// A DEBUG-only screen that measures how HealthKit ACTUALLY behaves when the same sync
/// identifier is saved again with a higher, an equal and a lower sync version.
///
/// NC-07's real HealthKit writer must follow the measured behaviour, not the documentation, so
/// this spike runs on a device once: write synthetic samples, record which sample UUIDs survive
/// each save, then delete the samples this app wrote. Only those are deleted: the delete is
/// filtered on `HKSource.default()`, so a sample written by another app is left alone.
///
/// Every line is also logged with `Logger`, so the results are readable from the device console,
/// and the whole transcript can be copied to the clipboard for pasting into
/// `docs/adr/0002-healthkit-sync.md`.
///
/// The whole file is behind `#if DEBUG`, so no Release build of the app contains this code.
@MainActor
@Observable
final class HealthKitSpikeRunner {
    /// One line per action and its result, shown on screen and copied as a single transcript.
    private(set) var lines: [String] = []

    /// True while a step is in flight, so a button cannot be tapped twice.
    private(set) var isBusy = false

    /// What the authorization request reported, as far as HealthKit is willing to say.
    private(set) var authorizationSummary = "not requested"

    private let store = HKHealthStore()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HealthNutrition", category: "HealthKitSpike")

    /// A fixed spike identifier, so a re-run targets the same samples. Synthetic amounts only:
    /// nothing here is anyone's real intake.
    private static let spikeSyncIdentifier = "dev.example.healthnutrition.spike.nc06"
    private static let initialSyncVersion = 1

    private static let waterType = HKQuantityType(.dietaryWater)
    private static let proteinType = HKQuantityType(.dietaryProtein)

    /// The transcript, for the clipboard.
    var transcript: String {
        (["HealthKit write spike (synthetic samples)"] + lines).joined(separator: "\n")
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
                let processed = try await self.store.requestAuthorization(
                    toShare: [Self.waterType, Self.proteinType],
                    read: [Self.waterType, Self.proteinType]
                )
                // `processed` says the request ran, not that every type was granted; HealthKit
                // deliberately reports nothing more than this.
                self.authorizationSummary = processed ? "requested" : "refused"
                self.record(
                    "authorization requested (write and read: dietaryWater, dietaryProtein), processed: \(processed)"
                )
            } catch {
                self.authorizationSummary = "failed"
                self.record("authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Step 1: save one water sample (250 mL) and one protein sample (10 g), tagged with the
    /// spike sync identifier and sync version 1.
    func saveInitialSamples() async {
        await run {
            self.record(
                "step 1: saving water 250 mL and protein 10 g at syncVersion \(Self.initialSyncVersion)"
            )
            do {
                try await self.store.save(Self.waterSample(syncVersion: Self.initialSyncVersion))
                try await self.store.save(Self.proteinSample(syncVersion: Self.initialSyncVersion))
                self.record("step 1: both samples saved")
            } catch {
                self.record("step 1: save failed: \(error.localizedDescription)")
            }
            await self.recordExistingSamples()
        }
    }

    /// Step 2: save the same sync identifier again with a higher sync version, then report which
    /// UUIDs exist afterwards. The question is whether the old sample is replaced, or whether both
    /// survive.
    func saveHigherVersion() async {
        await run {
            await self.saveWithSyncVersion(
                Self.initialSyncVersion + 1, label: "step 2 (higher version)")
        }
    }

    /// Step 3: save the same sync identifier again with the same version, then with a lower one,
    /// recording the result or error of each. The question is whether HealthKit treats an equal or
    /// a lower version as a conflict, as a no-op, or as a new sample.
    func saveEqualAndLowerVersions() async {
        await run {
            await self.saveWithSyncVersion(
                Self.initialSyncVersion, label: "step 3a (equal version)")
            await self.saveWithSyncVersion(
                Self.initialSyncVersion - 1, label: "step 3b (lower version)")
        }
    }

    /// Step 4: delete the spike samples this app wrote, then report what is left. The query is
    /// scoped to the spike sync identifier and filtered to `HKSource.default()`, so only this
    /// app's own writes are touched.
    func deleteOwnSamples() async {
        await run {
            let mine = await self.ownSpikeSamples()
            if mine.isEmpty {
                self.record("step 4: nothing to delete, no app-owned spike samples found")
            } else {
                do {
                    try await self.store.delete(mine)
                    self.record("step 4: deleted \(mine.count) app-owned spike sample(s)")
                } catch {
                    self.record("step 4: delete failed: \(error.localizedDescription)")
                }
            }
            await self.recordExistingSamples()
        }
    }

    // MARK: - HealthKit work

    private static func waterSample(syncVersion: Int) -> HKQuantitySample {
        quantitySample(
            type: waterType, unit: .literUnit(with: .milli), value: 250, syncVersion: syncVersion)
    }

    private static func proteinSample(syncVersion: Int) -> HKQuantitySample {
        quantitySample(type: proteinType, unit: .gram(), value: 10, syncVersion: syncVersion)
    }

    private static func quantitySample(
        type: HKQuantityType, unit: HKUnit, value: Double, syncVersion: Int
    ) -> HKQuantitySample {
        let now = Date()
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: now,
            end: now,
            metadata: spikeMetadata(syncVersion: syncVersion)
        )
    }

    private static func spikeMetadata(syncVersion: Int) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: spikeSyncIdentifier,
            // HealthKit reads the sync version as a number, so it cannot be a plain Swift Int.
            HKMetadataKeySyncVersion: NSNumber(value: syncVersion),
        ]
    }

    private static func spikePredicate() -> NSPredicate {
        HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            operatorType: .equalTo,
            value: spikeSyncIdentifier
        )
    }

    /// Every sample carrying the spike sync identifier, whichever app wrote it. The delete step
    /// narrows these down to this app's own.
    private func spikeSamples() async -> [HKQuantitySample] {
        var found: [HKQuantitySample] = []
        for type in [Self.waterType, Self.proteinType] {
            let samples: [HKSample] = await withCheckedContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: Self.spikePredicate(),
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, result, _ in
                    continuation.resume(returning: result ?? [])
                }
                store.execute(query)
            }
            found.append(contentsOf: samples.compactMap { $0 as? HKQuantitySample })
        }
        return found
    }

    /// Only the samples this app wrote, matched on `HKSource`. A sample from another app, or one
    /// written by another device of this app, is left alone.
    private func ownSpikeSamples() async -> [HKQuantitySample] {
        let all = await spikeSamples()
        return all.filter { $0.sourceRevision.source == HKSource.default() }
    }

    private func saveWithSyncVersion(_ version: Int, label: String) async {
        guard version >= 1 else {
            record("\(label): skipped, a sync version below 1 is not meaningful")
            return
        }
        do {
            try await store.save(Self.waterSample(syncVersion: version))
            try await store.save(Self.proteinSample(syncVersion: version))
            record("\(label): save accepted")
        } catch {
            record("\(label): save failed: \(error.localizedDescription)")
        }
        await recordExistingSamples()
    }

    // MARK: - Results

    /// Log every sample that exists for the spike sync identifier, with its UUID, sync version,
    /// timestamps and source, so a replaced sample shows up as a changed UUID.
    private func recordExistingSamples() async {
        let samples = await spikeSamples()
        if samples.isEmpty {
            record("existing spike samples: none")
            return
        }
        record("existing spike samples: \(samples.count)")
        for sample in samples.sorted(by: { $0.startDate < $1.startDate }) {
            record(
                "  \(sample.type.identifier) \(sample.quantity)"
                    + " uuid=\(sample.uuid.uuidString)"
                    + " syncVersion=\(syncVersion(of: sample))"
                    + " start=\(stamp(sample.startDate))"
                    + " end=\(stamp(sample.endDate))"
                    + " source=\(sample.sourceRevision.source.bundleIdentifier)"
                    + " product=\(sample.sourceRevision.product)"
                    + " own=\(sample.sourceRevision.source == HKSource.default())"
            )
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

    private func record(_ line: String) {
        logger.info("\(line, privacy: .public)")
        lines.append(line)
    }

    /// Keeps `isBusy` honest for a step, whatever it does.
    private func run(_ work: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        await work()
        isBusy = false
    }
}

/// The DEBUG-only spike screen: authorization, one button per step, the transcript, and a way to
/// copy it.
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
                    Button("1. Save water 250 mL and protein 10 g") {
                        Task { await runner.saveInitialSamples() }
                    }
                    Button("2. Save again with a higher sync version") {
                        Task { await runner.saveHigherVersion() }
                    }
                    Button("3. Save again with the same and a lower sync version") {
                        Task { await runner.saveEqualAndLowerVersions() }
                    }
                    Button("4. Delete the samples this app wrote") {
                        Task { await runner.deleteOwnSamples() }
                    }
                    .disabled(runner.isBusy)
                }

                Section("Results") {
                    if runner.lines.isEmpty {
                        Text("No results yet.").foregroundStyle(.secondary)
                    }
                    ForEach(runner.lines, id: \.self) { line in
                        Text(line).font(.footnote.monospaced())
                    }
                    Button("Copy results") {
                        UIPasteboard.general.string = runner.transcript
                        copied = true
                    }
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
