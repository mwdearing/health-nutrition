import Foundation
import HealthKit
import NutritionJournal

/// The app target's `HealthSampleWriter`: the only production code that touches HealthKit.
///
/// Everything `NutritionJournal` decides is already settled by the time this runs. The worker hands
/// over a plan of plain data — a quantity type identifier string, an exact decimal amount, a unit,
/// the intake's own timestamps, a sync identifier and a sync version — and this turns each spec into
/// an `HKQuantitySample` with the metadata ADR 0002 measured on a device, saves them, and takes them
/// back again.
///
/// The rules this implements come from that ADR rather than from Apple's documentation:
///
/// - **One sync identifier per (intake, nutrient)**, written as `HKMetadataKeySyncIdentifier`. The
///   plan already built them; nothing here generates or parses one.
/// - **The sync version is the journal revision**, written as `HKMetadataKeySyncVersion`. HealthKit
///   reads it as a number, so it is an `NSNumber` and not a plain `Int`. A higher version replaces
///   the sample, an equal version replaces it again, and a lower one is silently ignored — so a
///   successful save is never taken as proof that the store now holds this revision.
/// - **A delete goes by sync identifier *and* `HKSource.default()`**, so a sample another app wrote
///   under the same identifier is never touched, and nothing is keyed off a sample UUID (every
///   accepted save mints a new one).
///
/// Authorization is read per type with `authorizationStatus(for:)`, not inferred from the permission
/// sheet, which ADR 0002 recorded as under-reporting what it granted. A save that fails with
/// `errorAuthorizationDenied` is the one failure that is not retried; anything else is transient.
struct HealthKitSampleWriter: HealthSampleWriter {
    private let healthStore = HKHealthStore()

    /// Write access per quantity type identifier. A type HealthKit does not know, and a type this app
    /// may not write, are both `false`: in either case the samples would not be written, and a type
    /// that does not resolve needs a person rather than another attempt.
    func canWrite(identifiers: [String]) async -> [String: Bool] {
        var answer: [String: Bool] = [:]
        for identifier in identifiers {
            guard let type = HKQuantityType(identifier: identifier) else {
                answer[identifier] = false
                continue
            }
            answer[identifier] = healthStore.authorizationStatus(for: type) == .sharingAuthorized
        }
        return answer
    }

    /// Saves the whole plan in one call, so a batch either reaches HealthKit or reports why not.
    func save(_ specs: [HealthKitSampleSpec]) async throws {
        let samples = specs.compactMap(Self.sample(from:))
        guard !samples.isEmpty else { return }
        do {
            try await healthStore.save(samples)
        } catch {
            throw Self.classify(error)
        }
    }

    /// Deletes this app's own samples for every sync identifier given, and reports how many went.
    ///
    /// One identifier at a time, because the type each belongs to comes from the mapping table and a
    /// deletion is a query followed by a delete. An identifier whose type does not resolve, or whose
    /// samples are not there, deletes nothing and is not an error: the outcome the worker wanted is
    /// already true.
    func deleteSamples(syncIdentifiers: [String]) async throws -> Int {
        var deleted = 0
        for identifier in syncIdentifiers {
            guard let type = HKQuantityType(identifier: Self.typeIdentifier(for: identifier)) else {
                continue
            }
            do {
                let samples = try await ownSamples(type: type, syncIdentifier: identifier)
                guard !samples.isEmpty else { continue }
                try await healthStore.delete(samples)
                deleted += samples.count
            } catch {
                throw Self.classify(error)
            }
        }
        return deleted
    }

    // MARK: - Samples

    /// One spec as an `HKQuantitySample`, or nil when its type or unit does not resolve.
    ///
    /// A spec that cannot become a sample is left out rather than written as zero: the journal reads
    /// an absent nutrient as unknown, and a zero would turn "not stated" into "none" in Health. The
    /// worker plans from the same table, so this is a guard against a table HealthKit disagrees with.
    private static func sample(from spec: HealthKitSampleSpec) -> HKQuantitySample? {
        guard let type = HKQuantityType(identifier: spec.quantityTypeIdentifier),
              let unit = HKUnit(from: spec.unitSymbol)
        else { return nil }
        return HKQuantitySample(
            type: type,
            // HealthKit quantities are Double; the decimal is converted once, at the boundary, and
            // nowhere else in the app.
            quantity: HKQuantity(unit: unit, doubleValue: NSDecimalNumber(decimal: spec.amount).doubleValue),
            start: spec.start,
            end: spec.end,
            metadata: [
                HKMetadataKeySyncIdentifier: spec.syncIdentifier,
                HKMetadataKeySyncVersion: NSNumber(value: spec.syncVersion),
            ]
        )
    }

    /// The quantity type a sync identifier belongs to, from its trailing nutrient key. A key no row
    /// maps resolves to nothing, so a deletion for it deletes nothing.
    private static func typeIdentifier(for syncIdentifier: String) -> String {
        let key = HealthKitWritePlanner.canonicalKey(for: String(syncIdentifier.split(separator: ":").last ?? ""))
        return HealthKitWritePlanner.mappings.first { $0.nutrientKey == key }?.quantityTypeIdentifier ?? ""
    }

    /// Every sample with this sync identifier that **this app** wrote.
    ///
    /// A failed query throws instead of returning an empty array. An unsuccessful observation must
    /// never be read as "there is nothing to delete", or the delivery would be acknowledged while
    /// the samples are still there — the failure mode ADR 0002's spike was built to avoid.
    private func ownSamples(type: HKQuantityType, syncIdentifier: String) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            operatorType: .equalTo,
            value: syncIdentifier
        )
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result ?? [])
                }
            }
            healthStore.execute(query)
        }
        return samples
            .compactMap { $0 as? HKQuantitySample }
            .filter { $0.sourceRevision.source == HKSource.default() }
    }

    /// ADR 0002: only an authorization denial means "not allowed in Health". Every other error — an
    /// invalid sample, a restriction, a store error — is a delivery error worth another attempt, so
    /// the worker backs off instead of parking the entry for a person.
    private static func classify(_ error: Error) -> HealthSampleWriterError {
        guard let healthError = error as? HKError else {
            return .transient(error.localizedDescription)
        }
        if healthError.code == .errorAuthorizationDenied {
            return .authorizationDenied
        }
        return .transient(error.localizedDescription)
    }
}
