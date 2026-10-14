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
    ] + HealthKitWritePlanner.micronutrientKeys.filter { !["potassium", "vitaminA", "vitaminD", "vitaminE"].contains($0) }

    /// The fixed list plus any key the journal's own snapshots carry that it does not name — a compound
    /// a captured supplement panel states, such as `creatine-monohydrate`. A person can then set a goal
    /// for it, and Today shows the day's total against that goal like any other nutrient. The extras
    /// come after the fixed list, in the order the caller gives them.
    public static func keys(including extraKeys: [String]) -> [String] {
        var offered = keys
        for key in extraKeys {
            let canonical = HealthKitWritePlanner.canonicalKey(for: key)
            guard !offered.contains(key), !offered.contains(canonical) else { continue }
            offered.append(key)
        }
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
        // Only the canonical key is a mass row: a captured alias such as `vitamin-a` may state IU, which
        // stays on its own snapshot-unit path.
        if HealthKitWritePlanner.canonicalKey(for: key) == key,
            let mapped = HealthKitWritePlanner.mapping(for: key)?.unit { return mapped }
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
    /// The two ounces are excluded for these metric goal choices. Water is the exception at the
    /// view-model boundary: its volume menu includes fl oz, and input is normalized to mL before
    /// storage. Other nutrient goals retain the metric units their totals are counted in.
    public static func units(forKey key: String, snapshotUnit: MeasureUnit? = nil) -> [MeasureUnit] {
        UnitRegistry.units(in: unit(forKey: key, snapshotUnit: snapshotUnit).dimension).filter(isMetric)
    }

    /// Whether a unit is one a stored target may be counted in: everything the registry holds except
    /// the two ounces and the typed volumes, which are normalized away at the input boundary and so are
    /// never stored.
    private static func isMetric(_ unit: MeasureUnit) -> Bool {
        unit != .oz && unit != .flOz && unit != .cup && unit != .tablespoon && unit != .teaspoon
    }
}

/// One row on the Goals screen: a nutrient, what it is targeted at, and whether a target is set.
public struct NutrientGoalRow: Equatable, Identifiable {
    public let nutrient: String
    public let displayName: String
    /// "60 g", or nil where no target is set for this nutrient.
    public let targetText: String?
    /// Whether this goal's bar shows on Today. On unless a person has switched it off.
    public let showsOnToday: Bool

    public var id: String { nutrient }

    public init(nutrient: String, displayName: String, targetText: String?, showsOnToday: Bool = true) {
        self.nutrient = nutrient
        self.displayName = displayName
        self.targetText = targetText
        self.showsOnToday = showsOnToday
    }

    /// The row for a nutrient with no target, which is still listed so the screen can offer it.
    public static func withoutGoal(
        _ nutrient: String, displayName: String? = nil, showsOnToday: Bool = true
    ) -> NutrientGoalRow {
        NutrientGoalRow(
            nutrient: nutrient,
            displayName: displayName ?? NutrientNames.displayName(for: nutrient), targetText: nil,
            showsOnToday: showsOnToday)
    }
}

/// Editable presentation beside the existing persisted-goal rows.
public struct GoalSectionRow: Identifiable {
    public let nutrient: String
    public let displayName: String
    public let targetText: String
    public let draftText: String
    public let unit: MeasureUnit
    public let detail: String?
    public let rowError: String?
    /// Whether a target is set, which is what the Show on Today switch needs before it can be changed.
    public let hasTarget: Bool
    public let showsOnToday: Bool
    public var id: String { nutrient }
}

public struct GoalSection: Identifiable {
    public let title: String
    public let rows: [GoalSectionRow]
    public var id: String { title }
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
    @Published public var draftText: [String: String] = [:]
    @Published public var selectedUnits: [String: MeasureUnit] = [:]
    @Published public private(set) var rowError: [String: String] = [:]
    /// The split the macro gram goals follow, or nil when they do not follow the energy goal. Worked out
    /// when the goals load and whenever the stored split changes, never per render: a stored split that
    /// no longer describes the goals (the three gram goals are not its output for the stored energy
    /// goal) is not reported, so the screen never says goals follow when they would not.
    @Published public private(set) var followedMacroSplit: MacroSplit?

    public let footerText = "A goal is a number you set. The app compares your day against it and gives no advice or rating."

