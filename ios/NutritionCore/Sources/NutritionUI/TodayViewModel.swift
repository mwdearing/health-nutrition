import Foundation
import NutritionDomain
import NutritionJournal

/// A water entry or a deleted entry that can still be taken back.
public struct UndoHandle: Equatable {
    public let intakeID: String
    public let expiresAt: Date
    /// True for a delete, which Undo restores; false for a quick-added water entry, which Undo removes.
    public var isDelete = false
}

/// One row on the Today screen.
public struct TodayRow: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let occurredAt: Date
    /// The meal as words, or nil when the entry states none.
    public let meal: String?
    /// What kind of product the entry was recorded with. Food unless the entry's product says
    /// otherwise, which is what an entry typed by hand is; only a supplement is labeled on the row.
    public let kind: ProductKind
    /// Whether the entry is a water entry. Water is summarized by its own card on Today rather than
    /// listed row by row, so the meal sections leave these out; the flat `rows` list still holds them.
    public let isWater: Bool
    /// The time of day the entry was logged, "22:13", in the entry's own time zone. Empty when unknown.
    public let timeText: String

    public init(
        id: String, title: String, detail: String, occurredAt: Date, meal: String?,
        kind: ProductKind = .food, isWater: Bool = false, timeText: String = ""
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
        self.meal = meal
        self.kind = kind
        self.isWater = isWater
        self.timeText = timeText
    }
    public var iconName: String { EntryRow.symbol(for: self.kind, isWater: self.isWater) }

    /// The amounts and the time on one line: "100 g · 22:13". The amounts alone where no time is known.
    public var detailLine: String {
        timeText.isEmpty ? detail : "\(detail) · \(timeText)"
    }

    /// What a screen reader reads for one row: the name, amounts, time, and meal when it has one.
    /// The kind is spoken because the row's icon is decorative.
    public var accessibilityText: String {
        var parts = [title, detail]
        if !timeText.isEmpty { parts.append(timeText) }
        if let meal { parts.append(meal) }
        parts.append(self.isWater ? "Water" : self.kind.displayName)
        return parts.joined(separator: ", ")
    }
}

