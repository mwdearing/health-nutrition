import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

/// The nutrient keys the Goals screen offers, with the unit each is counted in.
///
/// A fixed list rather than whatever the catalog happens to hold, because a target a person cannot
/// choose is a target they cannot correct. Every key is one the journal already uses, so a goal set
/// here compares against the same totals Today shows.
public enum NutrientGoalChoices {
    /// Keys in the order the screen lists them.
    public static let keys = [
        "energy", "protein", "carbohydrate", "fiber", "fat", "sodium", "potassium", "water",
    ]

    /// The fixed list plus any key the journal's own snapshots carry that it does not name — a compound
    /// a captured supplement panel states, such as `creatine-monohydrate`. A person can then set a goal
    /// for it, and Today shows the day's total against that goal like any other nutrient. The extras
    /// come after the fixed list, in the order the caller gives them.
    public static func keys(including extraKeys: [String]) -> [String] {
        var offered = keys
        for key in extraKeys where !offered.contains(key) { offered.append(key) }
        return offered
    }

    /// The unit a key is counted in, which is where its total is read. It comes from the canonical
    /// nutrient mapping rather than from a table written here, so it is the same unit the totals
    /// provider and the HealthKit writer use: energy is kcal, water is mL, and every other key here
    /// is a mass.
    ///
    /// Energy in grams was a category error rather than a rounding one — a target of "60 g" of energy
    /// compares against nothing, and nothing on the screen could convert it back, so the comparison
    /// the person set was silently never against their day.
    ///
    /// A compound the mapping does not name has no canonical unit, so its dimension is read from the
    /// value a capture stored for it: a label that states `Vitamin A 900IU` is counted in IU and a
    /// target in milligrams would compare against nothing. The canonical mapping still wins where it
    /// exists, so a captured `Protein 500mg` is still grams.
    public static func unit(forKey key: String, snapshotUnit: MeasureUnit? = nil) -> MeasureUnit {
        if let mapped = HealthKitWritePlanner.mapping(for: key)?.unit { return mapped }
        if key == DailyTotalsBuilder.waterKey { return DailyTotalsBuilder.waterUnit }
        return snapshotUnit ?? .g
    }

    /// Every unit a key may be counted in: the registry's metric units for that one nutrient's
    /// dimension and no others, so a target cannot be set in something its totals are not counted in.
    ///
    /// Offering every mass *and* energy unit for every nutrient is what let the energy-in-grams
    /// target above be entered at all. The dimension is the one the nutrient's own unit has, so water
    /// is offered volumes, energy energies, and the rest masses.
    ///
    /// The two ounces are excluded as well, by the same rule the recipe editor applies. `oz` and
    /// `fl oz` are input and display units that Add intake normalises to grams and millilitres on the
    /// way in; a target has no such step, because `NutrientProgressLine` shows the day's total in
    /// its own unit beside the target as it was set rather than converting one to the other. An
    /// ounce target would sit on screen next to a gram total — "Protein 52 g of 2 oz" — comparing two
    /// numbers that are not in the same unit. A goal's whole job is to be compared against the day's
    /// total, so what it is offered is the metric units that total is counted in.
    public static func units(forKey key: String, snapshotUnit: MeasureUnit? = nil) -> [MeasureUnit] {
        UnitRegistry.units(in: unit(forKey: key, snapshotUnit: snapshotUnit).dimension).filter(isMetric)
    }

    /// Whether a unit is one a stored target may be counted in: everything the registry holds except
    /// the two ounces, which are normalised away at the input boundary and so are never stored.
    private static func isMetric(_ unit: MeasureUnit) -> Bool {
        unit != .oz && unit != .flOz
    }
}

/// One row on the Goals screen: a nutrient, what it is targeted at, and whether a target is set.
public struct NutrientGoalRow: Equatable, Identifiable {
    public let nutrient: String
    public let displayName: String
    /// "60 g", or nil where no target is set for this nutrient.
    public let targetText: String?

    public var id: String { nutrient }

    public init(nutrient: String, displayName: String, targetText: String?) {
        self.nutrient = nutrient
        self.displayName = displayName
        self.targetText = targetText
    }

