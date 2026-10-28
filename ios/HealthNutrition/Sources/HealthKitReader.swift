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
    /// Versioned with the read set: a person asked under an earlier set (before nutrient reading, then before
    /// height) has only the old key, so their card offers the request again and the new types are asked for once.
    private static let askedKey = "healthKitReader.askedForReadAccess.height"
    private static let legacyAskedKeys = [
        "healthKitReader.askedForReadAccess", "healthKitReader.askedForReadAccess.nutrition",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.bodyMass),
        ]
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
        for key in Self.legacyAskedKeys { defaults.removeObject(forKey: key) }
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
        readings.outsideRead = true
        let outside = await outsideNutrientTotals(from: startOfDay, to: now)
        readings.outsideNutrients = outside.totals
        readings.outsideReadKeys = outside.readKeys
        readings.outsideReadFailed = outside.failed
        if let latest = await latestWeight(before: now) {
            readings.latestWeightKg = latest.kilograms
            readings.latestWeightDate = latest.date
        }
        readings.latestHeightCm = await latestHeightCentimeters(before: now)
        let weightWindowStart = Calendar.current.date(byAdding: .day, value: -27, to: startOfDay) ?? startOfDay
        readings.weightSamples = await weightSamples(from: weightWindowStart, to: now)
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
    /// The day's outside totals per nutrient. A query that succeeds marks its nutrient as read, so an empty
    /// result is a known zero; a query that fails (or cannot be mapped) leaves its nutrient unread, and `failed`
    /// is set. Other nutrients still report, so one failed type does not make the whole day unknown.
    private func outsideNutrientTotals(from start: Date, to end: Date) async -> OutsideIntakeReading {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let own = HKSource.default()
        var queries: [OutsideQuery] = []
        for identifier in OutsideIntakeTotals.readQuantityTypeIdentifiers {
            let plan = OutsideIntakeTotals.readPlan(for: identifier, unitIsReadable: { Self.healthKitUnit(for: $0) != nil })
            guard case .read(let key, let unit, let hasIUFactor) = plan else {
                if case .unreadable(let key) = plan {
                    queries.append(OutsideQuery(nutrientKey: key, outcome: .failed))
                }
                continue
            }
            // readPlan and this lookup share one predicate, so this is a safe fallback, not a path a read takes today:
            // a nutrient with no HealthKit unit is recorded as failed under its own key, never dropped.
            guard let hkUnit = Self.healthKitUnit(for: unit) else {
                queries.append(OutsideQuery(nutrientKey: key, outcome: .failed))
                continue
            }
            let found: [HKQuantitySample]
            do {
                found = try await HKSampleQueryDescriptor(
                    predicates: [.quantitySample(type: HKQuantityType(HKQuantityTypeIdentifier(rawValue: identifier)), predicate: predicate)],
                    sortDescriptors: []).result(for: healthStore)
            } catch {
                queries.append(OutsideQuery(nutrientKey: key, outcome: .failed))
                continue
            }
            // Another app may store a sample in international units. Each sample is read in a unit it is compatible
            // with (checked first, so no incompatible conversion is attempted). IU is passed through only for a
            // nutrient with a fixed IU amount (vitamin D); any other sample is unconvertible.
            let outcomes: [OutsideSampleOutcome] = found.map { sample in
                guard let converted = Self.sampleValue(sample.quantity, hkUnit: hkUnit, unit: unit, hasIUFactor: hasIUFactor) else {
                    return .unconvertible
                }
                let (value, sampleUnit) = converted
                return .sample(OutsideNutrientSample(
                    quantityTypeIdentifier: identifier,
                    value: Decimal(value),
                    unit: sampleUnit,
                    isWrittenByThisApp: sample.sourceRevision.source == own))
            }
            queries.append(OutsideQuery(nutrientKey: key, outcome: .samples(outcomes)))
        }
        return OutsideIntakeTotals.reading(queries)
    }

    /// The value and unit a HealthKit quantity is read in, or nil when it cannot be converted. Each quantity is read in the
    /// nutrient's unit when HealthKit says it is compatible; IU is used only for a nutrient with a fixed IU amount (vitamin D).
    static func sampleValue(_ quantity: HKQuantity, hkUnit: HKUnit, unit: MeasureUnit, hasIUFactor: Bool) -> (Double, MeasureUnit)? {
        if quantity.is(compatibleWith: hkUnit) {
            return (quantity.doubleValue(for: hkUnit), unit)
        }
        if hasIUFactor, quantity.is(compatibleWith: .internationalUnit()) {
            return (quantity.doubleValue(for: .internationalUnit()), .iu)
        }
        return nil
    }

    /// The HealthKit unit for each unit the nutrient table uses. A unit not listed here returns nil, which leaves only that nutrient unread.
    static func healthKitUnit(for unit: MeasureUnit) -> HKUnit? {
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

    /// The newest height sample at or before `date`, in centimeters.
    private func latestHeightCentimeters(before date: Date) async -> Decimal? {
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: date, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.height), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        guard let sample = try? await descriptor.result(for: healthStore).first else { return nil }
        return Decimal(sample.quantity.doubleValue(for: .meterUnit(with: .centi)))
    }

    /// Every weight sample that starts from `start` up to `end`, each with the local day it was taken, read as a
    /// Gregorian date. A sample whose day cannot be formed is skipped.
    private func weightSamples(from start: Date, to end: Date) async -> [WeightSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass), predicate: predicate)],
            sortDescriptors: [])
        guard let samples = try? await descriptor.result(for: healthStore) else { return [] }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone.current
        return samples.compactMap { sample in
            let parts = gregorian.dateComponents([.year, .month, .day], from: sample.startDate)
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  let calendarDay = CalendarDay(year: year, month: month, day: day) else { return nil }
            return WeightSample(day: calendarDay, kilograms: Decimal(sample.quantity.doubleValue(for: .gramUnit(with: .kilo))))
        }
    }
}
