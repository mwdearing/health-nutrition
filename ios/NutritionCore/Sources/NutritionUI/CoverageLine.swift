import Foundation
import NutritionDomain
import NutritionJournal

/// Looks up the value of one nutrient for one intake component. The catalog arrives later;
/// until then the default answers `.unknown`, which is never read as zero.
public protocol NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue
}

public struct UnknownNutrientFacts: NutrientFactsLookup {
    public init() {}

    public func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }
}

/// One coverage indicator, for example "2 of 5 foods lack potassium".
public struct CoverageLine: Equatable, Identifiable {
    public let nutrient: String
    /// Foods whose value is unknown.
    public let missing: Int
    /// Foods that count: not-applicable values are left out.
    public let total: Int

    public var id: String { nutrient }

    public init(nutrient: String, missing: Int, total: Int) {
        self.nutrient = nutrient
        self.missing = missing
        self.total = total
    }

    public var text: String {
        "\(missing) of \(total) foods lack \(nutrient)"
    }

    public var isComplete: Bool { missing == 0 }

    /// Counts unknown values as missing; a known zero is known; not-applicable values are left out.
    public static func make(nutrient: String, values: [NutrientValue]) -> CoverageLine {
        var missing = 0
        var total = 0
        for value in values {
            switch value {
            case .unknown:
                missing += 1
                total += 1
            case .known, .belowReportingThreshold:
                total += 1
            case .notApplicable:
                break
            }
        }
        return CoverageLine(nutrient: nutrient, missing: missing, total: total)
    }
}
