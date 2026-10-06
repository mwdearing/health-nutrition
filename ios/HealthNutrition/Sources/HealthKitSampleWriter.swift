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
/// sheet, which ADR 0002 recorded as under-reporting what it granted. Two save failures are not
/// retried, because no retry can succeed: `errorAuthorizationDenied`, which only a person can grant,
/// and `errorInvalidArgument`, which rejects a sample that is rebuilt identically every attempt.
/// Anything else is transient.
struct HealthKitSampleWriter: HealthSampleWriter {
    private let healthStore = HKHealthStore()

    /// Write access per quantity type identifier. A type HealthKit does not know, and a type this app
    /// may not write, are both `false`: in either case the samples would not be written, and a type
    /// that does not resolve needs a person rather than another attempt.
    func canWrite(identifiers: [String]) async -> [String: Bool] {
        var answer: [String: Bool] = [:]
        for identifier in identifiers {
            guard let type = Self.quantityType(for: identifier) else {
                answer[identifier] = false
                continue
            }
            answer[identifier] = healthStore.authorizationStatus(for: type) == .sharingAuthorized
        }
        return answer
    }

    /// The subset of these types the person explicitly denied.
    ///
    /// `canWrite` is false for both a denial and a type Health never asked about (`.notDetermined`),
    /// and a retraction must tell them apart: a denied type keeps the operation for a person, while a
    /// type that was never asked holds nothing and is skipped. Only `.sharingDenied` is denied here; a
    /// type HealthKit does not know resolves to nothing and is not reported either.
    func deniedWriteTypes(identifiers: [String]) async -> Set<String> {
        var denied: Set<String> = []
        for identifier in identifiers {
            guard let type = Self.quantityType(for: identifier) else { continue }
            if healthStore.authorizationStatus(for: type) == .sharingDenied {
                denied.insert(identifier)
            }
        }
        return denied
    }

    /// Saves the whole plan in one call, so a batch either reaches HealthKit or reports why not.
    func save(_ specs: [HealthKitSampleSpec]) async throws {
        let samples = try specs.map { try Self.sample(from: $0) }.compactMap { $0 }
        guard !samples.isEmpty else { return }
        do {
            try await healthStore.save(samples)
        } catch {
            throw Self.classifySaveFailure(error)
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
            guard let type = Self.quantityType(for: Self.typeIdentifier(for: identifier)) else {
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

    /// One spec as an `HKQuantitySample`, or nil when its type does not resolve. Throws when its unit
    /// does not resolve, which is a different thing and cannot be handled by leaving the sample out.
    ///
    /// A spec whose *type* does not resolve is left out rather than written as zero: the journal reads
    /// an absent nutrient as unknown, and a zero would turn "not stated" into "none" in Health. The
    /// worker plans from the same table, so this is a guard against a table HealthKit disagrees with.
    ///
    /// A spec whose *unit* does not resolve is a different thing and **throws**: `HKUnit(from:)` traps
    /// on a string it does not know rather than returning nil, so the symbol is resolved through
    /// `unit(for:)` first. Dropping such a spec would silently write a plan that is missing a nutrient
    /// and then acknowledge the delivery, which is exactly the stale-data failure the planner exists to
    /// prevent — so it is reported as a delivery failure and retried instead.
    private static func sample(from spec: HealthKitSampleSpec) throws -> HKQuantitySample? {
        guard let type = quantityType(for: spec.quantityTypeIdentifier) else { return nil }
        let unit = try unit(for: spec.unitSymbol)
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

    /// The HealthKit unit for a symbol the plan produces, or a delivery failure for anything else.
    ///
    /// `HKUnit(from:)` looks like the obvious way to do this and is not: it is **not** optional and it
    /// traps on a string it does not recognise, so an unknown symbol would take the app down rather
    /// than fail one delivery. The plan's `unitSymbol` is a `MeasureUnit` symbol from a fixed table, so
    /// the five units it can produce are mapped here by hand and anything else is refused.
    ///
    /// Refusing is transient rather than a denial: a symbol this writer does not know means the two
    /// tables disagree, which a later build may well fix, and no amount of retrying here will guess the
    /// right unit. The message names the symbol so the mismatch is visible in the log.
    private static func unit(for symbol: String) throws -> HKUnit {
        switch symbol {
        case "mL": return .literUnit(with: .milli)
        case "g": return .gram()
        case "mg": return .gramUnit(with: .milli)
        case "mcg": return .gramUnit(with: .micro)
        case "kcal": return .kilocalorie()
        default:
            throw HealthSampleWriterError.transient(
                "no HealthKit unit for the symbol the plan produced: \(symbol)")
        }
    }

    /// The quantity type for an identifier string, or nil when HealthKit does not know it.
    ///
    /// `HKQuantityType` is built from `HKQuantityTypeIdentifier(rawValue:)`, because that is the
    /// initializer the SDK actually declares; there is no `HKQuantityType(identifier:)`. A raw value
    /// that no identifier declares gives an `HKQuantityTypeIdentifier` that holds no type, so a nil
    /// result here is a table that disagrees with HealthKit rather than a type to guess at.
    private static func quantityType(for identifier: String) -> HKQuantityType? {
        HKQuantityType(HKQuantityTypeIdentifier(rawValue: identifier))
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

    /// ADR 0002: an authorization denial means "not allowed in Health" on every path. Every other error
    /// is a delivery error worth another attempt, so the worker backs off instead of parking the entry
    /// for a person.
    private static func classify(_ error: Error) -> HealthSampleWriterError {
        guard let healthError = error as? HKError else {
            return .transient(error.localizedDescription)
        }
        if healthError.code == .errorAuthorizationDenied {
            return .authorizationDenied
        }
        return .transient(error.localizedDescription)
    }

    /// A save additionally distinguishes a sample HealthKit will never accept.
    ///
    /// Apple's save contract counts an invalid argument as a save failure, and a retry rebuilds the same
    /// specs from the same immutable journal revision, so the identical sample is rejected identically
    /// every time. Classifying it as transient meant an unfixable entry backed off on a timer forever,
    /// which is the retry storm ADR 0002's suspension exists to prevent.
    ///
    /// **Only on the save path.** Apple defines `errorInvalidArgument` as the app passing an invalid
    /// argument to a HealthKit API, not as a rejected sample, so a query or a deletion reporting it is
    /// not about a sample anybody can correct: there is no immutable plan behind it to edit, and an app
    /// update may well fix the call that made it. Those stay transient, which is the direction a later
    /// fix can recover from — the operation is still queued, unlike one parked behind `needsAttention`.
    private static func classifySaveFailure(_ error: Error) -> Error {
        guard let healthError = error as? HKError, healthError.code == .errorInvalidArgument else {
            return classify(error)
        }
        return HealthSampleRejectedError(reason: "HealthKit rejected a sample as invalid")
    }
}
