import Foundation
import HealthKit
import NutritionUI

/// Reads today's steps and active energy and the person's recent weight from HealthKit, for the
/// activity card on Today. Read access is asked for only when the person taps the card's button, and
/// HealthKit never reports whether it was granted: a type that was refused simply reads as no data.
@MainActor
final class HealthKitReader: BodyActivityReading {
    private let healthStore = HKHealthStore()
    private let defaults: UserDefaults
    private static let askedKey = "healthKitReader.askedForReadAccess"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static var readTypes: Set<HKObjectType> {
        [HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.bodyMass)]
    }

    var hasAskedForReadAccess: Bool { defaults.bool(forKey: Self.askedKey) }

    /// Erase all data returns the card to its opt-in state: the next read waits for the person again.
    nonisolated static func forgetReadAccess(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: askedKey)
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
        if let latest = await latestWeight(before: now) {
            readings.latestWeightKg = latest.kilograms
            readings.latestWeightDate = latest.date
            let thirtyDaysEarlier = Calendar.current.date(byAdding: .day, value: -30, to: latest.date) ?? latest.date
            readings.earlierWeightKg = await latestWeight(before: thirtyDaysEarlier)?.kilograms
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
