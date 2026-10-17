import Foundation
import NutritionDomain

/// One nutrient sample the app target read from HealthKit, described as plain data.
///
/// `NutritionJournal` may not import HealthKit, so the app target names the type by its identifier
/// string, converts the value into `unit` and says whether this app wrote the sample itself.
public struct OutsideNutrientSample: Sendable, Hashable {
    /// A HealthKit quantity type identifier, such as `"HKQuantityTypeIdentifierDietaryProtein"`.
    public let quantityTypeIdentifier: String
    public let value: Decimal
    public let unit: MeasureUnit
    /// True for a sample this app wrote. Those are already in the journal, so they are never counted
    /// again. The app target decides this from the sample's source.
    public let isWrittenByThisApp: Bool

    public init(quantityTypeIdentifier: String, value: Decimal, unit: MeasureUnit, isWrittenByThisApp: Bool) {
        self.quantityTypeIdentifier = quantityTypeIdentifier
        self.value = value
        self.unit = unit
        self.isWrittenByThisApp = isWrittenByThisApp
    }
}

/// Adds up the nutrient samples other apps wrote to Apple Health, per canonical nutrient key.
///
/// The read types and units come from `HealthKitWritePlanner.mappings`, so what this app reads is
/// exactly what it writes. A sample whose type is not mapped, whose unit cannot be converted exactly
/// into the mapping's unit, or that this app wrote itself, adds nothing.
public enum OutsideIntakeTotals {
    /// The identifiers the app asks Health to read: every type it writes, in the order it writes them.
    public static let readQuantityTypeIdentifiers: [String] = {
        var seen = Set<String>()
        return HealthKitWritePlanner.mappings.map(\.quantityTypeIdentifier).filter { seen.insert($0).inserted }
    }()

    /// The total per canonical nutrient key, in each mapping's unit. A nutrient with no outside
    /// sample is absent, so a caller can tell "nothing logged elsewhere" from "logged as zero".
    public static func totals(from samples: [OutsideNutrientSample]) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for sample in samples where !sample.isWrittenByThisApp {
            guard let mapping = HealthKitWritePlanner.mappings.first(where: {
                $0.quantityTypeIdentifier == sample.quantityTypeIdentifier
            }) else {
                continue
            }
            guard let converted = try? Quantity(value: sample.value, unit: sample.unit).converted(to: mapping.unit) else {
                continue
            }
            totals[mapping.nutrientKey, default: 0] += converted.value
        }
        return totals
    }
}