    public var sections: [GoalSection] {
        let groups: [(String, [String])] = [
            ("Energy and macros", ["energy", "protein", "carbohydrate", "fat", "fiber"]),
            ("Water", ["water"]),
            ("Vitamins", ["vitaminB6", "vitaminB12", "vitaminC", "vitaminK",
                "thiamin", "riboflavin", "niacin", "folate", "biotin", "pantothenicAcid"]),
            ("Minerals", ["sodium", "potassium", "calcium", "iron", "magnesium", "phosphorus", "zinc",
                "chloride", "chromium", "copper", "iodine", "manganese", "molybdenum", "selenium"]),
            ("From your labels", self.offeredKeys.filter { !NutrientGoalChoices.keys.contains($0) }),
        ]
        return groups.map { title, keys in
            GoalSection(title: title, rows: keys.compactMap { key in
                guard let row = self.rows.first(where: { $0.nutrient == key }) else { return nil }
                return GoalSectionRow(
                    nutrient: key, displayName: row.displayName, targetText: row.targetText ?? "None",
                    draftText: self.draftText[key] ?? "",
                    unit: self.selectedUnits[key] ?? self.unit(for: key),
                    detail: title == "From your labels" ? "Added by a scanned label" : nil,
                    rowError: self.rowError[key], hasTarget: row.targetText != nil,
                    showsOnToday: row.showsOnToday)
            })
        }
    }

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
    private let preferences: DisplayPreferences
    private var loadedUnitSystem: UnitSystem?
    private var storedWaterDraft: String?
    private var storedWaterUnit: MeasureUnit?
    /// The text each field was last filled with from the store, so a read can tell a field the person
    /// has not typed in since from one they have.
    private var loadedDraftText: [String: String] = [:]

    public init(
        store: GoalStore, journal: (any JournalStore)? = nil,
        preferences: DisplayPreferences = InMemoryDisplayPreferences()
    ) {
        self.store = store
        self.journal = journal
        self.preferences = preferences
    }

    /// Whether this preference store can keep the activity choice.
    public var offersActivityGoal: Bool { preferences is ActivityGoalPreferences }
    public var addsActiveEnergyToGoal: Bool {
        (preferences as? ActivityGoalPreferences)?.addsActiveEnergyToGoal ?? false
    }
    public func setAddsActiveEnergyToGoal(_ adds: Bool) {
        (preferences as? ActivityGoalPreferences)?.setAddsActiveEnergyToGoal(adds)
        objectWillChange.send()
    }
    public static let activityGoalTitle = "Add active energy to my calorie goal"
    public static let activityGoalFooter =
        "Raises today's calorie goal by the active energy Apple Health reports so far. Needs Show steps, "
        + "activity and weight on Today. Your saved goal does not change."

    /// The unit system the screen shows amounts in, read from the same preferences as the rest of the app.
    public var unitSystem: UnitSystem { preferences.unitSystem }

    /// The reference group chosen on the vitamins and minerals screen, or nil when none is.
    var referenceGroup: ReferenceGroup? { (preferences as? ReferenceGroupPreferences)?.referenceGroup }

