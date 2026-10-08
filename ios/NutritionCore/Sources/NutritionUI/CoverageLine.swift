import Foundation
import NutritionDomain
import NutritionJournal

/// Looks up the value of one nutrient for one intake component. The catalog arrives later;
/// until then the default answers `.unknown`, which is never read as zero.
public protocol NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue
    /// The same value resolved through the product snapshot the component was recorded with, which is
    /// nil for an entry typed by hand. A lookup that does not use snapshots answers from the
    /// component alone.
    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue
}

extension NutrientFactsLookup {
    public func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        value(for: component, nutrient: nutrient)
    }
}

public struct UnknownNutrientFacts: NutrientFactsLookup {
    public init() {}

    public func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }
}

/// Answers from the nutrient values the product snapshot carries, so an entry recorded from a looked
/// up product or a calculated recipe contributes what that product states. The stored values are the
/// product's own, on the basis its snapshot names; a snapshot that states nothing is unknown, never
/// zero.
public struct SnapshotNutrientFacts: NutrientFactsLookup {
    public init() {}

    public func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }

    public func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
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
    ///
    /// Every value counts here, because this is the count of a day's foods and a value on its own says
    /// nothing about what kind of product it came from. Where the day's entries carry a product kind,
    /// use `make(nutrient:values:kinds:)`, which leaves a supplement out.
    public static func make(nutrient: String, values: [NutrientValue]) -> CoverageLine {
        make(nutrient: nutrient, values: values, kinds: nil)
    }

    /// The same line for entries that know what they are. `kinds` runs alongside `values`, one per value.
    ///
    /// **A supplement is left out of both numbers.** It is not missing from anything: a multivitamin
    /// states no fibre, no protein and no potassium because that is what a supplement is, so counting it
    /// would report the day's food as short of three nutrients nobody was ever going to get from it.
    /// Leaving it out of the total as well as out of the missing count is what keeps "1 of 1 foods lack
    /// fibre" meaning one food of the day's foods — a supplement never lowers the count either, because
    /// a day with fewer foods in it is not better covered.
    ///
    /// A value with no kind beside it counts as a food, which is what an entry without a product
    /// snapshot is: the food it was recorded as before a kind existed.
    ///
    /// **A line that counts nothing is not published.** A `total` of zero means the day holds no food and
    /// no drink at all, and "0 of 0 foods lack fibre" says nothing about anybody's day; the caller drops
    /// those rather than showing them.
    public static func make(nutrient: String, values: [NutrientValue], kinds: [ProductKind]?) -> CoverageLine {
        var missing = 0
        var total = 0
        for (index, value) in values.enumerated() {
            // Indexed rather than zipped, so a shorter kind list cannot silently shorten the day: a
            // value with no kind beside it is a food, as above.
            if let kinds, kinds.indices.contains(index), kinds[index] == .supplement { continue }
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
