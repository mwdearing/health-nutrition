import Foundation
import NutritionDomain
import NutritionJournal

/// A water entry that can still be taken back.
public struct UndoHandle: Equatable {
    public let intakeID: String
    public let expiresAt: Date
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

    public init(id: String, title: String, rows: [TodayRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

@MainActor
public final class TodayViewModel: ObservableObject {
    public static let defaultTrackedNutrients = ["potassium", "sodium", "protein", "fiber"]
    public static let undoWindow: TimeInterval = 10
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
    /// One bar per tracked nutrient except water, in tracked order. A nutrient with a goal draws a bar;
    /// one without shows its value alone. Built from `progress` and `coverage`, which stay published.
    @Published public private(set) var goalBars: [GoalBarModel] = []
    /// The water bar, only where a water goal is set; without one the water card shows the total alone.
    @Published public private(set) var waterBar: GoalBarModel?
    /// The day's food and drink entries grouped by meal: Breakfast, Lunch, Dinner, Snack, then Other for
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
            // One snapshot is read once per load, however many components and nutrients refer to it.
            var snapshots: [String: ProductDefinition?] = [:]
            for intake in intakes.sorted(by: { $0.occurredAt > $1.occurredAt }) {
                let revisions = try store.revisions(of: intake.id)
                let current = revisions.first { $0.number == intake.currentRevision }
                let components = current?.components ?? []
                // Read once per entry, and once per snapshot however many components name it: what the
                // entry is comes from the same snapshot its values come from.
                let snapshot = Self.snapshot(of: current, in: &snapshots, using: store)
                // An entry typed by hand has no product to say what it is, so it is the food it was
                // always recorded as; a snapshot's own kind is what an entry with a product states.
                let kind = snapshot?.kind ?? .food
                if intake.category == "water" {
                    waterEntries += 1
                    for component in components {
                        if component.unit.dimension == .volume,
                            Self.isPositive(component.amount),
                            let converted = try? Quantity(value: component.amount, unit: component.unit).converted(to: .mL),
                            Self.isPositive(converted.value)
                        {
                            waterTotal += converted.value
                        } else {
                            skipped += 1
                        }
                    }
                } else {
                    if kind != .supplement {
                        for component in components { foodComponents.append((component, snapshot, kind)) }
                    }
                    foodEntries.append((components, snapshot, kind))
                }
                newRows.append(
                    TodayRow(
                        id: intake.id,
                        title: components.map(\.name).joined(separator: ", "),
                        detail: components.map { AmountText.describe($0, unitSystem: unitSystem) }
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
            waterTotalMilliliters = waterTotal
            waterSkippedCount = skipped
            skippedIntakeCount = skippedIntakes
            // A goal store that cannot be read is not a person with no goals, so the failure is
            // carried out to the screen rather than swallowed into an empty goal list: a target the
            // store holds but this load cannot see would otherwise be shown as a nutrient with no
            // goal set, which is a statement about the person rather than about the store.
            var goalsUnreadable = false
            let storedGoals: [NutrientGoal]
            do {
                storedGoals = try goals?.goals() ?? []
            } catch {
                storedGoals = []
                goalsUnreadable = true
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
            progress = try Self.progressLines(
                tracked: tracked, goals: storedGoals, intakes: intakes, store: store, lookup: lookup,
                displayNames: Self.printedNames(in: snapshots))
            let trackedFood = tracked.filter { $0 != DailyTotalsBuilder.waterKey }
            goalBars = progress.filter { $0.nutrient != DailyTotalsBuilder.waterKey }.map { line in
                var hasEntries = line.hasKnownAmount
                var missingCount = 0
                for entry in foodEntries where entry.kind != .supplement {
                    var entryMissing = false
                    for component in entry.components {
                        let value = DailyTotalsBuilder.value(
                            for: component, snapshot: entry.snapshot, nutrient: line.nutrient, lookup: self.lookup)
                        if value != .notApplicable { hasEntries = true }
                        if value == .unknown { entryMissing = true }
                    }
                    if entryMissing { missingCount += 1 }
                }
                return GoalBarModel.make(
                    line: line, hasEntries: hasEntries, missingCount: missingCount)
            }
            waterBar = progress.first { $0.nutrient == DailyTotalsBuilder.waterKey && $0.hasGoal }.map { line in
                GoalBarModel.make(
                    line: line, hasEntries: waterEntries > 0, missingCount: 0, skippedWaterCount: skipped,
                    unitSystem: self.preferences.unitSystem)
            }
            missingValuesSummary = Self.makeMissingValuesSummary(
                entries: foodEntries, trackedNutrients: trackedFood, lookup: lookup)
            errorMessage = goalsUnreadable ? GoalsViewModel.readFailedMessage : nil
        } catch {
            errorMessage = "Could not read the journal."
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
            try store.create(intake, components: [component], product: nil, now: now)
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
            try store.delete(intakeID: handle.intakeID, now: now)
        } catch {
            errorMessage = "Could not undo."
            return false
        }
        undo = nil
        load(now: now)
        return true
    }

    /// The water total in the unit the reader chose, as it is shown on screen.
    public var waterTotalDisplay: DisplayAmount {
        AmountDisplay.water(self.waterTotalMilliliters, system: self.preferences.unitSystem)
    }

    /// The quick-water amount in the unit the reader chose.
    public var quickWaterDisplay: DisplayAmount {
        AmountDisplay.display(quickWaterMilliliters, unit: .mL, system: unitSystem)
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
                displayName: NutrientNames.displayName(for: nutrient, displayNames: displayNames))
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