    /// Every offered nutrient, with a target's text where one is stored.
    public func load() {
        snapshotUnits = Self.snapshotValueUnits(in: journal)
        do {
            let stored = try store.goals()
            let byNutrient = Self.byKey(stored)
            // Every key that has a stored goal is offered even when no current snapshot carries it, so
            // an existing compound goal can still be changed or removed after the entry that named it
            // is gone. The snapshot keys add the compounds a live capture states.
            let snapshotKeys = Self.snapshotNutrientKeys(in: journal)
            var offered = NutrientGoalChoices.keys(including: snapshotKeys)
            // A stored goal keeps its own key, even a captured alias of a fixed row, so it stays editable.
            for goal in stored where !offered.contains(goal.nutrient) { offered.append(goal.nutrient) }
            offeredKeys = offered
            let displayNames = Self.snapshotDisplayNames(in: journal)
            let hidden = hiddenTodayGoals(in: preferences)
            rows = offeredKeys.map { key in
                let name = displayNames[key] ?? NutrientNames.displayName(for: key)
                let shown = !hidden.contains(key)
                guard let goal = byNutrient[key] else {
                    return .withoutGoal(key, displayName: name, showsOnToday: shown)
                }
                return NutrientGoalRow(
                    nutrient: key, displayName: name,
                    targetText: self.displayGoal(goal).text, showsOnToday: shown)
            }
            self.storedWaterDraft = byNutrient[DailyTotalsBuilder.waterKey].map {
                DecimalFormatting.text(self.displayGoal($0).amount)
            }
            self.storedWaterUnit = byNutrient[DailyTotalsBuilder.waterKey].map { self.displayGoal($0).unit }
            for key in offeredKeys {
                let waterUnitChanged = key == DailyTotalsBuilder.waterKey
                    && self.loadedUnitSystem != self.preferences.unitSystem
                // A field the person has not typed in since the last read always shows what is stored,
                // so a goal removed, put back or changed behind this screen (a clear that stopped
                // partway, a setup save rolled back) is never saved back over the store from old text
                // when the field next loses focus. Text the person typed is theirs and is kept.
                let storedText = byNutrient[key].map { DecimalFormatting.text(self.displayGoal($0).amount) } ?? ""
                if draftText[key] == nil || draftText[key] == loadedDraftText[key] || waterUnitChanged {
                    draftText[key] = storedText
                }
                loadedDraftText[key] = storedText
                if selectedUnits[key] == nil || waterUnitChanged {
                    selectedUnits[key] = byNutrient[key].map { self.displayGoal($0).unit } ?? self.unit(for: key)
                }
            }
            self.loadedUnitSystem = self.preferences.unitSystem
            errorMessage = nil
            // From the goals just read, so a load costs no further store reads for it.
            followedMacroSplit = Self.followedSplit(macroSplitPreferences?.macroSplit, in: byNutrient)
        } catch {
            rows = []
            followedMacroSplit = nil
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
        guard let target = AmountParser.parseTyped(targetText) else {
            errorMessage = "Enter a target above zero."
            return false
        }
        do {
            // Water entered in fl oz or another volume is always stored as exact mL.
            let stored: Quantity
            if nutrient == DailyTotalsBuilder.waterKey {
                stored = try Quantity(value: target, unit: chosen).converted(to: .mL)
            } else {
                stored = Quantity(value: target, unit: chosen)
            }
            try store.setGoal(NutrientGoal(nutrient: nutrient, target: stored.value, unit: stored.unit))
            load()
            return true
        } catch {
            errorMessage = Self.saveFailedMessage
            return false
        }
    }

    /// Shows or hides the nutrient's bar on Today and in the Journal day header. Refused for a nutrient
    /// with no target, because a switch that changes nothing a person can see is not offered.
    @discardableResult
    public func setShowsOnToday(_ shown: Bool, for nutrient: String) -> Bool {
        guard rows.first(where: { $0.nutrient == nutrient })?.targetText != nil,
              let visibility = preferences as? GoalVisibilityPreferences
        else { return false }
        visibility.setGoalShownOnToday(nutrient, shown: shown)
        load()
        return true
    }

    /// The goal stored for one nutrient key exactly as it is stored, or nil when none is. A read that
    /// fails is thrown, so a caller never takes a failed read for "no goal".
    public func storedGoal(for nutrient: String) throws -> NutrientGoal? {
        try store.goal(for: nutrient)
    }

    /// Puts a goal back exactly as it was read, or removes it when there was none. Used to undo a
    /// partly finished save. Returns whether the store accepted the change.
    @discardableResult
    public func restoreGoal(_ goal: NutrientGoal?, for nutrient: String) -> Bool {
        do {
            if let goal {
                try store.setGoal(goal)
            } else {
                try store.removeGoal(nutrient: nutrient)
            }
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

    /// Commits one inline field without discarding drafts in other fields.
    @discardableResult
    public func commitTarget(for nutrient: String) -> Bool {
        let text = (draftText[nutrient] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rowError[nutrient] = nil
        if nutrient == DailyTotalsBuilder.waterKey,
           text == self.storedWaterDraft, selectedUnits[nutrient] == self.storedWaterUnit {
            return true
        }
        if text.isEmpty {
            guard removeTarget(for: nutrient) else { return false }
            draftText[nutrient] = ""
            return true
        }
        guard let target = AmountParser.parseTyped(text), !target.isNaN, target > 0 else {
            rowError[nutrient] = "Enter a number above zero."
            return false
        }
        // Read before the write, so a split can be checked against the energy its grams were worked
        // out from. A read that fails leaves nothing to check, and the split is then not followed.
        var previousEnergy: NutrientGoal?
        if nutrient == Self.energyKey { previousEnergy = (try? store.goal(for: Self.energyKey)) ?? nil }
        guard setTarget(text, for: nutrient, unit: selectedUnits[nutrient]) else { return false }
        draftText[nutrient] = DecimalFormatting.text(target)
        if nutrient == Self.energyKey { followEnergyGoal(from: previousEnergy) }
        return true
    }

    /// The energy goal's key, which a macro split is a share of.
    static let energyKey = "energy"

    /// True while `applyMacroSplit` saves its own energy edit, so that save does not move the gram
    /// goals by the old split just before the new ones replace them.
    var isApplyingMacroSplit = false

    /// The preferences the stored split lives in, or nil for a store that keeps none.
    var macroSplitPreferences: MacroSplitPreferences? { preferences as? MacroSplitPreferences }

    /// Shown when the energy goal saved but the macro goals could not be moved to follow it.
    public static let macroSplitFollowFailedMessage =
        "Your energy goal is saved, but protein, carbohydrate and fat could not be updated to match it. Set the percentages again."

    /// Shown when, on top of that, the earlier macro goals could not all be put back.
    public static let macroSplitFollowRestoreFailedMessage =
        "Your energy goal is saved, but protein, carbohydrate and fat could not be updated to match it, and the earlier ones could not all be put back. Check protein, carbohydrate and fat below."

    /// An energy goal in kcal, or nil when there is none or it is not above zero.
    static func kcal(_ goal: NutrientGoal?) -> Decimal? {
        guard let goal, let value = try? Quantity(value: goal.target, unit: goal.unit).converted(to: .kcal).value,
            !value.isNaN, value > 0
        else { return nil }
        return value
    }

    /// The three macro goals in `goals` and their amounts in grams, or nil when one is missing or not a
    /// mass. Pure, so the goals a load already read are used rather than read again.
    static func macroGoals(in goals: [String: NutrientGoal]) -> (goals: [NutrientGoal], grams: MacroSplit.Grams)? {
        var found: [NutrientGoal] = []
        var grams: [Decimal] = []
        for key in macroSplitKeys {
            guard let goal = goals[key],
                let inGrams = try? Quantity(value: goal.target, unit: goal.unit).converted(to: .g).value
            else { return nil }
            found.append(goal)
            grams.append(inGrams)
        }
        return (found, MacroSplit.Grams(protein: grams[0], carbohydrate: grams[1], fat: grams[2]))
    }

    /// The rule both the screen and following use: the split describes the macro goals when they are
    /// exactly its output for the given energy goal.
    static func describes(_ split: MacroSplit, grams: MacroSplit.Grams, atEnergyKcal energy: Decimal?) -> Bool {
        guard let energy else { return false }
        return (try? split.grams(forEnergyKcal: energy)) == grams
    }

    /// The stored split when it describes `goals` at their energy goal, otherwise nil.
    static func followedSplit(_ stored: MacroSplit?, in goals: [String: NutrientGoal]) -> MacroSplit? {
        guard let stored, let macros = macroGoals(in: goals),
            describes(stored, grams: macros.grams, atEnergyKcal: kcal(goals[energyKey]))
        else { return nil }
        return stored
    }

    /// Goals by key; a key stored twice keeps its last goal.
    static func byKey(_ goals: [NutrientGoal]) -> [String: NutrientGoal] {
        Dictionary(goals.map { ($0.nutrient, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Every stored goal by key, or nil when the store cannot be read. One read for all of them.
    private func storedGoalsByKey() -> [String: NutrientGoal]? {
        (try? store.goals()).map(Self.byKey)
    }

    /// The three stored macro goals and their amounts in grams, or nil when one is missing, unreadable
    /// or not a mass.
    func storedMacroGoals() -> (goals: [NutrientGoal], grams: MacroSplit.Grams)? {
        storedGoalsByKey().flatMap { Self.macroGoals(in: $0) }
    }

    /// Works `followedMacroSplit` out again from the stored split and the stored goals, in one read.
    func refreshFollowedMacroSplit() {
        followedMacroSplit = storedGoalsByKey().flatMap { Self.followedSplit(macroSplitPreferences?.macroSplit, in: $0) }
    }

    /// Shown when the new energy goal saved but is too small for the followed split to share out, so the
    /// macro goals were left as they are.
    public static let macroSplitEnergyTooSmallMessage =
        "Your energy goal is saved, but it is too small to share out by your percentages, so protein, carbohydrate and fat were left as they are and no longer follow it."

    /// After the energy goal changes on this screen, moves the protein, carbohydrate and fat goals to the
    /// stored split's share of the new energy goal.
    ///
    /// The rule is decided here, from the goals, every time: the split is followed only when the three
    /// stored macro goals are exactly what it comes to for the energy goal before this change. A macro
    /// goal edited by hand or by the setup estimate, goals changed behind this screen, an unreadable
    /// store or an energy goal too small to share out all fail that, and the macro goals are then left
    /// as they are, so a goal a person set is never rescaled. Nothing is cleared: whether the goals
    /// follow is a fact about the goals, not a flag to keep in step. The three are written all or none;
    /// when one is refused the earlier ones are put back.
    private func followEnergyGoal(from previous: NutrientGoal?) {
        guard !isApplyingMacroSplit, let split = macroSplitPreferences?.macroSplit,
            let goals = storedGoalsByKey(), let macros = Self.macroGoals(in: goals),
            Self.describes(split, grams: macros.grams, atEnergyKcal: Self.kcal(previous)),
            let after = Self.kcal(goals[Self.energyKey])
        else { return }
        guard let next = try? split.grams(forEnergyKcal: after) else {
            // The goals followed until now, so stopping is said rather than left to the section's text.
            errorMessage = Self.macroSplitEnergyTooSmallMessage
            return
        }
        guard next != macros.grams else { return }
        let targets = [next.protein, next.carbohydrate, next.fat]
        for (index, key) in Self.macroSplitKeys.enumerated() {
            do {
                try store.setGoal(NutrientGoal(nutrient: key, target: targets[index], unit: .g))
            } catch {
                // The write that failed changed nothing, so only the ones before it are put back, and a
                // put-back that fails too is said, since the three may then be a mix of old and new.
                var restored = true
                for earlier in (0..<index).reversed() {
                    do { try store.setGoal(macros.goals[earlier]) } catch { restored = false }
                }
                // The fields are refilled from what is actually stored, so a field holding a value the
                // store no longer has is not committed back over it when it next loses focus.
                for key in Self.macroSplitKeys {
                    draftText[key] = nil
                    selectedUnits[key] = nil
                }
                load()
                errorMessage = restored
                    ? Self.macroSplitFollowFailedMessage : Self.macroSplitFollowRestoreFailedMessage
                return
            }
        }
        // The drafts follow too, so an old draft is not committed over the new goal when its field
        // next loses focus, which would also stop the following.
        for (index, key) in Self.macroSplitKeys.enumerated() {
            draftText[key] = DecimalFormatting.text(targets[index])
            selectedUnits[key] = .g
            rowError[key] = nil
        }
        load()
    }

    /// Clears the error a row showed for earlier text, once something outside the field (guided setup)
    /// has saved or removed that row's goal.
    func clearRowError(for key: String) {
        rowError[key] = nil
    }

    /// Reads the goals again after Erase all data. An erase is an explicit wipe, so text a person was
    /// typing and the errors under it go too, not only the fields that follow the store.
    public func reloadAfterErase() {
        draftText = [:]
        rowError = [:]
        load()
    }

    @discardableResult
    public func clearAllGoals() -> Bool {
        // Clearing all goals is a request to forget them, the split included, so it is forgotten first:
        // a removal refused partway then cannot leave it to resume once matching goals are typed again.
        // A clear that fails before removing anything changed nothing, so the split is put back.
        let earlierSplit = macroSplitPreferences?.macroSplit
        macroSplitPreferences?.setMacroSplit(nil)
        var removedAny = false
        do {
            for goal in try store.goals() {
                try store.removeGoal(nutrient: goal.nutrient)
                removedAny = true
            }
            draftText = [:]
            selectedUnits = [:]
            rowError = [:]
            load()
            return errorMessage == nil
        } catch {
            if !removedAny { macroSplitPreferences?.setMacroSplit(earlierSplit) }
            // The screen shows what the store still holds after a partial clear, and the reload refills
            // the fields of the goals it did remove, so their old text is not saved back.
            load()
            errorMessage = Self.removeFailedMessage
            return false
        }
    }

    /// The name an offered key is shown under: the words the label printed for it when a snapshot
    /// carries them, otherwise the name the key spells out.
    public func displayName(for key: String) -> String {
        rows.first { $0.nutrient == key }?.displayName ?? NutrientNames.displayName(for: key)
    }

    private func displayGoal(_ goal: NutrientGoal) -> DisplayAmount {
        guard goal.nutrient == DailyTotalsBuilder.waterKey else {
            return DisplayAmount(amount: goal.target, unit: goal.unit)
        }
        return AmountDisplay.water(goal.target, unit: goal.unit, system: self.preferences.unitSystem)
    }

    /// Water uses the preferred volume unit; other nutrients use their canonical dimension.
    public func unit(for key: String) -> MeasureUnit {
        if key == DailyTotalsBuilder.waterKey {
            return AmountDisplay.volumeUnit(for: self.preferences.unitSystem)
        }
        return NutrientGoalChoices.unit(forKey: key, snapshotUnit: self.snapshotUnits[key])
    }

    /// Only volumes for water, including fl oz; other nutrients retain their metric unit menus.
    public func units(for key: String) -> [MeasureUnit] {
        if key == DailyTotalsBuilder.waterKey {
            return UnitSelection.offered(for: self.preferences.unitSystem).filter {
                $0.dimension == .volume && !UnitSelection.typedVolumes.contains($0)
            }
        }
        return NutrientGoalChoices.units(forKey: key, snapshotUnit: self.snapshotUnits[key])
    }
}
