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
/// Nothing about "taken" is stored. Each load counts today's entries of each item in the journal, so an
/// entry logged from the Library counts, and deleting or undoing an entry un-marks its time. The times
/// live in `SupplementStackStoring`; the amounts and the product snapshot live in the favorite, so a
/// "Taken" logs exactly what the favorite copied, label snapshot included.
@MainActor
public final class SupplementStackViewModel: ObservableObject {
    @Published public private(set) var rows: [SupplementStackRow] = []
    @Published public private(set) var candidates: [SupplementStackCandidate] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var undoToken: LibraryUndoToken?
    /// Today's entries whose current revision could not be read. Each may be an item on the list, so the
    /// screen says a time may read "Not logged" when it was taken rather than showing a count it cannot back.
    @Published public private(set) var unreadableEntriesToday = 0

    private let store: JournalStore
    private let favorites: FavoritesStore
    private let schedules: SupplementStackStoring
    private let zoneID: () -> String
    private let makeID: () -> String

    public init(
        store: JournalStore,
        favorites: FavoritesStore,
        schedules: SupplementStackStoring,
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.favorites = favorites
        self.schedules = schedules
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
    }

    private var bases: [RowBasis] = []
    /// Today's entries per item, as of the last full read, and the day they were counted for.
    private var counts: [String: Int] = [:]
    private var countedDay: String?

    // MARK: Reading

    /// Reads the favorites, the list and today's entries, and builds every row and the picker.
    public func load(now: Date) {
        do {
            let stored = try favorites.list()
            let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let planned = try pruned(schedules.schedules(), keeping: Set(byID.keys))
            guard let clock = SupplementStackClock(now: now, zoneIdentifier: zoneID()) else {
                forget()
                rows = []
                candidates = []
                errorMessage = "Your time zone could not be read, so today's list cannot be shown."
                return
            }
            let (counted, unreadable) = try loggedCounts(on: clock.dayKey)
            var kinds: [String: ProductKind] = [:]
            func kind(_ snapshotID: String?, category: String) -> ProductKind {
                guard let snapshotID else { return category == Self.supplementCategory ? .supplement : .food }
                if let known = kinds[snapshotID] { return known }
                let found = (try? store.product(snapshotID: snapshotID))?.kind ?? .food
                kinds[snapshotID] = found
                return found
            }
            bases = planned.compactMap { entry -> RowBasis? in
                guard let favorite = byID[entry.key] else { return nil }
                let template = RepeatTemplate(favorite: favorite)
                return RowBasis(
                    favoriteID: favorite.id, title: favorite.displayName,
                    detail: template.map { AmountText.summary($0.components) } ?? "unknown",
                    kind: kind(favorite.productSnapshotID, category: favorite.category), schedule: entry.value,
                    matchKey: Self.matchKey(favorite), canLog: template.map { !$0.components.isEmpty } ?? false)
            }
            .sorted { left, right in
                let leftFirst = left.schedule.times.first.map(SupplementSchedule.minuteOfDay) ?? 0
                let rightFirst = right.schedule.times.first.map(SupplementSchedule.minuteOfDay) ?? 0
                if leftFirst != rightFirst { return leftFirst < rightFirst }
                let order = left.title.localizedCaseInsensitiveCompare(right.title)
                return order == .orderedSame ? left.favoriteID < right.favoriteID : order == .orderedAscending
            }
            counts = counted
            countedDay = clock.dayKey
            unreadableEntriesToday = unreadable
            rows = makeRows(clock: clock)
            candidates = try makeCandidates(favorites: stored, planned: Set(planned.keys), kind: kind)
            errorMessage = nil
        } catch {
            // Nothing read before stays on screen: it may be exactly what an erase just removed, and a
            // picker row left behind could still be added.
            forget()
            rows = []
            candidates = []
            errorMessage = "Could not read your supplements."
        }
    }

    /// Moves today's times on as the clock does, without reading the journal or the favorites: a time that
    /// passes turns "Not logged". On another day, or in a zone where it is another day, it reads everything
    /// again instead, because the entries counted belong to the day they were counted for.
    public func refreshClock(now: Date) {
        guard let day = countedDay, let clock = SupplementStackClock(now: now, zoneIdentifier: zoneID()),
              clock.dayKey == day
        else {
            load(now: now)
            return
        }
        rows = makeRows(clock: clock)
    }

