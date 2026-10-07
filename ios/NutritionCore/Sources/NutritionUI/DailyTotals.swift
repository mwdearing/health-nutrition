import Foundation
import NutritionDomain
import NutritionJournal

/// Every tracked nutrient's total for one local day.
///
/// A day is the caller's to decide and this type never decides it: it holds what one set of intakes
/// adds up to. `JournalViewModel` groups by day before summing, so a day boundary in one time zone
/// never mixes with one in another, and no day absorbs another's entries.
public struct DailyTotals: Equatable {
    /// One total per tracked nutrient, in the order the caller asked for them.
    public let totals: [String: NutrientTotal]

    public init(totals: [String: NutrientTotal]) {
        self.totals = totals
    }

    /// The total for one nutrient, or nil when it was not among those asked for.
    public func total(for nutrient: String) -> NutrientTotal? {
        totals[nutrient]
    }
}

/// Sums a set of intakes into per-nutrient totals for one day.
///
/// Where an amount comes from is decided by two rules, because those are the two the data has:
///
/// - A component that **measures the nutrient itself** is summed directly. Water is the case this
///   reaches: an entry in category `water` states its volume in its own unit, so it already is the
///   amount, and litres and millilitres are added exactly.
/// - A **product snapshot** states its nutrients for the amount its `labelBasis` names, so those
///   values are scaled by `IntakeContextSnapshotBasis.scalingFactor(labelBasis:logged:)` — the same
///   factor the intake-context encoder uses — and summed exactly. 40 g of a product stating 13 g of
///   protein per 100 g contributes 5.2 g, not 13 g.
///
/// An entry with no snapshot asks the injected `NutrientFactsLookup` about each of its components,
/// so a food the catalog can still answer contributes.
public enum DailyTotalsBuilder {
    /// The key dietary water is summed under.
    public static let waterKey = "water"
    /// The unit dietary water is stated in everywhere else in the app.
    public static let waterUnit = MeasureUnit.mL
    /// The intake category whose volume components count as dietary water.
    public static let waterCategory = "water"

    /// One day's totals for `nutrients`, summed from the current revision of every intake passed in.
    ///
    /// Throws rather than swallowing: a store that cannot be read has no honest totals to show, and
    /// the callers that can carry on without them catch this themselves.
    public static func totals(
        for intakes: [Intake],
        store: any JournalStore,
        lookup: NutrientFactsLookup,
        nutrients: [String]
    ) throws -> DailyTotals {
        // One snapshot is read once per build, however many intakes and nutrients refer to it.
        var snapshots: [String: ProductDefinition?] = [:]
        var entries: [(components: [IntakeComponent], snapshot: ProductDefinition?, category: String)] = []
        for intake in intakes {
            let revisions = try store.revisions(of: intake.id)
            guard let current = revisions.first(where: { $0.number == intake.currentRevision }) else {
                continue
            }
            let snapshot = Self.snapshot(of: current, in: &snapshots, using: store)
            entries.append((current.components, snapshot, intake.category))
        }
        var totals: [String: NutrientTotal] = [:]
        for nutrient in nutrients {
            var values: [NutrientValue] = []
            for entry in entries {
                values.append(contentsOf: contributions(
                    of: entry, nutrient: nutrient, lookup: lookup))
            }
            totals[nutrient] = Self.sum(values)
        }
        return DailyTotals(totals: totals)
    }

    /// What one entry contributes to one nutrient's day.
    private static func contributions(
        of entry: (components: [IntakeComponent], snapshot: ProductDefinition?, category: String),
        nutrient: String,
        lookup: NutrientFactsLookup
    ) -> [NutrientValue] {
        if entry.category == waterCategory {
            // Water is dietary water only for a drink. A food can carry a volume component, and
            // that is not a glass of water the person drank, so a non-drink contributes no water.
            guard nutrient == waterKey else { return [] }
            return waterContributions(entry.components)
        }
        // A snapshot states the product's own values once, not once per component, so it is scaled
        // and summed once per entry. Summing it per component would count a two-component product's
        // protein twice.
        if let snapshot = entry.snapshot {
            // Asked of one component because the snapshot's values are the product's own and do not
            // vary by component; a lookup that ignores the component (the one the app injects)
            // answers the product, and one that reads it answers the same for every component.
            guard let component = entry.components.first else { return [.unknown] }
            let value = lookup.value(for: component, snapshot: snapshot, nutrient: nutrient)
            guard case .known(let amount, let unit) = value else { return [value] }
            // The stated value is for the amount the basis names; it has to be scaled to the amount
            // actually logged before it can be summed with anything else.
            guard let factor = IntakeContextSnapshotBasis.scalingFactor(
                labelBasis: snapshot.labelBasis, logged: entry.components)
            else { return [.unknown] }
            return [.known(amount * factor, unit)]
        }
        return entry.components.map { lookup.value(for: $0, nutrient: nutrient) }
    }

    /// The millilitres a drink records, one value per component so the coverage says how much of it
    /// could be counted. A component that is not a volume, or whose stored amount is NaN or not above
    /// zero, is unknown rather than zero: the app cannot tell what that entry was.
    private static func waterContributions(_ components: [IntakeComponent]) -> [NutrientValue] {
        var values: [NutrientValue] = []
        for component in components {
            guard component.unit.dimension == .volume, isPositive(component.amount),
                let converted = try? Quantity(value: component.amount, unit: component.unit)
                    .converted(to: waterUnit),
                isPositive(converted.value)
            else {
                values.append(.unknown)
                continue
            }
            values.append(.known(converted.value, waterUnit))
        }
        return values
    }

    /// `NutrientTotal.sum`, with any unknown left in the day making the whole nutrient unknown.
    ///
    /// The sum adds what it can and reports the rest in its coverage; that coverage is what decides
    /// the answer here. A day holding one entry whose basis cannot be resolved has no true total
    /// protein, and reporting the other entries' sum as the day's figure would under-report what the
    /// person ate. Unknown is never zero: "0 g of protein" and "protein was never known" are
    /// different facts and only one of them is true.
    private static func sum(_ values: [NutrientValue]) -> NutrientTotal {
        // `NutrientTotal.sum` is non-throwing for the values this builder produces: every value
        // either shares a dimension with the first known one or is left out of the sum entirely.
        let total = (try? NutrientTotal.sum(values)) ?? NutrientTotal(
            value: .unknown,
            coverage: Coverage(
                knownCount: 0, totalCount: values.count, hasBelowReportingThreshold: false,
                hasUnknown: true))
        guard total.coverage.hasUnknown else { return total }
        return NutrientTotal(value: .unknown, coverage: total.coverage)
    }

    /// The product snapshot a revision points at, read at most once per snapshot id. A snapshot that
    /// cannot be read is nil, which the lookup answers as unknown rather than as zero.
    private static func snapshot(
        of revision: IntakeRevision, in cache: inout [String: ProductDefinition?], using store: any JournalStore
    ) -> ProductDefinition? {
        guard let id = revision.productSnapshotID else { return nil }
        if let cached = cache[id] { return cached }
        let found = try? store.product(snapshotID: id)
        cache[id] = found
        return found
    }

    private static func isPositive(_ value: Decimal) -> Bool {
        !value.isNaN && value > 0
    }
}
