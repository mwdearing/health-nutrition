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

    /// What a screen reader reads for one row: the name, the amounts, and the meal when it has one.
    public var accessibilityText: String {
        guard let meal else { return "\(title), \(detail)" }
        return "\(title), \(detail), \(meal)"
    }
}

@MainActor
public final class TodayViewModel: ObservableObject {
    public static let defaultTrackedNutrients = ["potassium", "sodium", "protein", "fiber"]
    public static let undoWindow: TimeInterval = 10

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
    /// changed on another screen is honoured by the next tap rather than by the next launch.
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
            var foodComponents: [(component: IntakeComponent, snapshot: ProductDefinition?)] = []
            // One snapshot is read once per load, however many components and nutrients refer to it.
            var snapshots: [String: ProductDefinition?] = [:]
            for intake in intakes.sorted(by: { $0.occurredAt > $1.occurredAt }) {
                let revisions = try store.revisions(of: intake.id)
                let current = revisions.first { $0.number == intake.currentRevision }
                let components = current?.components ?? []
                if intake.category == "water" {
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
                    let snapshot = Self.snapshot(of: current, in: &snapshots, using: store)
                    for component in components { foodComponents.append((component, snapshot)) }
                }
                newRows.append(
                    TodayRow(
                        id: intake.id,
                        title: components.map(\.name).joined(separator: ", "),
                        detail: components.map { AmountText.describe($0, unitSystem: unitSystem) }
                            .joined(separator: ", "),
                        occurredAt: intake.occurredAt,
                        meal: MealLabel.displayName(for: intake.meal)))
            }
            rows = newRows
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
            coverage = Self.defaultTrackedNutrientsOrGoals(
                goals: storedGoals, fallback: trackedNutrients
            ).map { nutrient in
                CoverageLine.make(nutrient: nutrient, values: foodComponents.map {
                    DailyTotalsBuilder.value(
                        for: $0.component, snapshot: $0.snapshot, nutrient: nutrient, lookup: lookup)
                })
            }
            progress = try Self.progressLines(
                tracked: tracked, goals: storedGoals, intakes: intakes, store: store, lookup: lookup)
            errorMessage = goalsUnreadable ? GoalsViewModel.readFailedMessage : nil
        } catch {
            errorMessage = "Could not read the journal."
        }
    }

    /// The quick-water amount the preference holds, in millilitres. Read through on every call, so a
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
            errorMessage = "Enter a water amount above zero."
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
        AmountDisplay.display(waterTotalMilliliters, unit: .mL, system: preferences.unitSystem)
    }

    /// The quick-water amount in the unit the reader chose.
    public var quickWaterDisplay: DisplayAmount {
        AmountDisplay.display(quickWaterMilliliters, unit: .mL, system: unitSystem)
    }

    /// One line for the quick-add button, naming the amount it adds and in the unit shown.
    public var quickWaterLabel: String {
        "Add \(quickWaterDisplay.text) water"
    }

    /// The same line, spelled out for a screen reader: "Add 250 millilitres of water".
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
        lookup: NutrientFactsLookup
    ) throws -> [NutrientProgressLine] {
        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: lookup, nutrients: tracked)
        return tracked.map { nutrient in
            NutrientProgressLine.make(
                nutrient: nutrient, total: totals.total(for: nutrient),
                goal: goals.first { $0.nutrient == nutrient })
        }
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
