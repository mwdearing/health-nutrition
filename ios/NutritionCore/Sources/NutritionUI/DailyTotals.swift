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
    /// The sum of the known values for a nutrient whose day has some entries with no value. Opt-in: `total(for:)`
    /// stays unknown for such a day, so only a caller that reads this field sees a partial sum.
    public let knownSums: [String: NutrientValue]
    /// How many entries of the day have no value for each nutrient, counted in the same pass as the sums.
    public let missingCounts: [String: Int]

    public init(
        totals: [String: NutrientTotal], knownSums: [String: NutrientValue] = [:], missingCounts: [String: Int] = [:]
    ) {
        self.totals = totals
        self.knownSums = knownSums
        self.missingCounts = missingCounts
    }

    /// The number of entries with no value for this nutrient. Zero when the nutrient was not asked for.
    public func missingCount(for nutrient: String) -> Int {
        missingCounts[nutrient] ?? 0
    }

    /// The known partial sum for one nutrient, or nil when the day is fully known or nothing is known.
    public func knownSum(for nutrient: String) -> NutrientValue? {
        knownSums[nutrient]
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
///   amount, and liters and milliliters are added exactly.
/// - A **product snapshot** states its nutrients for the amount its `labelBasis` names, so those
///   values are scaled by the factor `IntakeContextSnapshotBasis.scalingFactor(labelBasis:logged:)`
///   gives, or, for a "per 100 g or mL" label on a weight or a volume only, by the per-100 g or per-100 mL
///   factor `IntakeContextSnapshotBasis.perHundredGOrMLFactor` gives. The intake-context encoder does not take
///   that fallback. The scaled values are summed exactly. 40 g of a product
///   stating 13 g of protein per 100 g contributes 5.2 g, not 13 g. A per-serving basis that also
///   states its serving as a quantity is scaled from that serving and the amount logged, because an
///   entry recorded as an amount cannot be scaled by a count; see `scalingFactor(labelBasis:logged:)`.
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
        // Decided once per entry over a fixed universe of nutrients, so the answer does not depend on which nutrients
        // a caller asks for. Every caller, the meal section included, gets the same answer for the same entry.
        let distrustedEntries = entries.map { Self.isDistrusted($0, lookup: lookup) }
        var totals: [String: NutrientTotal] = [:]
        var knownSums: [String: NutrientValue] = [:]
        var missingCounts: [String: Int] = [:]
        for nutrient in nutrients {
            var values: [NutrientValue] = []
            var missing = 0
            for (index, entry) in entries.enumerated() {
                let contribution = contributions(
                    of: entry, nutrient: nutrient, lookup: lookup, distrusted: distrustedEntries[index])
                // An entry counts as missing when one of its values is unknown, which is exactly the case the sum
                // leaves out. A supplement with an undeclared nutrient contributes nothing, so it is not counted;
                // one whose label basis cannot be scaled does contribute unknown, and is counted.
                if contribution.contains(.unknown) { missing += 1 }
                values.append(contentsOf: contribution)
            }
            missingCounts[nutrient] = missing
            totals[nutrient] = Self.sum(values, nutrient: nutrient)
            if let partial = Self.partialKnownSum(values, nutrient: nutrient) {
                knownSums[nutrient] = partial
            }
        }
        return DailyTotals(totals: totals, knownSums: knownSums, missingCounts: missingCounts)
    }

    /// The nutrients a negative value is looked for under, whatever the caller asks for: the reference table,
    /// the Health mapping keys, and water.
    static let distrustUniverse: [String] = {
        var keys = Set(ReferenceIntakes.nutrients)
        keys.insert(waterKey)
        keys.formUnion(NutrientGoalChoices.keys)
        keys.formUnion(TodayViewModel.defaultTrackedNutrients)
        for mapping in HealthKitWritePlanner.mappings { keys.formUnion(mapping.acceptedKeys) }
        return keys.sorted()
    }()

    /// Whether one entry is distrusted: any logged amount, stated value, or lookup value that is negative.
    static func isDistrusted(
        _ entry: (components: [IntakeComponent], snapshot: ProductDefinition?, category: String),
        lookup: NutrientFactsLookup
    ) -> Bool {
        if entry.components.contains(where: { $0.amount < 0 }) { return true }
        if let snapshot = entry.snapshot {
            return snapshot.nutrients.values.contains { value in
                if case .known(let stated, _) = value { return stated < 0 }
                return false
            }
        }
        for nutrient in distrustUniverse {
            for component in entry.components {
                if case .known(let stated, _) = Self.value(for: component, snapshot: nil, nutrient: nutrient, lookup: lookup),
                    stated < 0
                {
                    return true
                }
            }
        }
        return false
    }

    /// A drink's water: each volume component times its share (its own, else the drink default). Non-volume
    /// components are skipped, as Today skips them.
    private static func drinkWaterContributions(_ components: [IntakeComponent]) -> [NutrientValue] {
        components.compactMap { component -> NutrientValue? in
            guard component.unit.dimension == .volume,
                  let converted = try? Quantity(value: component.amount, unit: component.unit).converted(to: .mL)
            else { return nil }
            // A drink logged before shares has no stored share, and adds no water, as on main.
            guard let share = component.hydrationPercent else { return nil }
            return .known(converted.value * share / 100, .mL)
        }
    }

    /// What one entry contributes to one nutrient's day.
    private static func contributions(
        of entry: (components: [IntakeComponent], snapshot: ProductDefinition?, category: String),
        nutrient: String,
        lookup: NutrientFactsLookup,
        distrusted: Bool = false
    ) -> [NutrientValue] {
        // A distrusted drink row is unknown for water and contributes nothing to any other nutrient, as a drink does.
        if distrusted && entry.category == waterCategory {
            return nutrient == waterKey ? [.unknown] : []
        }
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
        // The one exception is a stored water share, which counts toward the day's water as Today shows it.
        // One decision per entry, made in totals() from every value the entry carries: a negative logged amount,
        // a negative stated value, or a negative lookup value on any nutrient. A distrusted food row is unknown for
        // every nutrient. A distrusted supplement row is unknown for the nutrients it declares, and undeclared ones
        // still contribute nothing, as on a healthy supplement. A zero is a known zero.
        if distrusted {
            guard let snapshot = entry.snapshot, snapshot.kind == .supplement,
                let component = entry.components.first
            else { return [.unknown] }
            if case .unknown = Self.value(for: component, snapshot: snapshot, nutrient: nutrient, lookup: lookup) {
                return []
            }
            return [.unknown]
        }
        guard nutrient != waterKey else { return drinkWaterContributions(entry.components) }
        // A snapshot states the product's own values once, not once per component, so it is scaled
        // and summed once per entry. Summing it per component would count a two-component product's
        // protein twice.
        if let snapshot = entry.snapshot {
            // Asked of one component because the snapshot's values are the product's own and do not
            // vary by component; a lookup that ignores the component (the one the app injects)
            // answers the product, and one that reads it answers the same for every component.
            guard let component = entry.components.first else { return [.unknown] }
            let value = Self.value(for: component, snapshot: snapshot, nutrient: nutrient, lookup: lookup)
            // A supplement contributes the nutrients it declares, not unknown food nutrients.
            // An undeclared nutrient supplies no contribution; it does not invalidate food totals.
            if snapshot.kind == .supplement, case .unknown = value { return [] }
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
    /// "per serving (30 g)" or "per serving (240 mL)", and the entry records the food as an amount
    /// rather than as a counted serving, so a per-count basis alone cannot be scaled from the log
    /// and the day's total for that product read unknown. The two together do say how much was
    /// eaten: the serving the panel stated against the amount logged, in whichever dimension both
    /// are stated. A counted serving ("per serving (3 gummy)" with gummies logged) is answered by the
    /// basis type itself, so the delivery paths scale it too. The weight or volume case stays here: the
    /// intake-context encoder still answers it as unresolvable, and its contract with the relay
    /// receiver depends on that, so changing it is a contract change.
    static func scalingFactor(
        labelBasis: String, logged components: [IntakeComponent]
    ) -> Decimal? {
        if let factor = IntakeContextSnapshotBasis.scalingFactor(
            labelBasis: labelBasis, logged: components)
        {
            return factor
        }
        if let factor = statedServingFactor(labelBasis: labelBasis, logged: components) { return factor }
        return IntakeContextSnapshotBasis.perHundredGOrMLFactor(labelBasis: labelBasis, logged: components)
    }

    /// How much of a stated serving was logged, when the basis names the serving and the entry is
    /// recorded in the same dimension. 30 g logged of a "per serving (30 g)" product is one serving, 60 g
    /// is two; 480 mL logged of a "per serving (240 mL)" product is two of those. A basis that states
    /// no serving — "per serving", "per serving (1 large biscuit)" — is nil rather than a guess,
    /// because nothing in it says how big one serving is.
    ///
    /// The dimension has to match on both sides, and that is the only requirement on it: a panel that
    /// states a serving in milliliters and an entry logged in milliliters say the same thing about how
    /// much was eaten, and so does the gram case. A mass serving and a logged volume do not, so they
    /// are nil rather than a number — the day stays unknown, which is what an unscalable basis has
    /// always meant.
    static func statedServingFactor(
        labelBasis: String, logged components: [IntakeComponent]
    ) -> Decimal? {
        guard let basis = IntakeContextSnapshotBasis.parse(labelBasis), case .perCount = basis else {
            return nil
        }
        guard let serving = statedServingQuantity(labelBasis) else { return nil }
        var loggedAmount = Decimal(0)
        var found = false
        for component in components where component.unit.dimension == serving.unit.dimension {
            guard let converted = try? Quantity(
                value: component.amount, unit: component.unit).converted(to: serving.unit)
            else { continue }
            loggedAmount += converted.value
            found = true
        }
        guard found else { return nil }
        return loggedAmount / serving.value
    }

    /// The quantity one serving is, from a basis that states it: "per serving (30 g)" is 30 g and
    /// "per serving (240 mL)" is 240 mL.
    ///
    /// A household measure can carry its gram weight in brackets of its own, "per serving (1 bar
    /// (30 g))", so the innermost brackets are read: the last "(" and the first ")" after it. The
    /// weight is what scales.
    ///
    /// Only a number and a registry unit are read, in any dimension the registry holds. A serving
    /// stated any other way — "1 large biscuit", "a handful" — is not a quantity this can scale by, so
    /// it is nil and the nutrient stays unknown rather than being scaled by something guessed at.
    static func statedServingQuantity(
        _ labelBasis: String
    ) -> (value: Decimal, unit: MeasureUnit)? {
        // Read by the basis type, which the delivery paths also use for a counted serving.
        IntakeContextSnapshotBasis.statedServingQuantity(labelBasis)
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
            if let snapshot, snapshot.kind == .supplement {
                let declared = snapshot.value(for: key)
                if case .unknown = declared { continue }
                return declared
            }
            let value = lookup.value(for: component, snapshot: snapshot, nutrient: key)
            if case .unknown = value { continue }
            return value
        }
        return .unknown
    }

    /// The milliliters a drink records, one value per component so the coverage says how much of it
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
            // A water entry counts its full volume, or volume times its stored share when one is set.
            values.append(.known(converted.value * (component.hydrationPercent ?? 100) / 100, waterUnit))
        }
        return values
    }

    /// The known part of a day with some unknown entries: the sum of the known values. A below-threshold entry is
    /// a bound ("at least 0") and adds nothing; a day whose only known information is bounds is 0 in the unit.
    static func partialKnownSum(_ values: [NutrientValue], nutrient: String) -> NutrientValue? {
        let partialDay = values.contains { value in
            switch value {
            case .unknown, .belowReportingThreshold: return true
            case .known, .notApplicable: return false
            }
        }
        guard partialDay else { return nil }
        // A below-threshold bound adds 0, so it is left out of the sum rather than stated as a zero.
        let knownOnly = values.filter {
            if case .known = $0 { return true }
            return false
        }
        if !knownOnly.isEmpty {
            let raw = rawSum(knownOnly, nutrient: nutrient)
            if case .known = raw.value { return raw.value }
            return nil
        }
        // Only bounds (or nothing) are known: the zero needs a unit to be stated in.
        let mapping = HealthKitWritePlanner.canonicalKey(for: nutrient) == nutrient
            ? HealthKitWritePlanner.mapping(for: nutrient) : nil
        // Only a bound makes a zero known: a day with nothing known at all stays unknown.
        let bounds: [MeasureUnit?] = values.compactMap { value in
            if case .belowReportingThreshold(let unit) = value { return unit }
            return nil
        }
        guard !bounds.isEmpty else { return nil }
        guard let unit = bounds.compactMap({ $0 }).first ?? mapping?.unit else { return nil }
        return .known(0, unit)
    }

    /// `NutrientTotal.sum`, with any unknown left in the day making the whole nutrient unknown.
    ///
    /// The sum adds what it can and reports the rest in its coverage; that coverage is what decides
    /// the answer here. A day holding one entry whose basis cannot be resolved has no true total
    /// protein, and reporting the other entries' sum as the day's figure would under-report what the
    /// person ate. Unknown is never zero: "0 g of protein" and "protein was never known" are
    /// different facts and only one of them is true.
    ///
    /// **A below-threshold entry is a bound, "at least 0", and never the day's exact total.** It adds 0
    /// to the known sum (see `partialKnownSum`), so the figure is the exact entries' sum. The day is always
    /// marked partial, so the figure is shown with the missing-value note and is never presented as complete.
    /// A day where every entry is below the threshold shows 0 with the note. "No data" is used only when
    /// nothing at all is known. This total itself (`total(for:)`) stays unknown for such a day.
    private static func sum(_ values: [NutrientValue], nutrient: String) -> NutrientTotal {
        let total = rawSum(values, nutrient: nutrient)
        guard total.coverage.hasUnknown || total.coverage.hasBelowReportingThreshold else {
            return total
        }
        return NutrientTotal(value: .unknown, coverage: total.coverage)
    }

    private static func rawSum(_ values: [NutrientValue], nutrient: String) -> NutrientTotal {
        // The nutrient's canonical unit comes from the same mapping the goals and the HealthKit writer use.
        // A known value in another dimension (protein in IU, say) makes the sum throw, and a throw is
        // answered as unknown, the same as a mismatched pair. Without a mapping nothing is checked.
        // A captured alias (`vitamin-a`) may state IU, so only the canonical key is held to the mass unit.
        let mapping = HealthKitWritePlanner.canonicalKey(for: nutrient) == nutrient
            ? HealthKitWritePlanner.mapping(for: nutrient) : nil
        let expected = mapping?.unit
        // Vitamin D stated in IU is restated in mcg before summing, so it adds up with mcg values; an IU
        // for any other nutrient is left as it is and stays unknown here.
        let restated = mapping.map { mapping in values.map(mapping.restatingInternationalUnits) } ?? values
        let total = (try? NutrientTotal.sum(restated, expecting: expected)) ?? NutrientTotal(
            value: .unknown,
            coverage: Coverage(
                knownCount: 0, totalCount: values.count, hasBelowReportingThreshold: false,
                hasUnknown: true))
        return total
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
