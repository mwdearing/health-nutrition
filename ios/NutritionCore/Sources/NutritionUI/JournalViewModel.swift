import Foundation
import NutritionDomain
import NutritionJournal

public struct JournalRow: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let occurredAt: Date
    public let timeZoneIdentifier: String
    /// The meal as words, or nil when the entry states none. Carried on the row so the screens that
    /// list an entry can say which meal it was without reading the journal again.
    public let meal: String?
    /// What kind of product the entry was recorded with, read from the same snapshot its amounts come
    /// from. Food unless that snapshot says otherwise, which is what an entry typed by hand is.
    public let kind: ProductKind
    public let isWater: Bool

    public var iconName: String { EntryRow.symbol(for: self.kind, isWater: self.isWater) }

    public init(
        id: String, title: String, detail: String, occurredAt: Date, timeZoneIdentifier: String,
        meal: String?, kind: ProductKind = .food, isWater: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.meal = meal
        self.kind = kind
        self.isWater = isWater
    }

    /// What a screen reader reads for one row: the name, the amounts, and the meal when it has one.
    /// The kind is spoken because the row's icon is decorative.
    public var accessibilityText: String {
        var parts = [title, detail]
        if let meal { parts.append(meal) }
        parts.append(self.isWater ? "Water" : self.kind.displayName)
        return parts.joined(separator: ", ")
    }
}

