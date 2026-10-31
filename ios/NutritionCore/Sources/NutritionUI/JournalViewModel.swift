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
    /// The kind totals and the logged-day count use for this entry (ProductKindResolution.totalsKind).
    public let countsAs: ProductKind
    public let isWater: Bool

    public var iconName: String { EntryRow.symbol(for: self.kind, isWater: self.isWater) }

    public init(
        id: String, title: String, detail: String, occurredAt: Date, timeZoneIdentifier: String,
        meal: String?, kind: ProductKind = .food, countsAs: ProductKind, isWater: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.meal = meal
        self.kind = kind
        self.countsAs = countsAs
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
    @Published public private(set) var sections: [JournalDaySection] = [] {
        didSet { arrowSectionIDs = diarySections.map(\.id) }
    }
    /// Today's section when it has no entries of its own; nil otherwise. The Diary lists it above `sections`.
    @Published public private(set) var todaySection: JournalDaySection? {
        didSet { arrowSectionIDs = diarySections.map(\.id) }
    }

    /// Every section the Diary lists, today first when it is empty.
    public var diarySections: [JournalDaySection] { (todaySection.map { [$0] } ?? []) + sections }
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
    /// Copies a past day, or one meal of it, into the present.
    private let copier: IntakeCopier
    /// The zone a picked day is read in, and the zone "today" is read in for a future date. The same
    /// resolved zone the repeater uses, so the device zone in production and "UTC" in tests.
    private let journalZoneID: () -> String
    /// The zone the Diary groups its days in. The arrows and the jump both use it, so they agree with the sections.
    public var dayZone: TimeZone { TimeZone(identifier: journalZoneID()) ?? TimeZone.current }
    /// The day keys the Diary arrows step through, in list order: today's empty day too, which the
    /// sections leave out (#539). Refreshed by every change to the sections, so no writer can leave them stale (#611).
    @Published public private(set) var arrowSectionIDs: [String] = []
    private let locale: Locale
    private let preferences: DisplayPreferences

    public init(
        store: JournalStore,
        goals: GoalStore? = nil,
        lookup: NutrientFactsLookup = UnknownNutrientFacts(),
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { DiaryZone.identifier() },
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
        self.copier = IntakeCopier(store: store, timeZoneProvider: zoneID, makeID: makeID)
    }

    /// Reloads the Diary on each time-zone change, so its days follow the device zone without a relaunch (#648).
    /// The changes are injected so a test can send one without a system notification.
    /// A subscription reloads once when it starts, so a zone change that landed before it was made is applied (#655).
    /// A stream that throws is started again after a pause, so later zone changes still reload (#654). The pause
    /// doubles on each failure in a row, from one second up to a minute, so a stream that always throws does not
    /// reload the Diary every second; a change delivered resets it.
    public func runZoneChangeReloads<Changes: AsyncSequence>(
        _ makeChanges: @escaping () -> Changes, now: @escaping () -> Date,
        pause: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async where Changes.Element == Void {
        let firstPause: UInt64 = 1_000_000_000
        let longestPause: UInt64 = 60_000_000_000
        var nextPause = firstPause
        while !Task.isCancelled {
            var changes = makeChanges().makeAsyncIterator()
            load(now: now())
            do {
                while try await changes.next() != nil {
                    nextPause = firstPause
                    load(now: now())
                }
                return
            } catch {
                await pause(nextPause)
                nextPause = min(nextPause * 2, longestPause)
            }
        }
    }

    /// Groups active intakes by the local day of each intake's own time zone, newest first.
    public func load(now: Date) {
        defer { loadCount += 1 }
        copyNotice = nil
        copyFailed = false
        do {
            var skipped = 0
            var groups: [String: [JournalRow]] = [:]
            var titles: [String: String] = [:]
            // The intakes of each day, kept beside the rows so the day's totals are summed from
            // exactly the entries the rows below were built from. Nothing here ever sees two days.
            var intakesByDay: [String: [Intake]] = [:]
            // One snapshot is read once per load, however many entries name it.
            var snapshots: [String: ProductDefinition?] = [:]
            let loggedUnits = try LoggedUnitIndex.loadOrThrow(from: store)
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
                let snapshot = Self.snapshot(of: current, in: &snapshots, using: store)
                let rowKind = ProductKindResolution.kind(
                    snapshotID: current.productSnapshotID, snapshotKind: { _ in snapshot?.kind }, category: intake.category)
                let row = JournalRow(
                    id: intake.id, title: QuickAddViewModel.rowTitle(components: current.components, product: snapshot),
                    detail: current.components.isEmpty ? "unknown" : current.components.map { component in
                        guard intake.category == "water", !component.amount.isNaN else {
                            return AmountText.describe(
                                component, unitSystem: self.preferences.unitSystem,
                                loggedUnit: rowKind == .supplement
                                    ? loggedUnits[intake.id]?[component.componentID] : nil,
                                isSupplement: rowKind == .supplement)
                        }
                        return AmountDisplay.water(
                            component.amount, unit: component.unit, system: self.preferences.unitSystem).text
                    }.joined(separator: ", "),
                    occurredAt: intake.occurredAt,
                    timeZoneIdentifier: intake.timeZoneIdentifier,
                    meal: MealLabel.displayName(for: intake.meal),
                    kind: rowKind,
                    countsAs: ProductKindResolution.totalsKind(snapshotKind: snapshot?.kind),
                    isWater: intake.category == "water")
                let key = Self.dayKey(intake.occurredAt, zone: zone)
                if titles[key] == nil {
                    titles[key] = Self.dayTitle(intake.occurredAt, zone: zone, locale: locale, now: now)
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
            // Once the journal has a readable entry, today is built even with none of its own, so the Diary can show its
            // meal cards and add rows. It is kept apart from `sections`, which keeps its entry-day contract.
            let todayKey = Self.dayKey(now, zone: dayZone)
            var sectionKeys = Set(groups.keys)
            if !groups.isEmpty {
                if titles[todayKey] == nil { titles[todayKey] = Self.dayTitle(now, zone: dayZone, locale: locale, now: now) }
                sectionKeys.insert(todayKey)
            }
            let built = try sectionKeys.sorted(by: >).map { key in
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
                    isCollapsedByDefault: !rows.isEmpty && rows.allSatisfy { row in
                        let zone = TimeZone(identifier: row.timeZoneIdentifier) ?? TimeZone.current
                        return Self.isMoreThanAWeekBefore(Self.dayKey(row.occurredAt, zone: zone), now: now, zone: zone)
                    },
                    entryCountText: Self.entryCountText(rows.count))
            }
            todaySection = built.first { $0.id == todayKey && $0.rows.isEmpty }
            sections = built.filter { !($0.id == todayKey && $0.rows.isEmpty) }
            weekSummary = Self.makeWeekSummary(
                sections: sections, now: now,
                zone: TimeZone(identifier: journalZoneID()) ?? TimeZone.current,
                goals: storedGoals, hidden: hiddenGoals, unitSystem: self.preferences.unitSystem,
                displayNames: printedNames(in: intakesByDay.values.flatMap { $0 }.filter { $0.occurredAt >= weekWindowStart(now: now) && $0.occurredAt <= now }, goals: storedGoals))
            skippedCount = skipped
            errorMessage = nil
            goalsErrorMessage = goalsReadFailed ? GoalsViewModel.readFailedMessage : nil
            hasLoaded = true
        } catch {
            // Clear everything the last successful load built: a failed read must not leave its totals on screen.
            todaySection = nil
            sections = []
            skippedCount = 0
            weekSummary = nil
            goalsErrorMessage = nil
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

    /// The day the Diary arrows step from: the earliest visible day in list order, clamped to today, or `now`
    /// when none is visible. A section with an entry dated in the future is clamped, so the arrows never start there.
    public static func arrowBaseDay(sectionIDs: [String], visible: Set<String>, zone: TimeZone, now: Date) -> Date {
        guard let top = sectionIDs.first(where: { visible.contains($0) }), let day = dayDate(top, zone: zone) else { return now }
        return min(day, now)
    }

    /// The local midnight of a day key such as "2026-10-14", read in the given zone.
    static func dayDate(_ key: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
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
        // The picked day is a day key in the journal's zone, so "yesterday" is judged in that same zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let isYesterday = Self.dayKey(yesterday, zone: zone) == key
        // distantPast turns off dayTitle's own "Yesterday" check, which is UTC here and so wrong.
        let dayPhrase = isYesterday
            ? "yesterday"
            : "on " + Self.dayTitle(
                pickedDay, zone: TimeZone(secondsFromGMT: 0) ?? .current, locale: locale, now: .distantPast)
        return JournalJumpTarget(
            sectionID: closest.id,
            message: "Nothing logged \(dayPhrase). Showing the closest day with entries.")
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

    /// The sentence for the last copy or Save as meal, such as "Copied 3 entries to today."; nil until one runs.
    @Published public private(set) var copyNotice: String?
    /// True when `copyNotice` reports a copy that failed or stopped partway.
    @Published public private(set) var copyFailed = false

    /// True for a day the person can copy into today: any loaded day before today in the journal's zone.
    public func canCopyToToday(_ section: JournalDaySection, now: Date) -> Bool {
        let zone = TimeZone(identifier: journalZoneID()) ?? .current
        return section.id < Self.dayKey(now, zone: zone)
    }

    /// Copies every entry of a past day to now, as new entries. The day's own entries are untouched.
    @discardableResult
    public func copyDayToToday(_ sectionID: String, now: Date) -> IntakeCopyResult? {
        let result = runCopy(now: now) { try copier.copyDay(dayKey: sectionID, now: now) }
        setCopyUndo(result, now: now)
        return result
    }

    /// The entries the latest copy created, held so Undo can remove exactly them. A new copy replaces them.
    @Published private(set) var copiedIDs: [String] = []

    /// The moment the latest copy's Undo window closes: ten seconds after the copy. Held in the model, so the window
    /// holds whether or not the toast is on screen.
    private var copyUndoDeadline: Date?
    private static let copyUndoWindow: TimeInterval = 10

    /// Records the latest copy as the one Undo can take back, until its deadline.
    private func setCopyUndo(_ result: IntakeCopyResult?, now: Date) {
        copiedIDs = result?.createdIDs ?? []
        copyUndoDeadline = result == nil ? nil : now.addingTimeInterval(Self.copyUndoWindow)
        copyCount += 1
    }

    /// Whether the latest copy can still be undone at `now`: it has ids left and its window is open.
    public func canUndoCopy(now: Date) -> Bool {
        guard !copiedIDs.isEmpty, let deadline = copyUndoDeadline else { return false }
        return now < deadline
    }

    /// Counts each copy, so the Undo control restarts its window when a new copy lands.
    @Published public private(set) var copyCount = 0

    /// Ends the Undo window for the latest copy without undoing it.
    public func expireCopyUndo() {
        copiedIDs = []
        copyUndoDeadline = nil
    }

    /// Removes exactly the entries the latest copy created, and nothing else. Taken once: a second call finds
    /// nothing to undo.
    @discardableResult
    public func undoCopy(now: Date) -> Bool {
        guard canUndoCopy(now: now) else { return false }
        // A copy the person already deleted by hand is not active any more: it is skipped, not counted as a failure.
        guard let active = try? Set(store.activeIntakes().map(\.id)) else {
            load(now: now)
            // A failed read cannot tell which copies are still here, so the notice names no count (#535).
            copyNotice = "Couldn't remove the copied entries. Tap Undo to try again."
            return false
        }
        var succeeded = true
        // An id leaves copiedIDs only once it is gone, so a failed delete keeps the rest for a retry.
        while let id = copiedIDs.first {
            if active.contains(id) {
                do { try store.delete(intakeID: id, now: now) } catch {
                    succeeded = false
                    break
                }
            }
            copiedIDs.removeFirst()
        }
        load(now: now)
        // A failed undo leaves the copies still here, and the Undo control stays so tapping it tries again.
        // A copy after a failed delete may have been deleted by hand, so count only the ids still active (#535).
        copyNotice = succeeded ? nil : Self.undoFailureText(copiedIDs.filter { active.contains($0) }.count)
        return succeeded
    }

    /// The notice after an undo could not remove every copy: `remaining` copies are still here (#535).
    static func undoFailureText(_ remaining: Int) -> String {
        remaining == 1
            ? "Couldn't remove 1 copied entry. Tap Undo to try again."
            : "Couldn't remove \(remaining) copied entries. Tap Undo to try again."
    }

    /// Copies one meal group of a past day to now. "Other" copies the entries with no named meal.
    @discardableResult
    public func copyMealToToday(_ sectionID: String, groupID: String, now: Date) -> IntakeCopyResult? {
        let selector = MealLabel.allCases.first { $0.displayName == groupID }.map(MealSelector.named) ?? .other
        let result = runCopy(now: now) { try copier.copyMeal(selector, dayKey: sectionID, now: now) }
        setCopyUndo(result, now: now)
        return result
    }

    /// The saved meals "Save as meal" writes to. Set once by the app; nil leaves the action out.
    public var savedMeals: SavedMealsModel?

    /// Saves one meal group of a day as a saved meal named `name`, its entries in the order they were eaten.
    /// The group's meal is the meal it is logged under by default; "Other" saves one with no meal. The
    /// outcome, a refusal included, is shown as the copy notice.
    @discardableResult
    public func saveMeal(_ sectionID: String, groupID: String, name: String) -> Bool {
        guard let savedMeals else { return false }
        let label = MealLabel.allCases.first { $0.displayName == groupID }
        let selector = label.map(MealSelector.named) ?? .other
        let intakes: [Intake]
        do {
            intakes = try copier.sources(dayKey: sectionID, meal: selector)
        } catch {
            copyNotice = "Could not read this meal's entries, so it was not saved."
            copyFailed = true
            return false
        }
        let saved = savedMeals.save(name: name, meal: label, intakes: intakes)
        // Saving a meal is a newer action than the copy, so the copy's Undo is no longer offered once it has saved.
        if saved { expireCopyUndo() }
        copyNotice = savedMeals.notice
        copyFailed = savedMeals.noticeIsFailure
        return saved
    }

    private func runCopy(now: Date, _ body: () throws -> IntakeCopyResult) -> IntakeCopyResult? {
        do {
            let result = try body()
            load(now: now)
            copyNotice = Self.copyNoticeText(result)
            return result
        } catch IntakeCopyError.stoppedEarly(let partial, _) {
            load(now: now)
            copyNotice = partial.copiedCount == 0
                ? "Could not copy the entries."
                : "Copied \(Self.entriesText(partial.copiedCount)), then the copy stopped. The rest were not copied."
            copyFailed = true
            return partial
        } catch {
            copyNotice = "Could not copy the entries."
            copyFailed = true
            return nil
        }
    }

    static func copyNoticeText(_ result: IntakeCopyResult) -> String {
        if result.copiedCount == 0 {
            return result.skippedCount == 0
                ? "Nothing to copy."
                : "Nothing copied: \(Self.entriesText(result.skippedCount)) could not be copied."
        }
        let copied = "Copied \(Self.entriesText(result.copiedCount)) to today."
        guard result.skippedCount > 0 else { return copied }
        return copied + " \(Self.entriesText(result.skippedCount)) could not be copied."
    }

    private static func entriesText(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
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
            // A partial day is left off here too: this summary reads the whole-day amount, not the known part.
            guard case .known = line.amount else { return nil }
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

    /// The day's entries grouped by meal, as the Journal's section list has always carried them: only the meals
    /// with entries, then "Other". The Diary adds the empty named meals itself through `diaryMealGroups`.
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

    /// The meals a Diary day lists: the four named meals in their fixed order, empty ones included, then "Other"
    /// only when an entry has no named meal. Which of them a day shows is decided by `visibleMealGroups`.
    static func diaryMealGroups(for rows: [JournalRow]) -> [JournalMealGroup] {
        let named = MealLabel.allCases.map(\.displayName)
        var buckets: [String: [JournalRow]] = [:]
        for row in rows {
            let title = row.meal.flatMap { named.contains($0) ? $0 : nil } ?? "Other"
            buckets[title, default: []].append(row)
        }
        let namedGroups = named.map { JournalMealGroup(id: $0, title: $0, rows: buckets[$0] ?? []) }
        guard let other = buckets["Other"] else { return namedGroups }
        return namedGroups + [JournalMealGroup(id: "Other", title: "Other", rows: other)]
    }

    /// Whether a section is the day an add flow logs to: today in the device's own zone, which is the zone a new
    /// entry is stamped with. Section ids are each intake's own local day, so the comparison uses the same zone.
    static func isAddDay(_ sectionID: String, now: Date, zone: TimeZone = .current) -> Bool {
        sectionID == addDayID(now: now, zone: zone)
    }

    /// The section id an entry added now would get: the same day key every section uses, read in the zone the add
    /// flow stamps new entries with. Section ids come from each intake's own zone, so for a new entry this is the device zone.
    static func addDayID(now: Date, zone: TimeZone = .current) -> String {
        dayKey(now, zone: zone)
    }

    /// The meal groups a Diary day shows. Today's day shows every named meal, so each can take an add. A past day
    /// shows only the meals that have entries, because an add there would log to now, not to that day.
    static func visibleMealGroups(
        _ groups: [JournalMealGroup], sectionID: String, now: Date, zone: TimeZone = .current
    ) -> [JournalMealGroup] {
        guard !isAddDay(sectionID, now: now, zone: zone) else { return groups }
        return groups.filter { !$0.rows.isEmpty }
    }

    /// Whether a day's section offers the add row: the day an add made now lands in, judged in this journal's zone,
    /// the same zone the arrows and Copy to today use. The view asks this rather than comparing zones itself.
    public func showsAddRow(sectionID: String, now: Date) -> Bool {
        Self.isAddDay(sectionID, now: now, zone: dayZone)
    }

    /// The meal an add opens with for a group: the named meal, or nil for "Other", which has no add of its own.
    static func addMeal(forGroupTitle title: String) -> MealLabel? {
        MealLabel.allCases.first { $0.displayName == title }
    }

    /// A day counts as logged when it holds a food or drink entry. Water and supplements do not count.
    /// The day header and the week summary both use this rule.
    static func hasFoodEntries(_ rows: [JournalRow]) -> Bool {
        rows.contains { !$0.isWater && $0.countsAs != .supplement }
    }

    /// The week summary for the loaded sections, or nil when the journal has no day at all. The window is
    /// the seven days ending today in the journal's zone, today included; a later day is outside it.
    static func makeWeekSummary(
        sections: [JournalDaySection], now: Date, zone: TimeZone, goals: [NutrientGoal],
        hidden: Set<String>, unitSystem: UnitSystem, displayNames: [String: String] = [:]
    ) -> JournalWeekSummary? {
        guard !sections.isEmpty else { return nil }
        // The window is read by instant in the journal's zone: from the start of the day six days back to now.
        // An entry's own zone only decides which day section it sits in, so a trip across zones cannot move an
        // entry in or out of the week or make a section count twice.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let startOfToday = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(weekLength - 1), to: startOfToday) else { return nil }
        // An entry dated later than now has not happened yet, so it is not part of the week.
        let windowEnd = now
        let week = sections.filter { section in
            section.rows.contains { $0.occurredAt >= windowStart && $0.occurredAt <= windowEnd }
        }
        let logged = week.filter { hasFoodEntries($0.rows) }
        guard !logged.isEmpty else {
            return JournalWeekSummary(headline: "Nothing logged this week.", goalLines: [])
        }
        let lines = goals
            .filter { $0.nutrient != DailyTotalsBuilder.waterKey && !hidden.contains($0.nutrient) }
            .prefix(3)
            .map { weekGoalLine(goal: $0, days: logged, unitSystem: unitSystem, displayNames: displayNames) }
        return JournalWeekSummary(headline: "Logged \(min(logged.count, weekLength)) of 7 days", goalLines: Array(lines))
    }

    /// The words the labels printed for the goal nutrients (`DHA`, never `Dha`), read from the snapshots the
    /// loaded entries were logged with, so the week card names a compound as Today does.
    private func printedNames(in intakes: [Intake], goals: [NutrientGoal]) -> [String: String] {
        let wanted = Set(goals.map(\.nutrient))
        var names: [String: String] = [:]
        var seen = Set<String>()
        for intake in intakes {
            guard let revisions = try? store.revisions(of: intake.id),
                  let current = revisions.first(where: { $0.number == intake.currentRevision }),
                  let snapshotID = current.productSnapshotID, seen.insert(snapshotID).inserted,
                  let product = try? store.product(snapshotID: snapshotID)
            else { continue }
            for (key, name) in product.nutrientDisplayNames where wanted.contains(key) { names[key] = name }
        }
        return names
    }

    /// The start of the first day of the week window, in the journal's zone.
    private func weekWindowStart(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: journalZoneID()) ?? TimeZone.current
        return calendar.date(byAdding: .day, value: -(Self.weekLength - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
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
    /// to the goal's unit, and each day that cannot be totaled is counted in the parenthetical.
    static func weekGoalLine(
        goal: NutrientGoal, days: [JournalDaySection], unitSystem: UnitSystem, displayNames: [String: String] = [:]
    ) -> String {
        let name = NutrientNames.displayName(for: goal.nutrient, displayNames: displayNames)
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
        // Nutrient goals read in their own metric unit, as the goal bars on this screen do.
        let shown = AmountDisplay.display(average, unit: goal.unit, system: .metric)
        let rounded = DisplayRounding.rounded(shown.amount, fractionDigits: AmountDisplay.fractionDigits(for: shown.amount))
        // A real average that rounds to none of it reads as "less than" the smallest figure, never as zero.
        let figure = DisplayAmount(
            amount: rounded, unit: shown.unit,
            isBelowSmallest: shown.isBelowSmallest || (rounded == 0 && average > 0))
        let target = AmountDisplay.display(goal.target, unit: goal.unit, system: .metric)
        var line = "\(name): average \(figure.text) a day against \(target.text)"
        if unknownDays > 0 {
            line += " (\(unknownDays) \(unknownDays == 1 ? "day" : "days") could not be totaled)"
        }
        return line
    }

    /// One bar per stored goal that is not water and is shown on Today, in the stored order, at most
    /// three. A nutrient with a goal but no value in the day still gets a bar, which says it cannot be
    /// totaled or is unlogged.
    static func headerBars(
        totals: DailyTotals, goals: [NutrientGoal], hasFoodEntries: Bool, unitSystem: UnitSystem,
        hidden: Set<String> = []
    ) -> [GoalBarModel] {
        goals.filter { $0.nutrient != DailyTotalsBuilder.waterKey && !hidden.contains($0.nutrient) }
            .prefix(3).map { goal -> GoalBarModel in
            let line = NutrientProgressLine.make(
                nutrient: goal.nutrient, total: totals.total(for: goal.nutrient), goal: goal,
                knownSum: totals.knownSum(for: goal.nutrient), missingCount: totals.missingCount(for: goal.nutrient))
            return GoalBarModel.make(
                line: line, hasEntries: line.hasKnownAmount || hasFoodEntries, missingCount: line.missingCount,
                unitSystem: unitSystem)
        }
    }

    /// The day's energy as "1240 kcal", or nil when the day cannot total it. Never a zero for unknown.
    static func energyText(totals: DailyTotals) -> String? {
        let line = NutrientProgressLine.make(nutrient: energyKey, total: totals.total(for: energyKey), goal: nil)
        guard case .known(let value, _) = line.amount else { return nil }
        // Energy reads as "400 Calories": the Diary never shows the kcal symbol on a screen. A small positive
        // amount reads "under 1", never "0", the same as Today's ring.
        if value > 0 && value < 1 { return "under 1 Calories" }
        return "\(BodyActivityViewModel.whole(value)) Calories"
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

    static func dayTitle(_ date: Date, zone: TimeZone, locale: Locale, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let isYesterday = calendar.date(byAdding: .day, value: -1, to: now)
            .map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // The system words the previous day in the person's language ("Yesterday" in English).
        formatter.doesRelativeDateFormatting = isYesterday
        return formatter.string(from: date)
    }

    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The zone a new entry is stamped with and the Diary groups its days in, when no override is given (#539).
/// The add flow and the Diary both default to this one function, so the two cannot drift apart.
public enum DiaryZone {
    public static func identifier() -> String { TimeZone.current.identifier }
}