    private func makeRows(clock: SupplementStackClock) -> [SupplementStackRow] {
        bases.map { basis in
            let logged = counts[basis.matchKey] ?? 0
            let isDue = basis.schedule.weekdays.contains(clock.weekday)
            return SupplementStackRow(
                id: basis.favoriteID, title: basis.title, detail: basis.detail, kind: basis.kind,
                schedule: basis.schedule, isDueToday: isDue,
                slots: isDue
                    ? SupplementStackDay.slots(for: basis.schedule, takenCount: logged, minuteOfDay: clock.minuteOfDay)
                    : [],
                loggedToday: logged, canLog: basis.canLog)
        }
    }

    /// Drops what the last read kept, so the next refresh reads everything again.
    private func forget() {
        bases = []
        counts = [:]
        countedDay = nil
        unreadableEntriesToday = 0
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

    /// Today's entries per item, each on the local day of its own time zone, the rule the Journal groups by,
    /// and how many of today's entries could not be read. An unreadable entry is counted apart rather than
    /// skipped, because skipping it would read as "not taken".
    private func loggedCounts(on dayKey: String) throws -> (counts: [String: Int], unreadable: Int) {
        var counts: [String: Int] = [:]
        var unreadable = 0
        let today = try store.activeIntakes().filter {
            $0.lifecycle == .active && IntakeCopier.dayKey($0.occurredAt, zoneIdentifier: $0.timeZoneIdentifier) == dayKey
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
            counts[key, default: 0] += 1
        }
        return (counts, unreadable)
    }

    /// Favorites not on the list, supplements first, then supplements logged recently that no favorite
    /// stands for yet. Nothing is offered that matches the same entries as an item already on the list.
    private func makeCandidates(
        favorites stored: [FavoriteTemplate], planned: Set<String>,
        kind: (String?, String) -> ProductKind
    ) throws -> [SupplementStackCandidate] {
        let onList = Set(stored.filter { planned.contains($0.id) }.map { Self.matchKey($0) })
        let favoriteCandidates = stored
            .filter { !planned.contains($0.id) && !onList.contains(Self.matchKey($0)) }
            .map { favorite -> SupplementStackCandidate in
                let template = RepeatTemplate(favorite: favorite)
                return SupplementStackCandidate(
                    id: "favorite:\(favorite.id)", title: favorite.displayName,
                    detail: template.map { AmountText.summary($0.components) } ?? "unknown",
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
                detail: LibraryViewModel.detail(template), kind: .supplement, source: .recent(template)))
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
                guard let favorite = makeFavorite(from: template, title: candidate.title) else {
                    errorMessage = "This supplement has an amount that cannot be saved."
                    return false
                }
                newFavorite = favorite
                favoriteID = favorite.id
                key = Self.matchKey(favorite)
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
    /// The favorite is read again rather than taken from the row: a row on screen can outlive its favorite
    /// (removed in the Library, or erased from Settings), and logging from a copy would write an entry for
    /// something no longer on the list.
    @discardableResult
    public func markTaken(_ row: SupplementStackRow, now: Date) -> Bool {
        undoToken = nil
        do {
            guard schedules.schedules()[row.id] != nil,
                  let favorite = try favorites.list().first(where: { $0.id == row.id })
            else {
                return refuse("This item is no longer on your supplements.", now: now)
            }
            guard let template = RepeatTemplate(favorite: favorite), !template.components.isEmpty else {
                errorMessage = "This item has no amounts to log."
                return false
            }
            let repeater = IntakeRepeater(store: store, timeZoneProvider: zoneID, makeID: makeID)
            let id = try repeater.create(from: template, now: now)
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

    /// Clears the token when the Undo window ends, but only if it is still the current one.
    public func expireUndo(_ token: LibraryUndoToken) {
        if undoToken == token { undoToken = nil }
    }

    /// Drops any pending Undo offer, for when the screen goes away.
    public func clearUndo() {
        undoToken = nil
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
        return FavoriteTemplate(
            id: makeID(), displayName: title, category: template.category,
            components: template.components.map {
                FavoriteComponent(
                    componentID: $0.componentID, name: $0.name, amountText: DecimalFormatting.text($0.amount),
                    unitSymbol: $0.unit.symbol)
            },
            productSnapshotID: template.productSnapshotID, meal: template.meal)
    }
}