/// The entries of one meal in a journal day, in the order the day lists them.
public struct JournalMealGroup: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let rows: [JournalRow]

    public init(id: String, title: String, rows: [JournalRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

public struct JournalDaySection: Equatable, Identifiable {
    /// Local day in the intakes' own time zone, as yyyy-MM-dd.
    public let id: String
    /// Locale-formatted day (medium date style) in the intakes' own time zone.
    public let title: String
    public let rows: [JournalRow]
    /// What this day adds up to, summed from the same intakes as the rows above and never from
    /// another day.
    public let totals: DailyTotals
    /// One compact line for the day: each tracked nutrient against its target where one is set.
    public let totalsText: String
    /// The day's entries grouped by meal: the four named meals in order, then "Other".
    public let mealGroups: [JournalMealGroup]
    /// One bar per stored goal, water excluded, in the stored goals' order, at most three.
    public let headerBars: [GoalBarModel]
    /// The day's energy when its total is known, such as "1240 kcal"; nil when it is not.
    public let energyText: String?
    /// True when the day is more than seven days before the day of `now`, in the entry's own zone.
    public let isCollapsedByDefault: Bool
    /// "1 entry" or "9 entries".
    public let entryCountText: String

    public init(
        id: String, title: String, rows: [JournalRow], totals: DailyTotals, totalsText: String,
        mealGroups: [JournalMealGroup], headerBars: [GoalBarModel], energyText: String?,
        isCollapsedByDefault: Bool, entryCountText: String
    ) {
        self.id = id
        self.title = title
        self.rows = rows
        self.totals = totals
        self.totalsText = totalsText
        self.mealGroups = mealGroups
        self.headerBars = headerBars
        self.energyText = energyText
        self.isCollapsedByDefault = isCollapsedByDefault
        self.entryCountText = entryCountText
    }
}

/// Where a jump to a picked day lands. `sectionID` is the day to scroll to, nil only when the journal has
/// no entries at all. `message` is the sentence to show, or nil when the picked day had entries.
public struct JournalJumpTarget: Equatable {
    public let sectionID: String?
    public let message: String?

    public init(sectionID: String?, message: String?) {
        self.sectionID = sectionID
        self.message = message
    }
}

/// The week at the top of the Journal: how many of the seven local days ending today have food or drink,
/// and one line per goal that shows on Today.
public struct JournalWeekSummary: Equatable {
    /// "Logged 3 of 7 days", or "Nothing logged this week." when no day of the week has food or drink.
    public let headline: String
    /// One line per goal that shows on Today, water left out, at most three, in the stored order, such as
    /// "Protein: average 42 g a day against 60 g". Empty when nothing was logged this week.
    public let goalLines: [String]

    public init(headline: String, goalLines: [String]) {
        self.headline = headline
        self.goalLines = goalLines
    }
}

@MainActor
public final class JournalViewModel: ObservableObject {
    @Published public private(set) var sections: [JournalDaySection] = []
    /// Intakes left out because their time zone identifier is invalid or their record could not be read.
    @Published public private(set) var skippedCount: Int = 0
    /// How many times the journal has finished loading. The screen watches it to drop state tied to an earlier load.
    @Published public private(set) var loadCount = 0
    @Published public private(set) var errorMessage: String?
    /// Set when the stored goals cannot be read. The days still load, with no goal bars.
    @Published public private(set) var goalsErrorMessage: String?
    /// The days the person has opened. Only an old day (more than a week back) starts collapsed.
    @Published public private(set) var expandedDays: Set<String> = []
    /// The seven local days ending today, read from the loaded sections. Nil until a load finds an entry.
    @Published public private(set) var weekSummary: JournalWeekSummary?
    /// True once a load has completed without failing, so the empty state is never shown before one.
    private var hasLoaded = false

    /// The nutrient key for energy, which the day header shows beside its goal bars.
    private static let energyKey = "energy"

    private let store: JournalStore
    private let lookup: NutrientFactsLookup
    /// The goals each day's line compares against. Optional, so a caller with no goal store still
    /// gets the per-day totals.
    private let goals: GoalStore?
    private let repeater: IntakeRepeater
    /// The zone a picked day is read in, and the zone "today" is read in for a future date. The same
    /// resolved zone the repeater uses, so the device zone in production and "UTC" in tests.
    private let journalZoneID: () -> String
    private let locale: Locale
    private let preferences: DisplayPreferences

    public init(
        store: JournalStore,
        goals: GoalStore? = nil,
        lookup: NutrientFactsLookup = UnknownNutrientFacts(),
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        locale: Locale = .current,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
        preferences: DisplayPreferences = InMemoryDisplayPreferences()
    ) {
        self.store = store
        self.lookup = lookup
        self.goals = goals
        self.locale = locale
        self.preferences = preferences
        let zoneID = IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider)
        self.journalZoneID = zoneID
        self.repeater = IntakeRepeater(store: store, timeZoneProvider: zoneID, makeID: makeID)
    }

    /// Groups active intakes by the local day of each intake's own time zone, newest first.
    public func load(now: Date) {
        defer { loadCount += 1 }
        do {
            var skipped = 0
            var groups: [String: [JournalRow]] = [:]
            var titles: [String: String] = [:]
            // The intakes of each day, kept beside the rows so the day's totals are summed from
            // exactly the entries the rows below were built from. Nothing here ever sees two days.
            var intakesByDay: [String: [Intake]] = [:]
            // One snapshot is read once per load, however many entries name it.
            var snapshots: [String: ProductDefinition?] = [:]
            for intake in try store.activeIntakes() where intake.lifecycle == .active {
                guard let zone = TimeZone(identifier: intake.timeZoneIdentifier) else {
                    skipped += 1
                    continue
                }
                guard let revisions = try? store.revisions(of: intake.id),
                    let current = revisions.first(where: { $0.number == intake.currentRevision })
                else {
                    skipped += 1
                    continue
                }
                let row = JournalRow(
                    id: intake.id, title: AmountText.title(current.components),
                    detail: current.components.isEmpty ? "unknown" : current.components.map { component in
                        guard intake.category == "water", !component.amount.isNaN else {
                            return AmountText.describe(component)
                        }
                        return AmountDisplay.water(
                            component.amount, unit: component.unit, system: self.preferences.unitSystem).text
                    }.joined(separator: ", "),
                    occurredAt: intake.occurredAt,
                    timeZoneIdentifier: intake.timeZoneIdentifier,
                    meal: MealLabel.displayName(for: intake.meal),
                    kind: Self.snapshot(of: current, in: &snapshots, using: store)?.kind ?? .food,
                    isWater: intake.category == "water")
                let key = Self.dayKey(intake.occurredAt, zone: zone)
                if titles[key] == nil {
                    titles[key] = Self.dayTitle(intake.occurredAt, zone: zone, locale: locale)
                }
                groups[key, default: []].append(row)
                intakesByDay[key, default: []].append(intake)
            }
            // A goal store that cannot be read is reported, not taken for a person with no goals.
            var goalsReadFailed = false
            let storedGoals: [NutrientGoal]
            do {
                storedGoals = try goals?.goals() ?? []
            } catch {
                storedGoals = []
                goalsReadFailed = true
            }
            let tracked = TodayViewModel.totalsNutrients(goals: storedGoals)
            // Energy is read once per day alongside the tracked nutrients, for the header. The summary
            // line still names only the tracked ones, so it does not change.
            let queried = tracked.contains(Self.energyKey) ? tracked : tracked + [Self.energyKey]
            // The same choice as Today: a goal switched off there gets no bar in the day header either.
            let hiddenGoals = hiddenTodayGoals(in: preferences)
            sections = try groups.keys.sorted(by: >).map { key in
                let totals = try DailyTotalsBuilder.totals(
                    for: intakesByDay[key] ?? [], store: store, lookup: lookup, nutrients: queried)
                let rows = (groups[key] ?? []).sorted { $0.occurredAt > $1.occurredAt }
                return JournalDaySection(
                    id: key, title: titles[key] ?? key, rows: rows, totals: totals,
                    totalsText: Self.totalsText(
                        totals: totals, tracked: tracked, goals: storedGoals, unitSystem: self.preferences.unitSystem),
                    mealGroups: Self.mealGroups(for: rows),
                    headerBars: Self.headerBars(
                        totals: totals, goals: storedGoals, hasFoodEntries: Self.hasFoodEntries(rows),
                        unitSystem: self.preferences.unitSystem, hidden: hiddenGoals),
                    energyText: Self.energyText(totals: totals),
                    isCollapsedByDefault: rows.allSatisfy { row in
                        let zone = TimeZone(identifier: row.timeZoneIdentifier) ?? TimeZone.current
                        return Self.isMoreThanAWeekBefore(Self.dayKey(row.occurredAt, zone: zone), now: now, zone: zone)
                    },
                    entryCountText: Self.entryCountText(rows.count))
            }
            weekSummary = Self.makeWeekSummary(
                sections: sections, now: now,
                zone: TimeZone(identifier: journalZoneID()) ?? TimeZone.current,
                goals: storedGoals, hidden: hiddenGoals, unitSystem: self.preferences.unitSystem)
            skippedCount = skipped
            errorMessage = nil
            goalsErrorMessage = goalsReadFailed ? GoalsViewModel.readFailedMessage : nil
            hasLoaded = true
        } catch {
            errorMessage = "Could not read the journal."
        }
    }

    /// True when nothing is listed after a successful load: no day and no skipped entry.
    public var isEmpty: Bool {
        hasLoaded && errorMessage == nil && sections.isEmpty && skippedCount == 0
    }

    /// The one sentence about skipped entries, singular or plural, or nil when none were skipped.
    public var skippedText: String? {
        switch skippedCount {
        case 0:
            return nil
        case 1:
            return "1 entry can't be shown because its saved time or record can't be read."
        default:
            return "\(skippedCount) entries can't be shown because their saved time or record can't be read."
        }
    }

    /// Opens the day a jump landed on when it starts collapsed, so the person sees its entries and not a
    /// button. A day that is already open, or a jump with no day, changes nothing.
    public func reveal(_ target: JournalJumpTarget) {
        guard let id = target.sectionID, let section = sections.first(where: { $0.id == id }),
              !isExpanded(section)
        else { return }
        toggleDay(id)
    }

    /// Opens a collapsed day, or collapses an open one.
    public func toggleDay(_ id: String) {
        if expandedDays.contains(id) {
            expandedDays.remove(id)
        } else {
            expandedDays.insert(id)
        }
    }

    /// Where a picked day lands. A day with entries is its own section with no sentence. A day with none
    /// goes to the closest day that has entries (a tie goes to the newer day) with the sentence naming the
    /// picked day. A date after today is treated as today. With no entries at all there is no section.
    /// Sections are keyed by each entry's own local day, so the picked day is compared as a day key.
    public func jumpTarget(for date: Date, now: Date) -> JournalJumpTarget {
        guard !sections.isEmpty else {
            // Entries that could not be read, or a journal that failed to load, are not an empty journal:
            // the screen already says so, and "Nothing logged yet." would be false.
            let unreadable = skippedCount > 0 || errorMessage != nil
            return JournalJumpTarget(sectionID: nil, message: unreadable ? nil : "Nothing logged yet.")
        }
        let zone = TimeZone(identifier: journalZoneID()) ?? TimeZone.current
        let today = Self.dayKey(now, zone: zone)
        var key = Self.dayKey(date, zone: zone)
        if key > today { key = today }
        if let exact = sections.first(where: { $0.id == key }) {
            return JournalJumpTarget(sectionID: exact.id, message: nil)
        }
        let closest = sections.min { lhs, rhs in
            let left = Self.dayDistance(lhs.id, key)
            let right = Self.dayDistance(rhs.id, key)
            if left != right { return left < right }
            return lhs.id > rhs.id
        }
        guard let closest, let pickedDay = Self.utcDate(fromDayKey: key) else {
            return JournalJumpTarget(sectionID: sections.first?.id, message: nil)
        }
        let title = Self.dayTitle(pickedDay, zone: TimeZone(secondsFromGMT: 0) ?? .current, locale: locale)
        return JournalJumpTarget(
            sectionID: closest.id,
            message: "Nothing logged on \(title). Showing the closest day with entries.")
    }

    /// Whole days between two yyyy-MM-dd keys, or Int.max when either key cannot be read.
    private static func dayDistance(_ first: String, _ second: String) -> Int {
        guard let start = utcDate(fromDayKey: first), let end = utcDate(fromDayKey: second) else {
            return Int.max
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return abs(calendar.dateComponents([.day], from: start, to: end).day ?? Int.max)
    }

    /// A day shows its entries unless it is collapsed by default and has not been opened.
    public func isExpanded(_ section: JournalDaySection) -> Bool {
        !section.isCollapsedByDefault || expandedDays.contains(section.id)
    }

    /// Creates a new intake from an existing one (one `create`); the original is untouched.
    @discardableResult
    public func repeatIntake(_ intakeID: String, now: Date) -> String? {
        do {
            guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }) else {
                errorMessage = "This entry is no longer available."
                return nil
            }
            let newID = try repeater.create(repeating: intake, now: now)
            load(now: now)
            return newID
        } catch IntakeRepeatError.productUnavailable {
            errorMessage = IntakeRepeatError.productUnavailableMessage
            return nil
        } catch {
            errorMessage = "Could not repeat the entry."
            return nil
        }
    }

    /// The day's whole figure on one line, the nutrients with a target first.
    ///
    /// A nutrient the day cannot answer for is left out rather than written as "unknown": this is a
    /// summary line over a list of entries, and the entries below it say which ones could not be
    /// read. A day where nothing at all is known says so on its own.
    static func totalsText(
        totals: DailyTotals, tracked: [String], goals: [NutrientGoal], unitSystem: UnitSystem = .metric
    ) -> String {
        let withTarget = goals.map { $0.nutrient }
        let ordered = withTarget + tracked.filter { !withTarget.contains($0) }
        let parts = ordered.compactMap { nutrient -> String? in
            let line = NutrientProgressLine.make(
                nutrient: nutrient, total: totals.total(for: nutrient),
                goal: goals.first { $0.nutrient == nutrient })
            // A nutrient the day cannot answer for is left off rather than written as "unknown": this
            // is a summary over a list of entries, and the entries below it say which could not be read.
            guard line.hasKnownAmount else { return nil }
            if nutrient == DailyTotalsBuilder.waterKey, case .known(let amount, let unit) = line.amount {
                let totalText = "\(line.label) \(AmountDisplay.water(amount, unit: unit, system: unitSystem).text)"
                guard let goal = line.goal else { return totalText }
                return "\(totalText) of \(AmountDisplay.water(goal.target, unit: goal.unit, system: unitSystem).text)"
            }
            return line.text
        }
        return parts.isEmpty ? "No totals for this day." : parts.joined(separator: ", ")
    }

    /// The product snapshot a revision points at, read at most once per snapshot id. A snapshot that
    /// cannot be read is nil, which the row reads as the food an entry without a product always was.
    private static func snapshot(
        of revision: IntakeRevision?, in cache: inout [String: ProductDefinition?], using store: any JournalStore
    ) -> ProductDefinition? {
        guard let id = revision?.productSnapshotID else { return nil }
        if let cached = cache[id] { return cached }
        let found = try? store.product(snapshotID: id)
        cache[id] = found
        return found
    }

    /// The day's entries grouped by meal. A meal that is not one of the four named ones, or none at
    /// all, is "Other"; water with no meal lands there too. Rows keep the order they are given.
    static func mealGroups(for rows: [JournalRow]) -> [JournalMealGroup] {
        let named = MealLabel.allCases.map(\.displayName)
        var buckets: [String: [JournalRow]] = [:]
        for row in rows {
            let title = row.meal.flatMap { named.contains($0) ? $0 : nil } ?? "Other"
            buckets[title, default: []].append(row)
        }
        return (named + ["Other"]).compactMap { title in
            buckets[title].map { JournalMealGroup(id: title, title: title, rows: $0) }
        }
    }

    /// A day counts as logged when it holds a food or drink entry. Water and supplements do not count.
    /// The day header and the week summary both use this rule.
    static func hasFoodEntries(_ rows: [JournalRow]) -> Bool {
        rows.contains { !$0.isWater && $0.kind != .supplement }
    }

    /// The week summary for the loaded sections, or nil when the journal has no day at all. The window is
    /// the seven days ending today in the journal's zone, today included; a later day is outside it.
    static func makeWeekSummary(
        sections: [JournalDaySection], now: Date, zone: TimeZone, goals: [NutrientGoal],
        hidden: Set<String>, unitSystem: UnitSystem
    ) -> JournalWeekSummary? {
        guard !sections.isEmpty else { return nil }
        let today = dayKey(now, zone: zone)
        let week = sections.filter { section in
            guard let back = daysBefore(section.id, today: today) else { return false }
            return (0..<weekLength).contains(back)
        }
        let logged = week.filter { hasFoodEntries($0.rows) }
        guard !logged.isEmpty else {
            return JournalWeekSummary(headline: "Nothing logged this week.", goalLines: [])
        }
        let lines = goals
            .filter { $0.nutrient != DailyTotalsBuilder.waterKey && !hidden.contains($0.nutrient) }
            .prefix(3)
            .map { weekGoalLine(goal: $0, days: logged, unitSystem: unitSystem) }
        return JournalWeekSummary(headline: "Logged \(logged.count) of 7 days", goalLines: Array(lines))
    }

    /// How many local days the week summary covers, today included.
    private static let weekLength = 7

    /// Whole days from a yyyy-MM-dd key back to `today`: 0 for today, 6 for six days earlier and a negative
    /// number for a later day. Nil when a key cannot be read.
    private static func daysBefore(_ key: String, today: String) -> Int? {
        guard let day = utcDate(fromDayKey: key), let end = utcDate(fromDayKey: today) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.dateComponents([.day], from: day, to: end).day
    }

    /// One goal's line for the logged days. The average is over the days whose total is known, converted
    /// to the goal's unit, and each day that cannot be totalled is counted in the parenthetical.
    static func weekGoalLine(goal: NutrientGoal, days: [JournalDaySection], unitSystem: UnitSystem) -> String {
        let name = NutrientNames.displayName(for: goal.nutrient)
        var known: [Decimal] = []
        var unknownDays = 0
        for day in days {
            guard let total = day.totals.total(for: goal.nutrient), case .known(let amount, let unit) = total.value,
                  let converted = try? Quantity(value: amount, unit: unit).converted(to: goal.unit).value
            else {
                unknownDays += 1
                continue
            }
            known.append(converted)
        }
        guard !known.isEmpty else { return "\(name): can't total yet" }
        let average = known.reduce(Decimal(0), +) / Decimal(known.count)
        let shown = AmountDisplay.display(average, unit: goal.unit, system: unitSystem)
        let figure = DisplayAmount(
            amount: DisplayRounding.rounded(shown.amount, fractionDigits: AmountDisplay.fractionDigits(for: shown.amount)),
            unit: shown.unit, isBelowSmallest: shown.isBelowSmallest)
        let target = AmountDisplay.display(goal.target, unit: goal.unit, system: unitSystem)
        var line = "\(name): average \(figure.text) a day against \(target.text)"
        if unknownDays > 0 {
            line += " (\(unknownDays) \(unknownDays == 1 ? "day" : "days") could not be totalled)"
        }
        return line
    }

    /// One bar per stored goal that is not water and is shown on Today, in the stored order, at most
    /// three. A nutrient with a goal but no value in the day still gets a bar, which says it cannot be
    /// totalled or is unlogged.
    static func headerBars(
        totals: DailyTotals, goals: [NutrientGoal], hasFoodEntries: Bool, unitSystem: UnitSystem,
        hidden: Set<String> = []
    ) -> [GoalBarModel] {
        goals.filter { $0.nutrient != DailyTotalsBuilder.waterKey && !hidden.contains($0.nutrient) }
            .prefix(3).map { goal -> GoalBarModel in
            let line = NutrientProgressLine.make(
                nutrient: goal.nutrient, total: totals.total(for: goal.nutrient), goal: goal)
            return GoalBarModel.make(
                line: line, hasEntries: line.hasKnownAmount || hasFoodEntries, missingCount: 0,
                unitSystem: unitSystem)
        }
    }

    /// The day's energy as "1240 kcal", or nil when the day cannot total it. Never a zero for unknown.
    static func energyText(totals: DailyTotals) -> String? {
        let line = NutrientProgressLine.make(nutrient: energyKey, total: totals.total(for: energyKey), goal: nil)
        guard case .known(let value, let unit) = line.amount else { return nil }
        return "\(DecimalFormatting.text(value)) \(unit.symbol)"
    }

    /// "1 entry" or "9 entries".
    static func entryCountText(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    /// True when the day `key` is more than seven days before the day of `now`, both read in `zone`.
    static func isMoreThanAWeekBefore(_ key: String, now: Date, zone: TimeZone) -> Bool {
        guard let day = utcDate(fromDayKey: key), let today = utcDate(fromDayKey: dayKey(now, zone: zone)) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        return days > 7
    }

    /// A yyyy-MM-dd key as midnight UTC, so two keys can be compared by whole days.
    private static func utcDate(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: components)
    }

    static func dayTitle(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