/// The entries of one meal on Today, in the order the screen lists them.
public struct TodayMealSection: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let rows: [TodayRow]
    /// The meal's calories, or nil when they cannot be totaled completely. Never 0 for "unknown".
    public var energyKcal: Decimal?

    public init(id: String, title: String, rows: [TodayRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

@MainActor
public final class TodayViewModel: ObservableObject {
    /// What Today totals for everyone, goal or not, in label order. Energy, carbohydrate and fat are here so
    /// the calorie ring and the macro columns show from the first day rather than only once a goal is set.
    public static let defaultTrackedNutrients = ["energy", "protein", "carbohydrate", "fat", "fiber", "sodium", "potassium"]
    public static let undoWindow: TimeInterval = JournalUndo.deleteWindow
    /// The most rows the nutrient card shows.
    public static let nutrientCardLimit = 3
    /// The one importance ranking for the nutrient card, most important first. Source key in each comment:
    /// DGA = Dietary Guidelines for Americans nutrient of public health concern or limit; FDA = Nutrition Facts
    /// label; Journal = a nutrient the goal list offers; Default = tracked by default; Snapshot = a captured compound.
    public static let nutrientCardRanking: [String] = [
        "fiber",           // DGA concern; FDA label; Journal; Default
        "sodium",          // DGA limit; FDA label; Journal; Default
        "potassium",       // DGA concern; FDA label; Journal; Default
        "addedSugars",     // DGA limit; FDA label; Snapshot
        "saturatedFat",    // DGA limit; FDA label; Snapshot
        "calcium",         // DGA concern; FDA label; Journal
        "iron",            // DGA concern; FDA label; Journal
        "vitaminD",        // DGA concern; FDA label; Snapshot (excluded from goals)
        "sugars",          // FDA label; Snapshot
        "cholesterol",     // FDA label; Snapshot
        "transFat",        // FDA label; Snapshot
        "magnesium",       // Journal
        "vitaminC",        // Journal
        "folate",          // Journal
        "vitaminB12",      // Journal
        "zinc",            // Journal
        "vitaminA",        // Snapshot (excluded from goals)
        "vitaminE",        // Snapshot (excluded from goals)
        "vitaminK",        // Journal
        "phosphorus",      // Journal
        "thiamin", "riboflavin", "niacin", "vitaminB6", "pantothenicAcid", "biotin",
        "chloride", "chromium", "copper", "iodine", "manganese", "molybdenum", "selenium", // Journal
    ]
    /// Rows the card never shows: energy and the macros have their own place, and water has its own card.
    static let nutrientCardExcluded: Set<String> = ["energy", "protein", "carbohydrate", "fat", "water"]
    /// Shown when a water amount is zero, negative or not a number.
    public static let waterAmountInvalidMessage = "Enter a water amount above zero."

    @Published public private(set) var rows: [TodayRow] = []
    /// Water today in mL, an exact decimal.
    @Published public private(set) var waterTotalMilliliters: Decimal = 0
    /// Water components skipped because their unit is not a volume (never counted as zero).
    @Published public private(set) var waterSkippedCount: Int = 0
    /// Stored intakes left out of Today because their time zone identifier is not a valid time zone.
    @Published public private(set) var skippedIntakeCount: Int = 0
    @Published public private(set) var coverage: [CoverageLine] = []
    /// One line per tracked nutrient: what the day has reached, against a target where one is set.
    @Published public private(set) var progress: [NutrientProgressLine] = []
    /// The Today nutrient card under the macros: value-only, goal nutrients first, then the rest by
    /// `nutrientCardRanking`, at most `nutrientCardLimit` rows (#817).
    @Published public private(set) var nutrientCard: [GoalBarModel] = []
    /// One bar per tracked nutrient except water, in tracked order. A nutrient with a goal draws a bar;
    /// one without shows its value alone. Built from `progress` and `coverage`, which stay published.
    @Published public private(set) var goalBars: [GoalBarModel] = []
    /// Calories left today: the stored goal, less food, plus burned when the setting counts it. Nil fields are
    /// not stated; `remaining` is nil without a goal or without a known food total.
    @Published public private(set) var calorieRemaining: CalorieRemaining = .none
    /// True only after a load that read the goals and found no calorie goal. False before the first load,
    /// after a failed goal read and after a failed load, so Today never asks for a goal it could not see.
    @Published public private(set) var calorieGoalKnownAbsent = false
    /// Today's active energy from Apple Health, set by the activity card after it reads. Only used
    /// when the person switched on adding it to the calorie goal.
    public var activeEnergyKcal: Decimal?
    /// Health's side of Today's totals, set by the activity card after it reads. Until a read says otherwise
    /// Health is not connected, so the totals stay journal-only.
    public var outsideIntake: HealthIntakeTotals.Outside = .notConnected
    /// Says the calorie goal was raised by activity, and by how much; nil when it was not.
    @Published public private(set) var activityGoalNote: String?
    static let energyKey = "energy"
    /// The water bar, only where a water goal is set; without one the water card shows the total alone.
    @Published public private(set) var waterBar: GoalBarModel?
    /// The day's food, drink, and supplement entries grouped by meal: Breakfast, Lunch, Dinner, Snack, then Other for
    /// an entry with no meal or a free-text one. Sections with no entry are left out, and water entries
    /// are not listed (see `waterEntryCount`).
    @Published public private(set) var mealSections: [TodayMealSection] = []
    /// How many water entries the day holds.
    @Published public private(set) var waterEntryCount: Int = 0
    /// The one line that replaces the Coverage section: how many food and drink entries state no
    /// nutrition values at all. Nil when there are none. Supplements and water are never counted.
    @Published public private(set) var missingValuesSummary: String?
    /// The date under the title, "Tuesday, November 14", in the current device time zone.
    @Published public private(set) var dateSubtitle: String = ""
    /// The `now` of the load whose totals are the ones on screen: set when a load reads the journal successfully
    /// and cleared when the next load starts, so it is nil before the first load and after a load that failed
    /// (its rows and totals may then be partly new). The widgets' summary is stamped with it and only written
    /// while it still equals the load the write was announced for.
    @Published public private(set) var lastLoadedAt: Date?
    @Published public private(set) var undo: UndoHandle?
    @Published public private(set) var errorMessage: String?

    private let store: JournalStore
    private let lookup: NutrientFactsLookup
    /// The goals this screen compares the day against. Optional so a caller with nowhere to keep
    /// goals still gets the totals, which are the larger half of the line.
    private let goals: GoalStore?
    private let trackedNutrients: [String]
    private let timeZoneIdentifier: String
    private let makeID: () -> String
    /// Read on every quick add and every label, rather than copied into this model, so a preference
    /// changed on another screen is honored by the next tap rather than by the next launch.
    private let preferences: DisplayPreferences

    public init(
        store: JournalStore,
        goals: GoalStore? = nil,
        lookup: NutrientFactsLookup = UnknownNutrientFacts(),
        trackedNutrients: [String] = TodayViewModel.defaultTrackedNutrients,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
        preferences: DisplayPreferences = InMemoryDisplayPreferences()
    ) {
        self.store = store
        self.goals = goals
        self.lookup = lookup
        self.trackedNutrients = trackedNutrients
        self.timeZoneIdentifier = timeZoneIdentifier
        self.makeID = makeID
        self.preferences = preferences
    }

    /// The card rows: a nutrient with a known amount above zero today (a partial day's known sum counts), goal
    /// nutrients first, then the rest; each group in `nutrientCardRanking` order, uncategorised ones alphabetically
    /// after; at most `nutrientCardLimit`.
    static func nutrientCardRows(goalBars: [GoalBarModel], progress: [NutrientProgressLine]) -> [GoalBarModel] {
        func progressLine(_ id: String) -> NutrientProgressLine? { progress.first { $0.nutrient == id } }
        func hasValue(_ id: String) -> Bool {
            guard let line = progressLine(id), case .known(let value, _) = line.shownAmount else { return false }
            return value > 0
        }
        func hasGoal(_ id: String) -> Bool { progressLine(id)?.hasGoal == true }
        func rankKey(_ id: String) -> (Int, String) { (nutrientCardRanking.firstIndex(of: id) ?? Int.max, id) }
        let valued = goalBars.filter { !nutrientCardExcluded.contains($0.id) && hasValue($0.id) }
        let withGoal = valued.filter { hasGoal($0.id) }.sorted { rankKey($0.id) < rankKey($1.id) }
        let rest = valued.filter { !hasGoal($0.id) }.sorted { rankKey($0.id) < rankKey($1.id) }
        return Array((withGoal + rest).prefix(nutrientCardLimit))
    }

    /// The tracked list: the fallback's own order first, then the goals' other keys alphabetically.
    ///
    /// What the screen falls back to when a nutrient has no goal: it is still tracked, because the
    /// person logged it, but it shows a plain total rather than a comparison. The order is stated here
    /// once and is not the store's, because `GoalStore.goals()` sorts by nutrient key while the
    /// fallback has an order of its own — asking which of the two leads made the list depend on how
    /// the store happened to return the goals. So the fallback leads in its fixed order, whether or not
    /// those nutrients have goals, and a goal for a nutrient outside it is appended alphabetically, so
    /// the same goals always produce the same screen.
    public static func defaultTrackedNutrientsOrGoals(
        goals: [NutrientGoal], fallback: [String] = TodayViewModel.defaultTrackedNutrients
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let candidates = fallback + goals.map(\.nutrient).sorted()
        for nutrient in candidates where seen.insert(nutrient).inserted {
            ordered.append(nutrient)
        }
        return ordered
    }

    /// Whether Today must reload for these readings: only when the figures it reads from Health changed.
    public static func needsReload(
        activeEnergyKcal: Decimal?, outsideIntake: HealthIntakeTotals.Outside, for readings: BodyActivityReadings
    ) -> Bool {
        activeEnergyKcal != readings.activeEnergyKcal || outsideIntake != readings.outsideIntake
    }

    /// The nutrients a day's totals are summed for: the tracked ones, plus water.
    ///
    /// Water is always among them and is not in the fallback list above, because a drink is logged
    /// whether or not anyone has set a target for it, and a total that only appeared once a target
    /// existed would hide the day's water from anyone who has not set one. It goes at the end rather
    /// than to the front for a goal, because the order is the fallback's fixed one and a goal does not
    /// reorder a day; `JournalViewModel.totalsText` is what puts a targeted nutrient first, on the
    /// one-line summary where the order is a presentational choice.
    public static func totalsNutrients(
        goals: [NutrientGoal], fallback: [String] = TodayViewModel.defaultTrackedNutrients
    ) -> [String] {
        let tracked = defaultTrackedNutrientsOrGoals(goals: goals, fallback: fallback)
        guard !tracked.contains(DailyTotalsBuilder.waterKey) else { return tracked }
        return tracked + [DailyTotalsBuilder.waterKey]
    }

    /// Reloads Today: active intakes on the local day of each intake's own time zone.
    public func load(now: Date) {
        // Nil while a load is in progress and after one that failed, so it only ever names a load whose totals
        // are the ones on screen; a successful load sets it again at the end.
        lastLoadedAt = nil
        do {
            var skippedIntakes = 0
            var intakes: [Intake] = []
            for intake in try store.activeIntakes() where intake.lifecycle == .active {
                guard let sameDay = Self.isSameLocalDay(intake, as: now) else {
                    skippedIntakes += 1
                    continue
                }
                if sameDay { intakes.append(intake) }
            }
            var newRows: [TodayRow] = []
            var waterTotal = Decimal(0)
            var skipped = 0
            var foodComponents: [(component: IntakeComponent, snapshot: ProductDefinition?, kind: ProductKind)] = []
            // One record per food or drink entry, so the entries that state no values can be counted once
            // the tracked nutrients are known.
            var foodEntries: [(components: [IntakeComponent], snapshot: ProductDefinition?, kind: ProductKind)] = []
            var waterEntries = 0
            // Water components that counted as a volume: the only water that is known.
            var countedWater = 0
            // One snapshot is read once per load, however many components and nutrients refer to it.
            var snapshots: [String: ProductDefinition?] = [:]
            let loggedUnits = try LoggedUnitIndex.loadOrThrow(from: store)
            for intake in intakes.sorted(by: { $0.occurredAt > $1.occurredAt }) {
                let revisions = try store.revisions(of: intake.id)
                let current = revisions.first { $0.number == intake.currentRevision }
                let components = current?.components ?? []
                // Read once per entry, and once per snapshot however many components name it: what the
                // entry is comes from the same snapshot its values come from.
                let snapshot = Self.snapshot(of: current, in: &snapshots, using: store)
                // An entry with no product snapshot takes its stored category, so a typed supplement is a supplement;
                // an entry with a snapshot states its kind through that snapshot (#416, #364).
                let kind = ProductKindResolution.kind(
                    snapshotID: current?.productSnapshotID, snapshotKind: { _ in snapshot?.kind }, category: intake.category)
                if intake.category == "water" {
                    waterEntries += 1
                    for component in components {
                        if component.unit.dimension == .volume,
                            Self.isPositive(component.amount),
                            let converted = try? Quantity(value: component.amount, unit: component.unit).converted(to: .mL),
                            Self.isPositive(converted.value)
                        {
                            // A water entry counts its full volume, or volume times its stored share when one is set.
                            waterTotal += converted.value * (component.hydrationPercent ?? 100) / 100
                            countedWater += 1
                        } else {
                            skipped += 1
                        }
                    }
                } else {
                    // A volume component with a stored water share counts volume times share, whatever its product kind.
                    // A component with no stored share (logged before shares) adds no water, as on main.
                    for component in components where component.unit.dimension == .volume {
                        guard Self.isPositive(component.amount),
                            let converted = try? Quantity(value: component.amount, unit: component.unit).converted(to: .mL),
                            Self.isPositive(converted.value),
                            let share = component.hydrationPercent
                        else { continue }
                        waterTotal += converted.value * share / 100
                        // A stored share counts toward the goal bar too, so the bar reads it as a logged amount.
                        countedWater += 1
                    }
                    // Totals count an entry as it always has (#364): a typed entry in the food total, a snapshot-backed
                    // supplement on its own. The row's kind above is what the entry is, not how the totals count it.
                    let countsAs = ProductKindResolution.totalsKind(snapshotKind: snapshot?.kind)
                    if countsAs != .supplement {
                        for component in components { foodComponents.append((component, snapshot, countsAs)) }
                    }
                    foodEntries.append((components, snapshot, countsAs))
                }
                newRows.append(
                    TodayRow(
                        id: intake.id,
                        title: snapshot?.catalogOrigin == IntakeContextFactCatalog.quickAddOrigin
                            ? QuickAddViewModel.rowTitle(components: components, product: snapshot)
                            : components.map(\.name).joined(separator: ", "),
                        detail: components.map {
                            AmountText.describe(
                                $0, unitSystem: unitSystem,
                                loggedUnit: kind == .supplement ? loggedUnits[intake.id]?[$0.componentID] : nil,
                                isSupplement: kind == .supplement)
                        }
                            .joined(separator: ", "),
                        occurredAt: intake.occurredAt,
                        meal: MealLabel.displayName(for: intake.meal),
                        kind: kind,
                        isWater: intake.category == "water",
                        timeText: Self.timeText(intake.occurredAt, zoneIdentifier: intake.timeZoneIdentifier)))
            }
            rows = newRows
            mealSections = Self.makeMealSections(from: newRows)
            waterEntryCount = waterEntries
            dateSubtitle = Self.makeDateSubtitle(now, zoneIdentifier: TimeZone.current.identifier)
            waterTotalMilliliters = waterTotal + Self.outsideWaterMilliliters(outsideIntake)
            waterSkippedCount = skipped
            skippedIntakeCount = skippedIntakes
            // A goal store that cannot be read is not a person with no goals, so the failure is
            // carried out to the screen rather than swallowed into an empty goal list: a target the
            // store holds but this load cannot see would otherwise be shown as a nutrient with no
            // goal set, which is a statement about the person rather than about the store.
            var goalsUnreadable = false
            var storedGoals: [NutrientGoal]
            do {
                storedGoals = try goals?.goals() ?? []
                // First run: store the default water goal once so there is a bar to see. After that
                // the person owns it; removing it or clearing all goals is not undone.
                if let goals, let seeding = preferences as? WaterGoalDefaultPreferences,
                   !seeding.hasSeededWaterGoal {
                    if !storedGoals.contains(where: { $0.nutrient == DailyTotalsBuilder.waterKey }) {
                        // A failed write keeps the goals just read and is retried on the next load.
                        if (try? goals.setGoal(Self.defaultWaterGoal)) != nil {
                            storedGoals.append(Self.defaultWaterGoal)
                            seeding.markWaterGoalSeeded()
                        }
                    } else {
                        seeding.markWaterGoalSeeded()
                    }
                }
            } catch {
                storedGoals = []
                goalsUnreadable = true
            }
            // Today's active energy, when the person asked for it to count: the calorie target grows by
            // what Health reports burned so far. The stored goal is never changed.
            activityGoalNote = nil
            // The stored calorie target before activity is added, for "Calories remaining".
            let storedEnergyTarget = storedGoals.first { $0.nutrient == Self.energyKey && $0.unit == .kcal }?.target
            if let bonus = activeEnergyKcal, bonus > 0,
               (preferences as? ActivityGoalPreferences)?.addsActiveEnergyToGoal == true,
               let index = storedGoals.firstIndex(where: { $0.nutrient == Self.energyKey && $0.unit == .kcal }) {
                let goal = storedGoals[index]
                storedGoals[index] = NutrientGoal(nutrient: goal.nutrient, target: goal.target + bonus, unit: goal.unit)
                activityGoalNote = "Calorie goal includes \(BodyActivityViewModel.whole(bonus)) calories from activity"
            }
            let tracked = Self.totalsNutrients(goals: storedGoals, fallback: trackedNutrients)
            // Coverage is built from the same goal-expanded list the totals are, so a nutrient with
            // a target is also a nutrient the screen says how much of the day is known about. The
            // fixed fallback alone left a targeted nutrient out of Coverage entirely.
            //
            // **Water is left out of Coverage**, which is the section that says how much of what was
            // eaten could not be read: its line counts *foods*, and the values here come from the
            // day's food components, which a drink never joins. A water goal therefore gets a line in
            // Totals, where the day's milliliters are compared with the target, and no line here —
            // counting the day's foods against water would read "2 of 3 foods lack water" for a day
            // whose water was known exactly, and would ignore the drinks that are the only entries
            // that could have said anything. How much of the day's water could not be counted is
            // reported by `waterSkippedCount` on the water row instead.
            coverage = Self.defaultTrackedNutrientsOrGoals(
                goals: storedGoals, fallback: trackedNutrients
            ).filter { $0 != DailyTotalsBuilder.waterKey }.map { nutrient in
                CoverageLine.make(nutrient: nutrient, values: foodComponents.map {
                    DailyTotalsBuilder.value(
                        for: $0.component, snapshot: $0.snapshot, nutrient: nutrient, lookup: lookup)
                }, kinds: foodComponents.map(\.kind))
            }
                // A line with nothing behind it is not shown. That is the day holding no food and no
                // drink at all — only water, or only supplements, which are not foods and are excluded
                // from the count — and "0 of 0 foods lack fiber" tells a reader nothing.
                .filter { $0.total > 0 }
            progress = HealthIntakeTotals.combine(try Self.progressLines(
                tracked: tracked, goals: storedGoals, intakes: intakes, store: store, lookup: lookup,
                displayNames: Self.printedNames(in: snapshots)), outside: outsideIntake)
            mealSections = Self.withMealEnergy(mealSections, intakes: intakes, store: store, lookup: lookup)
            let trackedFood = tracked.filter { $0 != DailyTotalsBuilder.waterKey }
            // A goal switched off on the Goals screen keeps its target and its totals, but no bar.
            let hiddenGoals = hiddenTodayGoals(in: preferences)
            goalBars = progress.compactMap { line -> GoalBarModel? in
                guard line.nutrient != DailyTotalsBuilder.waterKey else { return nil }
                var hasEntries = line.hasKnownAmount
                var someKnown = line.hasKnownAmount
                for entry in foodEntries where entry.kind != .supplement {
                    for component in entry.components {
                        let value = DailyTotalsBuilder.value(
                            for: component, snapshot: entry.snapshot, nutrient: line.nutrient, lookup: self.lookup)
                        if value != .notApplicable { hasEntries = true }
                        if value != .notApplicable && value != .unknown { someKnown = true }
                    }
                }
                // Only a line that still has a goal can be hidden: with the goal gone, its plain total stays.
                // A goal-less row with nothing known has nothing to show. One with some entry known stays,
                // and its note says which entries lack a value.
                if line.hasGoal && hiddenGoals.contains(line.nutrient) { return nil }
                guard line.hasGoal || someKnown else { return nil }
                return GoalBarModel.make(
                    line: line, hasEntries: hasEntries, missingCount: line.missingCount, someKnown: someKnown)
            }
            nutrientCard = Self.nutrientCardRows(goalBars: goalBars, progress: progress)
            waterBar = progress.first {
                $0.nutrient == DailyTotalsBuilder.waterKey && $0.hasGoal
                    && !hiddenGoals.contains(DailyTotalsBuilder.waterKey)
            }.map { line in
                // Water other apps logged to Health counts as logged and known, as it does in the water figure.
                let outsideWater = Self.outsideWaterMilliliters(outsideIntake) > 0
                return GoalBarModel.make(
                    line: line, hasEntries: waterEntries > 0 || countedWater > 0 || outsideWater, missingCount: 0,
                    skippedWaterCount: skipped, someKnown: countedWater > 0 || outsideWater,
                    unitSystem: self.preferences.unitSystem)
            }
            let burnedCounted = (preferences as? ActivityGoalPreferences)?.addsActiveEnergyToGoal == true
            let foodLine = progress.first { $0.nutrient == Self.energyKey }
            calorieGoalKnownAbsent = !goalsUnreadable && storedEnergyTarget == nil
            calorieRemaining = CalorieRemaining.make(
                goal: storedEnergyTarget,
                food: foodLine.flatMap { line -> Decimal? in
                    if case .known(let value, _) = line.shownAmount { return value }
                    return nil
                },
                partial: foodLine?.isPartial ?? false,
                missingCount: foodLine?.missingCount ?? 0,
                burned: burnedCounted ? activeEnergyKcal.flatMap { $0 >= 0 ? $0 : nil } : nil,
                energyLabel: foodLine?.label ?? "Energy")
            missingValuesSummary = Self.makeMissingValuesSummary(
                entries: foodEntries, trackedNutrients: trackedFood, lookup: lookup)
            errorMessage = goalsUnreadable ? GoalsViewModel.readFailedMessage : nil
            lastLoadedAt = now
        } catch {
            // Clear what the last good read showed, so a failed reload never shows old rows as today's.
            rows = []
            mealSections = []
            calorieRemaining = .none
            calorieGoalKnownAbsent = false
            waterTotalMilliliters = 0
            waterEntryCount = 0
            waterSkippedCount = 0
            skippedIntakeCount = 0
            coverage = []
            progress = []
            goalBars = []
            nutrientCard = []
            waterBar = nil
            missingValuesSummary = nil
            activityGoalNote = nil
            dateSubtitle = Self.makeDateSubtitle(now, zoneIdentifier: TimeZone.current.identifier)
            errorMessage = "Could not read the journal."
        }
    }

    /// The vitamins and minerals screen, reading the same journal and nutrient facts as Today and the
    /// reference group kept with the display preferences.
    public func makeNutrientGaps() -> NutrientGapsViewModel {
        NutrientGapsViewModel(
            store: store, lookup: lookup, preferences: preferences as? ReferenceGroupPreferences)
    }

    /// The daily water goal used until the person sets one: 2,000 mL (about 68 fl oz).
    static let defaultWaterGoal = NutrientGoal(
        nutrient: DailyTotalsBuilder.waterKey, target: 2000, unit: .mL)

    /// One-tap container sizes, in milliliters, shown in the unit the reader chose. US sizes are
    /// whole fluid ounces (8, 16, 24) so the labels read as the containers do.
    public var waterPresets: [WaterPreset] {
        let flOz = Decimal(string: "29.5735295625", locale: AmountParser.locale)!
        if AmountDisplay.volumeUnit(for: unitSystem) == .flOz {
            return [("Glass", 8), ("Bottle", 16), ("Large bottle", 24)].map {
                WaterPreset(name: $0.0, milliliters: Decimal($0.1) * flOz, label: "\($0.0) \($0.1) fl oz")
            }
        }
        return [("Glass", 250), ("Bottle", 500), ("Large bottle", 750)].map {
            WaterPreset(name: $0.0, milliliters: Decimal($0.1), label: "\($0.0) \($0.1) mL")
        }
    }

    /// The quick-water amount the preference holds, in milliliters. Read through on every call, so a
    /// glass size changed elsewhere is used by the next tap.
    public var quickWaterMilliliters: Decimal { preferences.quickWaterMilliliters }

    /// The unit the reader sees amounts in.
    public var unitSystem: UnitSystem { preferences.unitSystem }

    /// Writes one water intake (one `create`) and returns the undo handle, valid for 10 seconds.
    ///
    /// `milliliters` defaults to the stored preference rather than to a literal, so the amount is
    /// configured in one place instead of being pinned here.
    @discardableResult
    public func quickAddWater(milliliters: Decimal? = nil, now: Date) -> UndoHandle? {
        let milliliters = milliliters ?? preferences.quickWaterMilliliters
        guard !milliliters.isNaN, milliliters > 0 else {
            errorMessage = Self.waterAmountInvalidMessage
            return nil
        }
        let intake = Intake(
            id: makeID(), category: "water", occurredAt: now, timeZoneIdentifier: timeZoneIdentifier)
        let component = IntakeComponent(componentID: "water", name: "Water", amount: milliliters, unit: .mL)
        do {
            // The place of the write in commit order is taken inside its own commit.
            offerSequence = try store.createSequenced(intake, components: [component], product: nil, now: now).1
        } catch {
            errorMessage = "Could not save the water."
            return nil
        }
        let handle = UndoHandle(intakeID: intake.id, expiresAt: now.addingTimeInterval(Self.undoWindow))
        undo = handle
        load(now: now)
        return handle
    }

    /// Writes one water intake for an amount typed in the volume unit the reader sees: milliliters
    /// under metric, fluid ounces under US. The amount is stored in milliliters and undone exactly like
    /// the quick button. Zero, negative or unreadable text is refused with `errorMessage` and nothing
    /// is written.
    @discardableResult
    public func addWater(typed text: String, now: Date) -> UndoHandle? {
        guard let typed = AmountParser.parseTyped(text), typed > 0 else {
            errorMessage = Self.waterAmountInvalidMessage
            return nil
        }
        let milliliters: Decimal
        if AmountDisplay.volumeUnit(for: unitSystem) == .flOz {
            // Exact factor, the same one the quick-water setting uses: a Decimal product, nothing rounded.
            milliliters = typed * Decimal(string: "29.5735295625", locale: AmountParser.locale)!
        } else {
            milliliters = typed
        }
        errorMessage = nil
        return quickAddWater(milliliters: milliliters, now: now)
    }

    /// The unit symbol of the volume unit the typed water amount is read in: "mL" or "fl oz".
    public var otherWaterUnitSymbol: String { AmountDisplay.volumeUnit(for: unitSystem).symbol }

    /// The label of the typed water field, naming the unit: "Water amount in mL".
    public var otherWaterFieldLabel: String { "Water amount in \(otherWaterUnitSymbol)" }

    public func isUndoAvailable(now: Date) -> Bool {
        guard let undo else { return false }
        return now < undo.expiresAt
    }

    /// Deletes the last quick-added water while the window is open. Returns false once it expired.
    @discardableResult
    public func undoLastQuickAdd(now: Date) -> Bool {
        guard let handle = undo, now < handle.expiresAt else {
            undo = nil
            return false
        }
        do {
            if handle.isDelete {
                try store.undoDelete(intakeID: handle.intakeID)
            } else {
                try store.delete(intakeID: handle.intakeID, now: now)
            }
        } catch {
            errorMessage = "Could not undo."
            return false
        }
        undo = nil
        load(now: now)
        return true
    }

    /// Where the offer on screen sits in the store's commit order: the delete it offers, or the latest water.
    private var offerSequence: UInt64 = 0

    /// A delete committed anywhere in the app, reported with its place in commit order. Undo is offered for the
    /// most recent change only, so the offer goes only when a delete committed after it. A late hook for an
    /// earlier delete, or for the offered delete itself, carries a lower or equal place and leaves it alone.
    public func deleteCommitted(sequence: UInt64) {
        guard undo != nil, sequence > offerSequence else { return }
        undo = nil
    }

    /// Deletes an entry from Today, offering Undo for the window. Nothing reaches Apple Health until it passes.
    @discardableResult
    public func deleteEntry(intakeID: String, now: Date) -> Bool {
        do {
            offerSequence = try store.deleteSequenced(intakeID: intakeID, now: now)
        } catch {
            errorMessage = "Could not delete the entry."
            return false
        }
        errorMessage = nil
        undo = UndoHandle(
            intakeID: intakeID, expiresAt: now.addingTimeInterval(Self.undoWindow), isDelete: true)
        load(now: now)
        return true
    }

    /// The water other apps logged to Apple Health today, in millilitres, added to Today's water the way their
    /// nutrients are added to Today's lines. The read leaves out the samples this app wrote, so a drink logged here
    /// is never counted twice. A read that did not complete, or Health not connected, adds nothing.
    static func outsideWaterMilliliters(_ outside: HealthIntakeTotals.Outside) -> Decimal {
        guard case .read(let values, let readKeys) = outside,
              readKeys.contains(DailyTotalsBuilder.waterKey),
              let value = values[DailyTotalsBuilder.waterKey],
              let unit = HealthKitWritePlanner.mapping(for: DailyTotalsBuilder.waterKey)?.unit,
              let milliliters = try? Quantity(value: value, unit: unit).converted(to: .mL)
        else { return 0 }
        return milliliters.value
    }

    /// The water total in the unit the reader chose, as it is shown on screen.
    public var waterTotalDisplay: DisplayAmount {
        AmountDisplay.water(self.waterTotalMilliliters, system: self.preferences.unitSystem)
    }

    /// The quick-water amount in the unit the reader chose.
    public var quickWaterDisplay: DisplayAmount {
        AmountDisplay.display(quickWaterMilliliters, unit: .mL, system: unitSystem, roundsStoredUnit: true)
    }

    /// One line for the quick-add button, naming the amount it adds and in the unit shown.
    public var quickWaterLabel: String {
        "Add \(quickWaterDisplay.text) water"
    }

    /// The same line, spelled out for a screen reader: "Add 250 milliliters of water".
    public var quickWaterAccessibilityLabel: String {
        "Add \(quickWaterDisplay.spokenAmount) "
            + "\(AmountDisplay.spokenName(for: quickWaterDisplay.unit)) of water"
    }

    /// Spoken summary of the water total for assistive technology. Built from the same bound-aware
    /// figures as the label, so an amount too small for the shown unit is spoken as less than that
    /// rather than as a zero that is not there.
    public var waterAccessibilityValue: String {
        "\(waterTotalDisplay.spokenAmount) "
            + "\(AmountDisplay.spokenName(for: waterTotalDisplay.unit)) today"
    }

    /// The meal sections for a list of rows. Water rows are left out; a meal that is not one of the four
    /// the app names, or none at all, is Other.
    static func makeMealSections(from rows: [TodayRow]) -> [TodayMealSection] {
        let named = MealLabel.allCases.map(\.displayName)
        var buckets: [String: [TodayRow]] = [:]
        for row in rows where !row.isWater {
            let title = row.meal.flatMap { named.contains($0) ? $0 : nil } ?? "Other"
            buckets[title, default: []].append(row)
        }
        return (named + ["Other"]).compactMap { title in
            buckets[title].map { TodayMealSection(id: title, title: title, rows: $0) }
        }
    }

    /// "2 entries have no nutrition values", or nil. An entry counts when it is a food or a drink whose
    /// tracked snapshot values are all unknown and whose components the lookup knows nothing about.
    /// A supplement never counts: stating no macros is what it is.
    static func makeMissingValuesSummary(
        entries: [(components: [IntakeComponent], snapshot: ProductDefinition?, kind: ProductKind)],
        trackedNutrients: [String], lookup: NutrientFactsLookup
    ) -> String? {
        var missing = 0
        for entry in entries where entry.kind != .supplement {
            if let snapshot = entry.snapshot,
                trackedNutrients.contains(where: { snapshot.value(for: $0) != .unknown })
            { continue }
            let known = entry.components.contains { component in
                trackedNutrients.contains { nutrient in
                    DailyTotalsBuilder.value(
                        for: component, snapshot: entry.snapshot, nutrient: nutrient, lookup: lookup).isKnown
                }
            }
            if !known { missing += 1 }
        }
        switch missing {
        case 0: return nil
        case 1: return "1 entry has no nutrition values"
        default: return "\(missing) entries have no nutrition values"
        }
    }

    /// "22:13" in the given zone, with a fixed locale so the figure never depends on the device's.
    static func timeText(_ date: Date, zoneIdentifier: String) -> String {
        formatted(date, format: "HH:mm", zoneIdentifier: zoneIdentifier)
    }

    /// "Tuesday, November 14" in the given zone.
    static func makeDateSubtitle(_ date: Date, zoneIdentifier: String) -> String {
        formatted(date, format: "EEEE, MMMM d", zoneIdentifier: zoneIdentifier)
    }

    private static func formatted(_ date: Date, format: String, zoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zoneIdentifier) ?? TimeZone.current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func isPositive(_ value: Decimal) -> Bool {
        !value.isNaN && value > 0
    }

    /// Each named meal's calories, summed from that meal's own intakes with the same totals builder as
    /// the day. A meal with any unknown energy shows no figure rather than a partial one. A meal whose
    /// totals cannot be read shows no figure too, so the header never fails the load.
    /// Entries with no meal ("Other") and water are left out.
    private static func withMealEnergy(
        _ sections: [TodayMealSection], intakes: [Intake], store: JournalStore, lookup: NutrientFactsLookup
    ) -> [TodayMealSection] {
        let named = MealLabel.allCases.map(\.displayName)
        return sections.map { section in
            var section = section
            guard named.contains(section.title) else { return section }
            let mealIntakes = intakes.filter { intake in
                guard intake.category != DailyTotalsBuilder.waterCategory else { return false }
                let meal = MealLabel.displayName(for: intake.meal).flatMap { named.contains($0) ? $0 : nil }
                return meal == section.title
            }
            guard !mealIntakes.isEmpty else { return section }
            guard let totals = try? DailyTotalsBuilder.totals(
                for: mealIntakes, store: store, lookup: lookup, nutrients: [energyKey]) else { return section }
            if let total = totals.total(for: energyKey), !total.coverage.hasUnknown,
               case .known(let kcal, _) = total.value {
                section.energyKcal = kcal
            }
            return section
        }
    }

    /// The lines Today shows, one per tracked nutrient and in the order they are tracked.
    ///
    /// Throwing rather than swallowing: the totals are built from the same intakes the rows above
    /// were built from, so a store that cannot be read has already failed the load and there is
    /// nothing honest left to show.
    private static func progressLines(
        tracked: [String], goals: [NutrientGoal], intakes: [Intake], store: JournalStore,
        lookup: NutrientFactsLookup, displayNames: [String: String]
    ) throws -> [NutrientProgressLine] {
        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: lookup, nutrients: tracked)
        return tracked.map { nutrient in
            NutrientProgressLine.make(
                nutrient: nutrient, total: totals.total(for: nutrient),
                goal: goals.first { $0.nutrient == nutrient },
                displayName: NutrientNames.displayName(for: nutrient, displayNames: displayNames),
                knownSum: totals.knownSum(for: nutrient), missingCount: totals.missingCount(for: nutrient))
        }
    }

    /// The printed names the day's snapshots carry, keyed by nutrient, so a compound reads under the
    /// words the label used (`DHA`, never `Dha`).
    private static func printedNames(in snapshots: [String: ProductDefinition?]) -> [String: String] {
        var names: [String: String] = [:]
        for product in snapshots.values.compactMap({ $0 }) {
            for (key, name) in product.nutrientDisplayNames { names[key] = name }
        }
        return names
    }

    /// The product snapshot a revision points at, read at most once per snapshot id. A snapshot that
    /// cannot be read is nil, which the lookup answers as unknown rather than as zero.
    private static func snapshot(
        of revision: IntakeRevision?, in cache: inout [String: ProductDefinition?], using store: JournalStore
    ) -> ProductDefinition? {
        guard let id = revision?.productSnapshotID else { return nil }
        if let cached = cache[id] { return cached }
        let found = try? store.product(snapshotID: id)
        cache[id] = found
        return found
    }

    /// Nil when the intake's stored time zone identifier is not a valid time zone (no fallback).
    static func isSameLocalDay(_ intake: Intake, as now: Date) -> Bool? {
        guard let zone = TimeZone(identifier: intake.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(intake.occurredAt, inSameDayAs: now)
    }

    }

/// Locale-independent decimal text.
enum DecimalFormatting {
    static func text(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }
}


/// A one-tap water container: a name, the exact amount in milliliters and its on-screen label.
public struct WaterPreset: Hashable, Sendable, Identifiable {
    public let name: String
    public let milliliters: Decimal
    public let label: String
    public var id: String { name }
}
