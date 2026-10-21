import Foundation
import NutritionDomain
import NutritionJournal

/// One item on the supplement list, as the screen shows it today.
public struct SupplementStackRow: Identifiable, Equatable {
    /// The favorite's id.
    public let id: String
    public let title: String
    /// The amounts one "Taken" logs, from the favorite.
    public let detail: String
    public let kind: ProductKind
    public let schedule: SupplementSchedule
    /// Whether today is one of the schedule's days.
    public let isDueToday: Bool
    /// Today's times and where each stands. Empty on a day the schedule leaves out.
    public let slots: [SupplementSlot]
    /// Entries of this item logged today, whether from this list or from anywhere else in the app.
    public let loggedToday: Int
    /// False when the favorite's amounts cannot be read back, so there is nothing to log.
    public let canLog: Bool
    /// The names of the nutrients this item's label states that are above an upper limit today, where the
    /// limit counts what this item is (any product for an all-sources limit, a supplement for the
    /// supplement-only ones). Empty without a reference group.
    public let aboveUpperLimit: [String]

    /// "1 of 2 taken today", "Not on today's schedule", or the count when more was logged than planned.
    public var statusText: String {
        guard isDueToday else {
            return loggedToday > 0 ? "Not on today's schedule · logged \(loggedToday) today" : "Not on today's schedule"
        }
        if loggedToday > slots.count { return "All taken today · logged \(loggedToday) times" }
        return "\(loggedToday) of \(slots.count) taken today"
    }
}

/// Something that can be added to the list: a favorite not on it yet, or a supplement logged recently
/// that is not a favorite.
public struct SupplementStackCandidate: Identifiable, Equatable {
    enum Source: Equatable {
        case favorite(String)
        case recent(RepeatTemplate)
    }

    public let id: String
    public let title: String
    public let detail: String
    public let kind: ProductKind
    let source: Source
}

/// The supplement list: favorites with the times of day they are taken, a one-tap "Taken" that logs an
/// entry, and where each of today's times stands.
///
/// Each load counts today's entries of each item in the journal, so an entry logged from the Library
/// counts, and deleting or undoing an entry un-marks its time. All that is stored about a Taken is which
/// time it was for, per entry. The schedules and those marks live in `SupplementStackStoring`; the amounts
/// and the product snapshot live in the favorite, so a "Taken" logs exactly what the favorite copied,
/// label snapshot included.
@MainActor
public final class SupplementStackViewModel: ObservableObject {
    @Published public private(set) var rows: [SupplementStackRow] = []
    @Published public private(set) var candidates: [SupplementStackCandidate] = []
    @Published public private(set) var errorMessage: String?
    /// True when the last read failed, so the screen shows the error and not an empty list. Separate from
    /// `errorMessage`, which also says why an add or a Taken was refused while the list itself is fine.
    @Published public private(set) var readFailed = false
    @Published public private(set) var undoToken: LibraryUndoToken?
    /// Today's entries whose current revision could not be read. Each may be an item on the list, so the
    /// screen says a time may read "Not logged" when it was taken rather than showing a count it cannot back.
    @Published public private(set) var unreadableEntriesToday = 0
    /// Today's vitamins and minerals that are above an upper limit, as rows of the vitamins and minerals
    /// screen. They are built the way that screen builds them (`NutrientGapsViewModel.tallies` and
    /// `NutrientGapRow`), so the two screens never disagree. Empty without a reference group.
    @Published public private(set) var limitRows: [NutrientGapRow] = []
    /// Whether a reference group is chosen, without which there is no limit to compare with.
    @Published public private(set) var hasReferenceGroup = false
    /// True when today's amounts could not be read for the limit check.
    @Published public private(set) var limitCheckFailed = false
    /// Advances each time an erase or a restore replaced the stores, so a screen can close a picker or an
    /// editor that still shows what was there before.
    @Published public private(set) var replacements = 0

    private let store: JournalStore
    private let favorites: FavoritesStore
    private let schedules: SupplementStackStoring
    private let preferences: DisplayPreferences
    private let zoneID: () -> String
    private let makeID: () -> String
    private let lookup: NutrientFactsLookup
    private let referencePreferences: ReferenceGroupPreferences?

