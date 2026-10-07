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
///   values are scaled by the factor `IntakeContextSnapshotBasis.scalingFactor(labelBasis:logged:)`
///   gives — the same factor the intake-context encoder uses — and summed exactly. 40 g of a product
///   stating 13 g of protein per 100 g contributes 5.2 g, not 13 g. A per-serving basis that also
///   states its serving as a mass is scaled from that serving and the amount logged, because an entry
///   recorded as a mass cannot be scaled by a count; see `scalingFactor(labelBasis:logged:)`.
///
/// The nutrient a value is read under is resolved through the canonical mapping
/// `HealthKitWritePlanner` holds, so a snapshot storing `energyKcal` is read for `energy` and one
/// storing `carbohydrates` for `carbohydrate`.
///
/// An entry with no snapshot asks the injected `NutrientFactsLookup` about each of its components,
/// so a food the catalog can still answer contributes.
///
/// Water is the one nutrient only one kind of entry speaks to, and neither kind speaks to the
/// other's: a food entry states no water, and a drink states no nutrients. Anything else made each
/// answer unknown where the day says something.
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
        // The other way round: a drink states nothing but its own volume, so it is no evidence
        // about any nutrient but water. Without this a food entry reaches the water line at all,
        // answers unknown there — a snapshot states no water unless the product states water — and a
        // day holding one food makes the day's water unknown rather than what was actually drunk.
        guard nutrient != waterKey else { return [] }
        // A snapshot states the product's own values once, not once per component, so it is scaled
        // and summed once per entry. Summing it per component would count a two-component product's
        // protein twice.
        if let snapshot = entry.snapshot {
            // Asked of one component because the snapshot's values are the product's own and do not
            // vary by component; a lookup that ignores the component (the one the app injects)
            // answers the product, and one that reads it answers the same for every component.
            guard let component = entry.components.first else { return [.unknown] }
            let value = Self.value(for: component, snapshot: snapshot, nutrient: nutrient, lookup: lookup)
            guard case .known(let amount, let unit) = value else { return [value] }
            // The stated value is for the amount the basis names; it has to be scaled to the amount
            // actually logged before it can be summed with anything else.
            guard let factor = Self.scalingFactor(
                labelBasis: snapshot.labelBasis, logged: entry.components)
            else { return [.unknown] }
            return [.known(amount * factor, unit)]
        }
        return entry.components.map {
            Self.value(for: $0, snapshot: nil, nutrient: nutrient, lookup: lookup)
        }
    }

    /// The factor a snapshot's stated values are scaled by for what was logged, or nil when the
    /// logged components cannot answer its basis.
    ///
    /// This is `IntakeContextSnapshotBasis.scalingFactor(labelBasis:logged:)`, plus one case it
    /// cannot reach. A barcode lookup or a label panel that knows how big a serving is stores
    /// "per serving (30 g)", and the entry records the food as a mass — 30 g, 60 g — rather than as a
    /// counted serving, so a per-count basis alone cannot be scaled from the log and the day's total
    /// for that product read unknown. The two together do say how much was eaten: the serving the
    /// panel stated against the amount logged. It is deliberately here and not in the basis type
    /// itself, because the intake-context encoder answers the same basis as unresolvable and its
    /// contract with the relay receiver says so; changing what that basis means is a contract change,
    /// while reading it here is one reader being able to answer a question the data can answer.
    private static func scalingFactor(
        labelBasis: String, logged components: [IntakeComponent]
    ) -> Decimal? {
        if let factor = IntakeContextSnapshotBasis.scalingFactor(
            labelBasis: labelBasis, logged: components)
        {
            return factor
        }
        return statedServingFactor(labelBasis: labelBasis, logged: components)
    }

    /// How much of a stated serving was logged, when the basis names the serving as a mass and the
    /// entry is recorded as one. 30 g logged of a "per serving (30 g)" product is one serving, 60 g is
    /// two, and a basis that states no serving — "per serving", "per serving (1 large biscuit)" — is
    /// nil rather than a guess, because nothing in it says what one serving weighs.
    private static func statedServingFactor(
        labelBasis: String, logged components: [IntakeComponent]
    ) -> Decimal? {
        guard let basis = IntakeContextSnapshotBasis.parse(labelBasis), case .perCount = basis else {
            return nil
        }
        guard let serving = statedServingMass(labelBasis) else { return nil }
        var loggedMass = Decimal(0)
        var found = false
        for component in components where component.unit.dimension == .mass {
            guard let converted = try? Quantity(
                value: component.amount, unit: component.unit).converted(to: serving.unit)
            else { continue }
            loggedMass += converted.value
            found = true
        }
        guard found else { return nil }
        return loggedMass / serving.value
    }

    /// The mass one serving weighs, from a basis that states it: "per serving (30 g)" is 30 g.
    ///
    /// Only a number and a registry mass unit are read. A serving stated any other way — "1 large
    /// biscuit", "240 mL" — is not a mass this can scale by, so it is nil and the nutrient stays
    /// unknown rather than being scaled by a quantity of the wrong dimension.
    private static func statedServingMass(_ labelBasis: String) -> (value: Decimal, unit: MeasureUnit)? {
        guard let open = labelBasis.firstIndex(of: "("),
            let close = labelBasis.firstIndex(of: ")"), close > open
        else { return nil }
        let stated = String(labelBasis[labelBasis.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        let digits = stated.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let symbol = stated.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard let amount = AmountParser.parse(String(digits)),
            let unit = try? UnitRegistry.unit(for: symbol), unit.dimension == .mass
        else { return nil }
        return (amount, unit)
    }

    /// What one component carries for a nutrient, read through every key that nutrient may be stored
    /// under.
    ///
    /// The keys come from the canonical mapping `HealthKitWritePlanner` uses, so the alias table is
    /// written down once rather than per reader: a barcode snapshot keeps `energyKcal` and
    /// `carbohydrates`, while a goal and Today ask for `energy` and `carbohydrate`. Reading the asked
    /// key alone made the day's energy unknown where the snapshot says 400 kcal. They are read in the
    /// mapping's order — the canonical key first, then the aliases — so a snapshot that states both is
    /// read once and never summed twice, and the first key that says anything at all is what the entry
    /// carries. Keys that say nothing at all are unknown, never zero.
    public static func value(
        for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String,
        lookup: NutrientFactsLookup
    ) -> NutrientValue {
        for key in HealthKitWritePlanner.acceptedKeys(for: nutrient) {
            let value = lookup.value(for: component, snapshot: snapshot, nutrient: key)
            if case .unknown = value { continue }
            return value
        }
        return .unknown
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
    ///
    /// **Coverage that is uncertain is answered as unknown, not as a lower bound.** One entry that
    /// states its nutrient below the reporting threshold carries no amount, only a bound, so adding
    /// it to what the other entries stated cannot produce the day's total; it produces a number that
    /// is smaller than the truth by an unknown amount. That is the same defect as the unknown case
    /// above and is decided the same way, so the sum reads as unknown instead. It is a deliberate loss
    /// of precision against printing "at least 5 g" beside a goal: the screen would then compare a
    /// bound against a target as though the bound were the day's figure, and a person reading "at
    /// least 5 g of 60 g" cannot tell whether the day is met. Unknown is the one answer that cannot
    /// be mistaken for the day being short.
    private static func sum(_ values: [NutrientValue]) -> NutrientTotal {
        // `NutrientTotal.sum` is non-throwing for the values this builder produces: every value
        // either shares a dimension with the first known one or is left out of the sum entirely.
        let total = (try? NutrientTotal.sum(values)) ?? NutrientTotal(
            value: .unknown,
            coverage: Coverage(
                knownCount: 0, totalCount: values.count, hasBelowReportingThreshold: false,
                hasUnknown: true))
        guard total.coverage.hasUnknown || total.coverage.hasBelowReportingThreshold else {
            return total
        }
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
