import Foundation
import HealthKit
import NutritionDomain
import NutritionJournal
import NutritionUI

/// Reads today's steps and active energy and the person's recent weight from HealthKit, for the
/// activity card on Today. Read access is asked for only when the person taps the card's button, and
/// HealthKit never reports whether it was granted: a type that was refused simply reads as no data.
@MainActor
final class HealthKitReader: BodyActivityReading {
    private let healthStore = HKHealthStore()
    private let defaults: UserDefaults
    /// Versioned with the read set: builds before nutrient reading asked for steps, energy and weight under the
    /// old key only, so their card offers the request again and the nutrient types are asked for once.
    private static let askedKey = "healthKitReader.askedForReadAccess.nutrition"
    private static let legacyAskedKey = "healthKitReader.askedForReadAccess"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.bodyMass)]
        for identifier in OutsideIntakeTotals.readQuantityTypeIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) {
                types.insert(type)
            }
        }
        return types
    }

    var hasAskedForReadAccess: Bool { defaults.bool(forKey: Self.askedKey) }

    /// Erase all data returns the card to its opt-in state: the next read waits for the person again.
    nonisolated static func forgetReadAccess(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.askedKey)
        defaults.removeObject(forKey: Self.legacyAskedKey)
    }

    func requestReadAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
            defaults.set(true, forKey: Self.askedKey)
        } catch {
            // Nothing was asked, so the card keeps offering the button.
        }
    }

    func read(now: Date) async -> BodyActivityReadings {
        guard HKHealthStore.isHealthDataAvailable() else { return .empty }
        let startOfDay = Calendar.current.startOfDay(for: now)
        var readings = BodyActivityReadings()
        readings.steps = await sum(.stepCount, unit: .count(), from: startOfDay, to: now)
        readings.activeEnergyKcal = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: startOfDay, to: now)
        if let outside = await outsideNutrientTotals(from: startOfDay, to: now) {
            readings.outsideNutrients = outside
        } else {
            readings.outsideReadFailed = true
        }
        if let latest = await latestWeight(before: now) {
            readings.latestWeightKg = latest.kilograms
            readings.latestWeightDate = latest.date
            let thirtyDaysEarlier = Calendar.current.date(byAdding: .day, value: -30, to: latest.date) ?? latest.date
            let earlier = await latestWeight(before: thirtyDaysEarlier)
            readings.earlierWeightKg = earlier?.kilograms
            readings.earlierWeightDate = earlier?.date
        }
        return readings
    }

    /// Today's total for a cumulative type, or nil when Health holds none (or reading was refused).
    private func sum(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date
    ) async -> Decimal? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: HKQuantityType(identifier), predicate: predicate),
            options: .cumulativeSum)
        guard let quantity = try? await descriptor.result(for: healthStore)?.sumQuantity() else { return nil }
        return Decimal(quantity.doubleValue(for: unit))
    }

    /// Today's nutrient totals from samples other apps wrote. This app's own samples are flagged by
    /// their source and left out by `OutsideIntakeTotals`, so an entry logged here is never counted twice.
    /// The day's outside totals, or nil when any query fails: a partial total would read as complete.
    private func outsideNutrientTotals(from start: Date, to end: Date) async -> [String: Decimal]? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let own = HKSource.default()
        var samples: [OutsideNutrientSample] = []
        for identifier in OutsideIntakeTotals.readQuantityTypeIdentifiers {
            guard
                let mapping = HealthKitWritePlanner.mappings.first(where: { $0.quantityTypeIdentifier == identifier }),
                let hkUnit = Self.healthKitUnit(for: mapping.unit)
            else { return nil }
            let found: [HKQuantitySample]
            do {
                found = try await HKSampleQueryDescriptor(
                    predicates: [.quantitySample(type: HKQuantityType(HKQuantityTypeIdentifier(rawValue: identifier)), predicate: predicate)],
                    sortDescriptors: []).result(for: healthStore)
            } catch {
                return nil
            }
            for sample in found {
                // Another app may store a sample in international units. Each sample is read in a unit it is
                // compatible with (checked first, so no incompatible conversion is attempted), and IU is passed
                // through so OutsideIntakeTotals restates it. Only a nutrient with a fixed IU amount (vitamin D) is
                // read this way; any other IU sample is skipped here, as any unconvertible sample is.
                let value: Double
                let unit: MeasureUnit
                if sample.quantity.is(compatibleWith: hkUnit) {
                    value = sample.quantity.doubleValue(for: hkUnit)
                    unit = mapping.unit
                } else if mapping.amountPerInternationalUnit != nil, sample.quantity.is(compatibleWith: .internationalUnit()) {
                    value = sample.quantity.doubleValue(for: .internationalUnit())
                    unit = .iu
                } else {
                    continue
                }
                samples.append(OutsideNutrientSample(
                    quantityTypeIdentifier: identifier,
                    value: Decimal(value),
                    unit: unit,
                    isWrittenByThisApp: sample.sourceRevision.source == own))
            }
        }
        return OutsideIntakeTotals.totals(from: samples)
    }

    /// The HealthKit unit for each unit the nutrient table uses. A unit not listed here returns nil, which fails the day's read.
    private static func healthKitUnit(for unit: MeasureUnit) -> HKUnit? {
        switch unit.symbol {
        case "g": return .gram()
        case "mg": return .gramUnit(with: .milli)
        case "mcg": return .gramUnit(with: .micro)
        case "mL": return .literUnit(with: .milli)
        case "kcal": return .kilocalorie()
        default: return nil
        }
    }

    /// The newest weight sample at or before `date`.
    private func latestWeight(before date: Date) async -> (kilograms: Decimal, date: Date)? {
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: date, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        guard let sample = try? await descriptor.result(for: healthStore).first else { return nil }
        return (Decimal(sample.quantity.doubleValue(for: .gramUnit(with: .kilo))), sample.endDate)
    }
}