    /// The row for a nutrient with no target, which is still listed so the screen can offer it.
    public static func withoutGoal(_ nutrient: String, displayName: String? = nil) -> NutrientGoalRow {
        NutrientGoalRow(
            nutrient: nutrient,
            displayName: displayName ?? NutrientNames.displayName(for: nutrient), targetText: nil)
    }
}

/// Backs the Goals screen: the targets a person set, and the writes that change them.
///
/// The keys come from `NutrientGoalChoices` rather than from the store, so the screen lists the same
/// nutrients however few targets exist. A read that throws leaves the list empty and says so: an
/// empty screen that looks loaded would invite a person to set a target over one already stored.
@MainActor
public final class GoalsViewModel: ObservableObject {
    @Published public private(set) var rows: [NutrientGoalRow] = []
    /// The nutrients the change-a-goal picker offers: the fixed list plus every compound key the
    /// journal's current snapshots carry.
    @Published public private(set) var offeredKeys: [String] = NutrientGoalChoices.keys
    @Published public private(set) var errorMessage: String?

    public static let readFailedMessage = "Could not read the daily goals."
    public static let saveFailedMessage = "Could not save that daily goal."
    public static let removeFailedMessage = "Could not remove that daily goal."

    private let store: GoalStore
    /// The journal, read only to learn which compound keys its snapshots carry, so the screen can
    /// offer a goal for a nutrient a captured label states but the fixed list does not name.
    private let journal: (any JournalStore)?
    /// The unit each captured key was stored in, keyed by nutrient, read from the same snapshots the
    /// keys come from. A compound the canonical mapping does not name takes its dimension from here,
    /// so a label's `Vitamin A 900IU` is offered and stored in IU rather than as a mass.
    private var snapshotUnits: [String: MeasureUnit] = [:]

    public init(store: GoalStore, journal: (any JournalStore)? = nil) {
        self.store = store
        self.journal = journal
    }

    /// Every offered nutrient, with a target's text where one is stored.
    public func load() {
        snapshotUnits = Self.snapshotValueUnits(in: journal)
        do {
            let stored = try store.goals()
            let byNutrient = Dictionary(stored.map { ($0.nutrient, $0) }, uniquingKeysWith: { _, last in last })
            // Every key that has a stored goal is offered even when no current snapshot carries it, so
            // an existing compound goal can still be changed or removed after the entry that named it
            // is gone. The snapshot keys add the compounds a live capture states.
            let snapshotKeys = Self.snapshotNutrientKeys(in: journal)
            offeredKeys = NutrientGoalChoices.keys(including: snapshotKeys + stored.map(\.nutrient))
            let displayNames = Self.snapshotDisplayNames(in: journal)
            rows = offeredKeys.map { key in
                let name = displayNames[key] ?? NutrientNames.displayName(for: key)
                guard let goal = byNutrient[key] else { return .withoutGoal(key, displayName: name) }
                return NutrientGoalRow(
                    nutrient: key, displayName: name,
                    targetText: "\(DecimalFormatting.text(goal.target)) \(goal.unit.symbol)")
            }
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = Self.readFailedMessage
        }
    }

    /// The compound keys the journal's current snapshots carry that the fifteen journal nutrients do
    /// not name, sorted. A label capture stores a supplement's own compound under a slug of its name
    /// (`creatine-monohydrate`), and that key is what a goal and the day's total are read under, so it
    /// has to be offerable here. A read that throws is treated as no extras: the fixed list is still
    /// offered, and the totals are unaffected.
    static func snapshotNutrientKeys(in journal: (any JournalStore)?) -> [String] {
        guard let journal else { return [] }
        let standard = Set(NutritionFactKey.allCases.map(\.rawValue))
        var keys: Set<String> = []
        guard let intakes = try? journal.activeIntakes() else { return [] }
        for intake in intakes {
            guard let revisions = try? journal.revisions(of: intake.id),
                  let current = revisions.first(where: { $0.number == intake.currentRevision }),
                  let snapshotID = current.productSnapshotID,
                  let product = try? journal.product(snapshotID: snapshotID)
            else { continue }
            guard product.catalogOrigin == ProductOrigin.label_capture else { continue }
            for key in product.nutrients.keys where !standard.contains(key) { keys.insert(key) }
        }
        return keys.sorted()
    }