    public init(
        store: JournalStore,
        favorites: FavoritesStore,
        schedules: SupplementStackStoring,
        lookup: NutrientFactsLookup = UnknownNutrientFacts(),
        referencePreferences: ReferenceGroupPreferences? = nil,
        preferences: DisplayPreferences = InMemoryDisplayPreferences(),
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.favorites = favorites
        self.schedules = schedules
        self.lookup = lookup
        self.referencePreferences = referencePreferences
        self.preferences = preferences
        self.zoneID = IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider)
        self.makeID = makeID
    }

    /// What a row needs that changes only when the journal, the favorites or the list change. Kept between
    /// reads, so the once-a-minute refresh moves the times on without reading the journal again.
    private struct RowBasis {
        let favoriteID: String
        let title: String
        let detail: String
        let kind: ProductKind
        let schedule: SupplementSchedule
        let matchKey: String
        let canLog: Bool
        let aboveUpperLimit: [String]
    }

    private var bases: [RowBasis] = []
    /// Today's entries per item (their journal ids), as of the last full read, and the day they were
    /// counted for.
    private var counts: [String: [String]] = [:]
    private var countedDay: String?
    /// The reference group the last full read compared with.
    private var loadedGroup: ReferenceGroup?
    /// The time each Taken tap was for, by entry id, as of the last full read. Only today's marks for
    /// entries still in the journal are kept.
    private var marks: [String: SupplementTakenMark] = [:]
    /// The screens showing the list, one id each, in case more than one window shows it. A set rather than
    /// a count, so an appearance reported twice without a disappearance in between is still one screen.
    /// The app's reloads only reread the journal while one is shown: a list nobody is looking at is read
    /// again when it next appears.
    private var shownBy: Set<UUID> = []
    private var isShown: Bool { !shownBy.isEmpty }

    // MARK: Reading

    /// Reads the favorites, the list and today's entries, and builds every row and the picker.
    public func load(now: Date) {
        do {
            let stored = try favorites.list()
            let loggedUnitIndex = try LoggedUnitIndex.loadOrThrow(from: store)
            let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let planned = try pruned(schedules.schedules(), keeping: Set(byID.keys))
            guard let clock = SupplementStackClock(now: now, zoneIdentifier: zoneID()) else {
                forget()
                rows = []
                candidates = []
                errorMessage = "Your time zone could not be read, so today's list cannot be shown."
                readFailed = true
                return
            }
            let (counted, unreadable, todayTimes, active) = try loggedCounts(on: clock.dayKey)
            let keptMarks = try prunedMarks(keeping: todayTimes, on: clock.dayKey)
            var products: [String: ProductDefinition?] = [:]
            func product(_ snapshotID: String?) -> ProductDefinition? {
                guard let snapshotID else { return nil }
                if let known = products[snapshotID] { return known }
                let found = try? store.product(snapshotID: snapshotID)
                products[snapshotID] = found
                return found
            }
            func kind(_ snapshotID: String?, category: String) -> ProductKind {
                guard snapshotID != nil else { return category == Self.supplementCategory ? .supplement : .food }
                return product(snapshotID)?.kind ?? .food
            }
            let limits = upperLimitRows(now: now, intakes: active)
            bases = planned.compactMap { entry -> RowBasis? in
                guard let favorite = byID[entry.key] else { return nil }
                let template = RepeatTemplate(favorite: favorite, loggedUnitIndex: loggedUnitIndex)
                return RowBasis(
                    favoriteID: favorite.id, title: favorite.displayName,
                    detail: template.map {
                        AmountText.summary(
                            $0.components, unitSystem: preferences.unitSystem,
                            loggedUnits: kind(favorite.productSnapshotID, category: favorite.category) == .supplement
                                ? $0.loggedUnits : [:],
                            isSupplement: kind(favorite.productSnapshotID, category: favorite.category) == .supplement)
                    } ?? "unknown",
                    kind: kind(favorite.productSnapshotID, category: favorite.category), schedule: entry.value,
                    matchKey: Self.matchKey(favorite), canLog: template.map { !$0.components.isEmpty } ?? false,
                    aboveUpperLimit: Self.limitsCounting(product(favorite.productSnapshotID), among: limits.rows))
            }
            .sorted { left, right in
                let leftFirst = left.schedule.times.first.map(SupplementSchedule.minuteOfDay) ?? 0
                let rightFirst = right.schedule.times.first.map(SupplementSchedule.minuteOfDay) ?? 0
                if leftFirst != rightFirst { return leftFirst < rightFirst }
                let order = left.title.localizedCaseInsensitiveCompare(right.title)
                return order == .orderedSame ? left.favoriteID < right.favoriteID : order == .orderedAscending
            }
            counts = counted
            marks = keptMarks
            countedDay = clock.dayKey
            unreadableEntriesToday = unreadable
            limitRows = limits.rows
            loadedGroup = referencePreferences?.referenceGroup
            hasReferenceGroup = limits.hasGroup
            limitCheckFailed = limits.failed
            rows = makeRows(clock: clock)
            candidates = try makeCandidates(favorites: stored, planned: Set(planned.keys), kind: kind)
            errorMessage = nil
            readFailed = false
        } catch {
            // Clear everything read before rather than keep it on screen: it may be exactly what an erase
            // just removed, and a picker row left behind could still be added.
            forget()
            rows = []
            candidates = []
            errorMessage = "Could not read your supplements."
            readFailed = true
        }
    }

    /// Moves today's times on as the clock does, without reading the journal or the favorites: a time that
    /// passes turns "Not logged". On another day, or in a zone where it is another day, it reads everything
    /// again instead, because the entries counted belong to the day they were counted for.
    public func refreshClock(now: Date) {
        // A reference group changed elsewhere (Vitamins and minerals in another window) changes what the
        // limits are, so the list reads everything again rather than keep the old group's notes.
        guard let day = countedDay, let clock = SupplementStackClock(now: now, zoneIdentifier: zoneID()),
              clock.dayKey == day, referencePreferences?.referenceGroup == loadedGroup
        else {
            load(now: now)
            return
        }
        rows = makeRows(clock: clock)
    }

    private func makeRows(clock: SupplementStackClock) -> [SupplementStackRow] {
        bases.map { basis in
            let entries = counts[basis.matchKey] ?? []
            // Entries a Taken tap recorded mark their own time; the rest fill the open times.
            let recorded = entries.compactMap { id -> (minute: Int, entryID: String?)? in
                guard let mark = marks[id], mark.favoriteID == basis.favoriteID, mark.dayKey == clock.dayKey,
                      let time = mark.timeOfDay
                else { return nil }
                return (minute: SupplementSchedule.minuteOfDay(time), entryID: id as String?)
            }
            let logged = entries.count
            let isDue = basis.schedule.weekdays.contains(clock.weekday)
            return SupplementStackRow(
                id: basis.favoriteID, title: basis.title, detail: basis.detail, kind: basis.kind,
                schedule: basis.schedule, isDueToday: isDue,
                slots: isDue
                    ? SupplementStackDay.slots(
                        for: basis.schedule, recorded: recorded, unrecordedCount: logged - recorded.count,
                        minuteOfDay: clock.minuteOfDay)
                    : [],
                loggedToday: logged, canLog: basis.canLog, aboveUpperLimit: basis.aboveUpperLimit)
        }
    }

    /// Today's rows that are above an upper limit, built exactly as the vitamins and minerals screen builds
    /// its rows. A read failure is reported rather than read as "nothing above a limit".
    /// `intakes` are the active entries this read already holds, so the check does not read the journal again.
    private func upperLimitRows(now: Date, intakes: [Intake]) -> (rows: [NutrientGapRow], hasGroup: Bool, failed: Bool) {
        guard let group = referencePreferences?.referenceGroup else { return ([], false, false) }
        do {
            let day = try NutrientGapsViewModel.tallies(intakes: intakes, store: store, lookup: lookup, now: now)
            let rows = NutrientGapsViewModel.nutrients.map { nutrient in
                NutrientGapRow(
                    nutrient: nutrient, label: NutrientNames.displayName(for: nutrient),
                    unit: NutrientGapsViewModel.unit(for: nutrient), tally: day.tallies[nutrient] ?? NutrientDayTally(),
                    reference: ReferenceIntakes.intake(for: nutrient, group: group))
            }
            return (rows.filter { $0.status == .aboveUpperLimit }, true, false)
        } catch {
            return ([], true, true)
        }
    }

    /// The names of the over-limit nutrients this product's label states and the limit counts: every
    /// product for an all-sources limit, only a supplement for a limit on supplements. Nothing for an item
    /// with no product snapshot, whose label the app never saw.
    static func limitsCounting(_ product: ProductDefinition?, among rows: [NutrientGapRow]) -> [String] {
        guard let product else { return [] }
        return rows.filter { row in
            // The label may state the nutrient under an accepted alias (`vitamin-c`); the day's tally reads
            // the same keys in the same order, so an item is marked for exactly what the tally counted.
            let stated = HealthKitWritePlanner.acceptedKeys(for: row.nutrient).lazy
                .map { product.value(for: $0) }
                .first { if case .unknown = $0 { return false } else { return true } }
            guard case .known(let amount, _)? = stated, amount > 0 else { return false }
            switch row.reference?.upperLimitScope {
            case .allSources: return true
            case .supplementsAndMedicines, .supplementsAndFortifiedFoods: return product.kind == .supplement
            case .folicAcid, .preformedVitaminA, nil: return false
            }
        }.map(\.label)
    }

    /// Drops what the last read kept, so the next refresh reads everything again.
    private func forget() {
        bases = []
        counts = [:]
        marks = [:]
        countedDay = nil
        unreadableEntriesToday = 0
        limitRows = []
        limitCheckFailed = false
    }

    /// The schedules whose favorite still exists. A favorite removed in the Library takes its schedule
    /// with it, so a later favorite can never inherit times nobody set for it.
    private func pruned(_ planned: [String: SupplementSchedule], keeping ids: Set<String>) throws
        -> [String: SupplementSchedule]
    {
        let kept = planned.filter { ids.contains($0.key) }
        if kept.count != planned.count { try schedules.save(kept) }
        return kept
    }

    /// Today's entries per item (their ids), each on the local day of its own time zone, the rule the
    /// Journal groups by; how many of today's entries could not be read; and when each of today's entries
    /// happened, which says which Taken marks still stand. An unreadable entry is counted apart rather than
    /// skipped, because skipping it would read as "not taken".
    private func loggedCounts(on dayKey: String) throws
        -> (counts: [String: [String]], unreadable: Int, todayTimes: [String: Date], active: [Intake])
    {
        var counts: [String: [String]] = [:]
        var unreadable = 0
        let active = try store.activeIntakes().filter { $0.lifecycle == .active }
        let today = active.filter {
            IntakeCopier.dayKey($0.occurredAt, zoneIdentifier: $0.timeZoneIdentifier) == dayKey
        }
        for intake in today {
            guard let revisions = try? store.revisions(of: intake.id),
                  let current = revisions.first(where: { $0.number == intake.currentRevision })
            else {
                unreadable += 1
                continue
            }
            let key = SupplementStackDay.matchKey(
                category: intake.category, snapshotID: current.productSnapshotID, names: current.components.map(\.name))
            counts[key, default: []].append(intake.id)
        }
        return (
            counts, unreadable, Dictionary(today.map { ($0.id, $0.occurredAt) }, uniquingKeysWith: { first, _ in first }),
            active)
    }

    /// The stored Taken marks for today whose entry is still in today's journal at the time the tap logged
    /// it. Any other mark (its entry deleted, moved to another day, or given another time in the Journal,
    /// or the mark from another day) is dropped from the store when the list is read.
    private func prunedMarks(keeping todayTimes: [String: Date], on dayKey: String) throws
        -> [String: SupplementTakenMark]
    {
        let stored = schedules.takenMarks()
        let kept = stored.filter { entry in
            guard entry.value.dayKey == dayKey, let occurredAt = todayTimes[entry.key] else { return false }
            return entry.value.matches(occurredAt: occurredAt)
        }
        if kept.count != stored.count { try schedules.saveTakenMarks(kept) }
        return kept
    }

    /// Favorites not on the list, supplements first, then supplements logged recently that no favorite
    /// stands for yet. Nothing is offered that matches the same entries as an item already on the list.
    private func makeCandidates(
        favorites stored: [FavoriteTemplate], planned: Set<String>,
        kind: (String?, String) -> ProductKind
    ) throws -> [SupplementStackCandidate] {
        let loggedUnitIndex = try LoggedUnitIndex.loadOrThrow(from: store)
        let onList = Set(stored.filter { planned.contains($0.id) }.map { Self.matchKey($0) })
        let favoriteCandidates = stored
            .filter { !planned.contains($0.id) && !onList.contains(Self.matchKey($0)) }
            .map { favorite -> SupplementStackCandidate in
                let template = RepeatTemplate(favorite: favorite, loggedUnitIndex: loggedUnitIndex)
                return SupplementStackCandidate(
                    id: "favorite:\(favorite.id)", title: favorite.displayName,
                    detail: template.map {
                        AmountText.summary(
                            $0.components, unitSystem: preferences.unitSystem,
                            loggedUnits: kind(favorite.productSnapshotID, favorite.category) == .supplement
                                ? $0.loggedUnits : [:],
                            isSupplement: kind(favorite.productSnapshotID, favorite.category) == .supplement)
                    } ?? "unknown",
                    kind: kind(favorite.productSnapshotID, favorite.category), source: .favorite(favorite.id))
            }
        let supplementsFirst = favoriteCandidates.filter { $0.kind == .supplement }
            + favoriteCandidates.filter { $0.kind != .supplement }
        // A recent that any favorite already matches is left out, whatever its meal: that favorite is the
        // one to add, and a second favorite of it would only count the same entries twice.
        var seen = Set(stored.map { Self.matchKey($0) })
        var recentCandidates: [SupplementStackCandidate] = []
        for recent in try RecentItemsProvider(store: store).recents() {
            let template = recent.template
            guard !template.components.isEmpty,
                  kind(template.productSnapshotID, template.category) == .supplement
            else { continue }
            let key = Self.matchKey(template)
            guard seen.insert(key).inserted else { continue }
            recentCandidates.append(SupplementStackCandidate(
                id: "recent:\(recent.id)", title: template.displayName,
                detail: LibraryViewModel.detail(template, unitSystem: preferences.unitSystem, isSupplement: true), kind: .supplement, source: .recent(template)))
        }
        return supplementsFirst + recentCandidates
    }

    // MARK: Changing the list

    /// Puts the candidate on the list with this schedule. A recent supplement is saved as a favorite first,
    /// the same copy the Library's star makes. False, with a message, when nothing was added.
    @discardableResult
    public func add(_ candidate: SupplementStackCandidate, schedule: SupplementSchedule, now: Date) -> Bool {
        do {
            // Read again rather than trusting the picker, which may be older than the list: the favorite is
            // matched by what it holds now, not by what it held when the picker was built.
            let stored = try favorites.list()
            let current = schedules.schedules()
            let favoriteID: String
            let key: String
            var newFavorite: FavoriteTemplate?
            switch candidate.source {
            case .favorite(let id):
                guard let favorite = stored.first(where: { $0.id == id }) else {
                    return refuse("This favorite is no longer saved.", now: now)
                }
                favoriteID = id
                key = Self.matchKey(favorite)
            case .recent(let template):
                // The picker can be older than the journal: an erase, a restore or a delete in another
                // window may have removed the entry it showed. Only a supplement the journal still holds is
                // saved, so nothing erased comes back as a favorite.
                // The entry the picker showed must still be in the journal with the amounts it showed: an
                // edit in another window changes what a favorite would copy, and a delete leaves nothing to
                // copy. Either way nothing is saved, and the list reads the journal again.
                guard let fresh = try RecentItemsProvider(store: store).recents(limit: .max)
                    .first(where: { "recent:\($0.id)" == candidate.id }),
                    fresh.template.components == template.components
                else {
                    return refuse("Could not add it to your supplements.", now: now)
                }
                let recentKey = Self.matchKey(fresh.template)
                let sameItem = stored.filter { Self.matchKey($0) == recentKey }
                let sameAmounts = sameItem.filter { RepeatTemplate(favorite: $0)?.components == fresh.template.components }
                if sameAmounts.count != sameItem.count {
                    // Starred since the picker was built with other amounts. A second favorite of the same
                    // item would share its Library identity, and removing either star would remove both, so
                    // nothing is saved; the reloaded picker offers that favorite instead.
                    return refuse("Could not add it to your supplements.", now: now)
                } else if let starred = sameAmounts.first {
                    // Starred since the picker was built, with the same amounts: that favorite goes on the
                    // list rather than a second copy of it.
                    favoriteID = starred.id
                    key = recentKey
                } else {
                    guard let favorite = makeFavorite(from: fresh.template, title: candidate.title) else {
                        errorMessage = "This supplement has an amount that cannot be saved."
                        return false
                    }
                    newFavorite = favorite
                    favoriteID = favorite.id
                    key = Self.matchKey(favorite)
                }
            }
            guard !stored.contains(where: { current[$0.id] != nil && Self.matchKey($0) == key }) else {
                return refuse("This is already on your supplements.", now: now)
            }
            if let newFavorite { try favorites.add(newFavorite) }
            var planned = current
            planned[favoriteID] = schedule
            try schedules.save(planned)
            load(now: now)
            return true
        } catch {
            errorMessage = "Could not add it to your supplements."
            return false
        }
    }

    /// Changes the times and days of an item already on the list.
    @discardableResult
    public func setSchedule(_ schedule: SupplementSchedule, for favoriteID: String, now: Date) -> Bool {
        var planned = schedules.schedules()
        guard planned[favoriteID] != nil else {
            return refuse("This item is no longer on your supplements.", now: now)
        }
        planned[favoriteID] = schedule
        do {
            try schedules.save(planned)
            load(now: now)
            return true
        } catch {
            errorMessage = "Could not save the times."
            return false
        }
    }

    /// Takes the item off the list. The favorite and every logged entry stay.
    @discardableResult
    public func remove(favoriteID: String, now: Date) -> Bool {
        var planned = schedules.schedules()
        planned[favoriteID] = nil
        do {
            try schedules.save(planned)
            load(now: now)
            return true
        } catch {
            errorMessage = "Could not remove it from your supplements."
            return false
        }
    }

    // MARK: Logging

    /// Logs one entry of the item now, from the favorite as it is stored at this moment, and offers Undo.
    /// False, with no token, when nothing was logged.
    ///
    /// `time` is the time of day the tap was for, and that time is the one the list marks taken. Without
    /// one (a tap on a day off the schedule, or after every time is taken) the entry fills the open times
    /// like an entry logged anywhere else.
    ///
    /// The favorite is read again rather than taken from the row: a row on screen can outlive its favorite
    /// (removed in the Library, or erased from Settings), and logging from a copy would write an entry for
    /// something no longer on the list.
    @discardableResult
    public func markTaken(_ row: SupplementStackRow, at time: ReminderTime? = nil, now: Date) -> Bool {
        // An earlier Taken's Undo offer stays up unless this one writes an entry and replaces it.
        do {
            guard schedules.schedules()[row.id] != nil,
                  let favorite = try favorites.list().first(where: { $0.id == row.id })
            else {
                return refuse("This item is no longer on your supplements.", now: now)
            }
            guard let template = RepeatTemplate(
                favorite: favorite, loggedUnitIndex: try LoggedUnitIndex.loadOrThrow(from: store)),
                !template.components.isEmpty
            else {
                errorMessage = "This item has no amounts to log."
                return false
            }
            let repeater = IntakeRepeater(store: store, timeZoneProvider: zoneID, makeID: makeID)
            let id = try repeater.create(from: template, now: now)
            // A time the item's schedule no longer has (a row older than an edit of its times) is not
            // recorded: the entry fills an open time like any other.
            if let time, let clock = SupplementStackClock(now: now, zoneIdentifier: zoneID()),
               schedules.schedules()[favorite.id]?.times.contains(time) == true
            {
                // The entry is written either way. A mark that cannot be saved only means this entry
                // fills an open time the way an entry logged elsewhere does.
                var stored = schedules.takenMarks()
                stored[id] = SupplementTakenMark(
                    favoriteID: favorite.id, dayKey: clock.dayKey, time: time, loggedAt: now)
                try? schedules.saveTakenMarks(stored)
            }
            undoToken = LibraryUndoToken(intakeID: id, message: "Logged \(favorite.displayName)")
            errorMessage = nil
            load(now: now)
            return true
        } catch IntakeRepeatError.productUnavailable {
            errorMessage = IntakeRepeatError.productUnavailableMessage
            return false
        } catch {
            errorMessage = "Could not log it. Try again."
            return false
        }
    }

    /// Deletes the entry the last "Taken" wrote. False when there is nothing to undo. An entry that is
    /// already gone clears the offer, since there is nothing left to undo; any other failure keeps it.
    @discardableResult
    public func undo(now: Date) -> Bool {
        guard let token = undoToken else { return false }
        do {
            try store.delete(intakeID: token.intakeID, now: now)
            undoToken = nil
            load(now: now)
            return true
        } catch JournalError.intakeDeleted(_) {
            undoToken = nil
            load(now: now)
            return false
        } catch {
            errorMessage = "Could not undo. Try again."
            return false
        }
    }

    /// Deletes the entry a Taken tap recorded for this time, after the Undo offer is gone (the screen shows
    /// Undo Taken only then): a Taken on the wrong time is put right from the list. False, with a message, when nothing was deleted. A time an
    /// entry logged elsewhere filled has no recorded entry, and is corrected in the Journal instead.
    @discardableResult
    public func undoTaken(_ slot: SupplementSlot, now: Date) -> Bool {
        guard let entryID = slot.recordedEntryID else { return false }
        do {
            try store.delete(intakeID: entryID, now: now)
            if undoToken?.intakeID == entryID { undoToken = nil }
            load(now: now)
            return true
        } catch JournalError.intakeDeleted(_) {
            load(now: now)
            return false
        } catch {
            errorMessage = "Could not undo. Try again."
            return false
        }
    }

    /// Clears the token when the Undo window ends, but only if it is still the current one.
    public func expireUndo(_ token: LibraryUndoToken) {
        if undoToken == token { undoToken = nil }
    }

    /// Drops any pending Undo offer, for when the screen goes away.
    public func clearUndo() {
        undoToken = nil
    }

    // MARK: Showing

    /// A screen with this id came into view: read everything, and follow the app's reloads until every
    /// screen showing the list has gone away.
    public func appeared(_ screen: UUID, now: Date) {
        shownBy.insert(screen)
        load(now: now)
    }

    /// The screen with this id went away. When no screen shows the list any more, stop following the app's
    /// reloads and drop the Undo offer, whose toast is gone.
    public func disappeared(_ screen: UUID) {
        shownBy.remove(screen)
        if !isShown { clearUndo() }
    }

    /// The journal may have changed somewhere in the app. Read again only while the list is on screen; a
    /// list out of view reads everything when it next appears, so nothing is read for no one.
    public func reloadIfShown(now: Date) {
        if isShown { load(now: now) }
    }

    /// Erase all data or a restore replaced what the stores hold. The Undo offer refers to an entry that may
    /// be gone, so it is dropped, and nothing read before is kept: the list is read again if it is on
    /// screen and emptied if it is not, so no erased name waits in memory for the next appearance.
    public func storesWereReplaced(now: Date) {
        undoToken = nil
        replacements += 1
        if isShown {
            load(now: now)
        } else {
            // Nothing from before the replacement is kept, a message about it included.
            forget()
            rows = []
            candidates = []
            errorMessage = nil
            readFailed = false
        }
    }

    // MARK: Helpers

    /// Reads the list again and then says why nothing happened. In that order: `load` clears the message
    /// it finds, so a message set before it would never be shown.
    private func refuse(_ message: String, now: Date) -> Bool {
        load(now: now)
        errorMessage = message
        return false
    }

    /// The category an entry typed as a supplement carries when it has no product snapshot.
    static let supplementCategory = "supplement"

    static func matchKey(_ favorite: FavoriteTemplate) -> String {
        SupplementStackDay.matchKey(
            category: favorite.category, snapshotID: favorite.productSnapshotID,
            names: favorite.components.map(\.name))
    }

    static func matchKey(_ template: RepeatTemplate) -> String {
        SupplementStackDay.matchKey(
            category: template.category, snapshotID: template.productSnapshotID,
            names: template.components.map(\.name))
    }

    /// The favorite a recent supplement is saved as: the same exact decimal text the Library's star writes.
    /// Nil when an amount is unknown or cannot be written back as a decimal.
    private func makeFavorite(from template: RepeatTemplate, title: String) -> FavoriteTemplate? {
        guard !template.components.isEmpty,
              template.components.allSatisfy({
                  !$0.amount.isNaN && AmountParser.parse(DecimalFormatting.text($0.amount)) != nil
              })
        else { return nil }
        let favoriteID = makeID()
        // The units the entry was logged in follow it into the favorite, keyed by the favorite's own id.
        if let units = store as? JournalLoggedUnits {
            for component in template.components where component.unit == .mL {
                guard let loggedUnit = template.loggedUnits[component.componentID] else { continue }
                // A unit that cannot be written refuses the favorite, so it never saves without its unit.
                do {
                    try units.recordLoggedUnit(JournalLoggedUnit(
                        intakeID: favoriteID, componentID: component.componentID, unit: loggedUnit))
                } catch { return nil }
            }
        }
        return FavoriteTemplate(
            id: favoriteID, displayName: title, category: template.category,
            components: template.components.map {
                FavoriteComponent(
                    componentID: $0.componentID, name: $0.name, amountText: DecimalFormatting.text($0.amount),
                    unitSymbol: $0.unit.symbol)
            },
            productSnapshotID: template.productSnapshotID, meal: template.meal)
    }
}
