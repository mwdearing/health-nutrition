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
            // An IU sample with a fixed conversion (vitamin D) is restated the way the writer restates it.
            var value = sample.value
            var unit = sample.unit
            if unit == .iu {
                guard let factor = mapping.amountPerInternationalUnit else { continue }
                value *= factor
                unit = mapping.unit
            }
            guard let converted = try? Quantity(value: value, unit: unit).converted(to: mapping.unit) else {
                continue
            }
            totals[mapping.nutrientKey, default: 0] += converted.value
        }
        return totals
    }
}

/// One sample from a Health query, after the app target has converted it where it could. HealthKit's own
/// types stay in the app target, so the rules below can be tested here.
public enum OutsideSampleOutcome: Sendable, Equatable {
    /// A sample in a unit this app can total (the mapping's unit, or IU for a nutrient with a fixed IU amount).
    case sample(OutsideNutrientSample)
    /// A sample in a unit that cannot be converted. Its nutrient cannot be read as a complete total.
    case unconvertible
}

/// What one Health query for one nutrient returned.
public enum OutsideQueryOutcome: Sendable, Equatable {
    /// The query ran and returned these samples. An empty list is a successful read with no samples.
    case samples([OutsideSampleOutcome])
    /// The query failed.
    case failed
    /// The identifier does not map to a nutrient, so there is nothing to read.
    case unmapped
}

/// One query for one nutrient: the canonical key it reads, and what came back. An unmapped query has no key to read.
public struct OutsideQuery: Sendable, Equatable {
    public let nutrientKey: String
    public let outcome: OutsideQueryOutcome

    public init(nutrientKey: String, outcome: OutsideQueryOutcome) {
        self.nutrientKey = nutrientKey
        self.outcome = outcome
    }
}

/// The day's outside reading: totals per canonical key, the keys whose reads were complete, and whether any read was not.
public struct OutsideIntakeReading: Equatable, Sendable {
    public let totals: [String: Decimal]
    public let readKeys: Set<String>
    public let failed: Bool

    public init(totals: [String: Decimal], readKeys: Set<String>, failed: Bool) {
        self.totals = totals
        self.readKeys = readKeys
        self.failed = failed
    }
}

extension OutsideIntakeTotals {
    /// Combines the queries for a day. A nutrient is read completely only when its query succeeded and every one of
    /// its samples converted, so a failed query or an unconvertible sample leaves it unread. A successful query with no
    /// samples is a complete read. The samples this app wrote are left out of the totals (see `totals(from:)`), but
    /// their query still counts as read.
    public static func reading(_ queries: [OutsideQuery]) -> OutsideIntakeReading {
        var samples: [OutsideNutrientSample] = []
        var readKeys: Set<String> = []
        var failed = false
        for query in queries {
            switch query.outcome {
            case .failed, .unmapped:
                failed = true
            case .samples(let outcomes):
                var skipped = false
                for outcome in outcomes {
                    switch outcome {
                    case .sample(let sample): samples.append(sample)
                    case .unconvertible: skipped = false
                    }
                }
                if skipped {
                    failed = true
                } else {
                    readKeys.insert(query.nutrientKey)
                }
            }
        }
        return OutsideIntakeReading(totals: totals(from: samples), readKeys: readKeys, failed: failed)
    }
}