    /// The printed names the journal's current snapshots carry, keyed by nutrient. A captured
    /// supplement panel stores a compound under a slug and keeps the label's own words beside it, so a
    /// goal for `dha` is shown as `DHA` rather than as the `Dha` the slug spells back out. A read that
    /// throws is treated as no names: the keys are still offered under the names they spell out.
    static func snapshotDisplayNames(in journal: (any JournalStore)?) -> [String: String] {
        guard let journal else { return [:] }
        var names: [String: String] = [:]
        guard let intakes = try? journal.activeIntakes() else { return [:] }
        for intake in intakes {
            guard let revisions = try? journal.revisions(of: intake.id),
                  let current = revisions.first(where: { $0.number == intake.currentRevision }),
                  let snapshotID = current.productSnapshotID,
                  let product = try? journal.product(snapshotID: snapshotID)
            else { continue }
            guard product.catalogOrigin == ProductOrigin.label_capture else { continue }
            for (key, name) in product.nutrientDisplayNames {
                names[key] = name
            }
        }
        return names
    }

    /// The unit each captured key was stored in, keyed by nutrient. A compound a captured supplement
    /// panel states has no canonical unit, so the dimension its goal may be set in is the dimension
    /// the capture recorded: `Vitamin A 900IU` is an international-unit value, and a target in grams
    /// would compare against nothing. A read that throws is treated as no units: those keys fall back
    /// to the mass the screen assumed before.
    static func snapshotValueUnits(in journal: (any JournalStore)?) -> [String: MeasureUnit] {
        guard let journal else { return [:] }
        var units: [String: MeasureUnit] = [:]
        guard let intakes = try? journal.activeIntakes() else { return [:] }
        for intake in intakes {
            guard let revisions = try? journal.revisions(of: intake.id),
                  let current = revisions.first(where: { $0.number == intake.currentRevision }),
                  let snapshotID = current.productSnapshotID,
                  let product = try? journal.product(snapshotID: snapshotID)
            else { continue }
            guard product.catalogOrigin == ProductOrigin.label_capture else { continue }
            for (key, value) in product.nutrients where units[key] == nil {
                let unit: MeasureUnit?
                switch value {
                case .known(_, let stored): unit = stored
                case .belowReportingThreshold(let stored): unit = stored
                case .unknown, .notApplicable: unit = nil
                }
                if let unit { units[key] = unit }
            }
        }
        return units
    }

    /// Stores `target` for `nutrient`, replacing any target already set for it.
    ///
    /// Returns whether it was written. Invalid text is refused rather than rounded or guessed at, and
    /// leaves whatever was stored before untouched.
    @discardableResult
    public func setTarget(_ targetText: String, for nutrient: String, unit: MeasureUnit? = nil) -> Bool {
        let chosen = unit ?? self.unit(for: nutrient)
        guard let target = AmountParser.parse(targetText) else {
            errorMessage = "Enter a target above zero."
            return false
        }
        do {
            try store.setGoal(NutrientGoal(nutrient: nutrient, target: target, unit: chosen))
            load()
            return true
        } catch {
            errorMessage = Self.saveFailedMessage
            return false
        }
    }

    /// Removes the target for `nutrient`, so the nutrient falls back to a plain total.
    @discardableResult
    public func removeTarget(for nutrient: String) -> Bool {
        do {
            try store.removeGoal(nutrient: nutrient)
            load()
            return true
        } catch {
            errorMessage = Self.removeFailedMessage
            return false
        }
    }

    /// The name an offered key is shown under: the words the label printed for it when a snapshot
    /// carries them, otherwise the name the key spells out.
    public func displayName(for key: String) -> String {
        rows.first { $0.nutrient == key }?.displayName ?? NutrientNames.displayName(for: key)
    }

    /// The unit a key's goal is counted in, read from the captured value's dimension for a compound
    /// the canonical mapping does not name, and from the mapping otherwise.
    public func unit(for key: String) -> MeasureUnit {
        NutrientGoalChoices.unit(forKey: key, snapshotUnit: snapshotUnits[key])
    }

    /// Every unit the key's goal may be set in: the registry's metric units for the dimension
    /// `unit(for:)` reads, and no others.
    public func units(for key: String) -> [MeasureUnit] {
        NutrientGoalChoices.units(forKey: key, snapshotUnit: snapshotUnits[key])
    }
}
