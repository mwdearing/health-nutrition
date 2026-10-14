import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

private struct UnreadableRevision: Error {}

/// Forwards to a real store, counts the reads of every active entry (the one read that grows with the whole
/// journal) and can refuse to read chosen entries' revisions.
private final class StackReadCountingStore: JournalStore, @unchecked Sendable {
    let inner: SwiftDataJournalStore
    private(set) var activeIntakesCalls = 0
    var unreadableIntakeIDs: Set<String> = []

    init(inner: SwiftDataJournalStore) { self.inner = inner }

    var failNextSaveForTesting: Bool {
        get { inner.failNextSaveForTesting }
        set { inner.failNextSaveForTesting = newValue }
    }

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws
        -> IntakeRevision
    {
        try inner.create(intake, components: components, product: product, now: now)
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?
    ) throws -> IntakeRevision {
        try inner.edit(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }
    func delete(intakeID: String, now: Date) throws { try inner.delete(intakeID: intakeID, now: now) }
    func activeIntakes() throws -> [Intake] {
        activeIntakesCalls += 1
        return try inner.activeIntakes()
    }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        if unreadableIntakeIDs.contains(intakeID) { throw UnreadableRevision() }
        return try inner.revisions(of: intakeID)
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? { try inner.product(snapshotID: snapshotID) }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }
}

/// The supplement list: its schedules, where each of today's times stands, the one-tap "Taken" and the
/// stored schedules.
///
/// Synthetic names and ids only. Lowercase UUID intake ids.
@MainActor
final class SupplementStackTests: XCTestCase {
    /// Wednesday 2023-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)
    private let eight = ReminderTime(hour: 8, minute: 0)
    private let twenty = ReminderTime(hour: 20, minute: 0)
    private let british = Locale(identifier: "en_GB")

    // MARK: Fixtures

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore() throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: try makeDirectory().appendingPathComponent("journal.store"))
    }

    private func makeFavorites() throws -> SwiftDataFavoritesStore {
        try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "supplement-stack-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeSchedules() throws -> UserDefaultsSupplementStackStore {
        UserDefaultsSupplementStackStore(defaults: try makeDefaults())
    }

    private func makeModel(
        store: JournalStore, favorites: FavoritesStore, schedules: SupplementStackStoring, zone: String = "UTC"
    ) -> SupplementStackViewModel {
        SupplementStackViewModel(store: store, favorites: favorites, schedules: schedules, timeZoneIdentifier: zone)
    }

    private func supplement(_ snapshot: String = "s-magnesium", name: String = "Example magnesium") -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshot, productID: "p-\(snapshot)", name: name, labelBasis: "per_serving",
            catalogOrigin: "dsld", catalogVersion: "1", kind: .supplement)
    }

    /// Writes one entry and returns its id.
    @discardableResult
    private func log(
        _ store: JournalStore, name: String = "Example magnesium", at date: Date, zone: String = "UTC",
        category: String = "supplement", meal: String? = nil, amount: Decimal = 1, unit: MeasureUnit = .capsule,
        product: ProductDefinition? = nil
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        try store.create(
            Intake(id: id, category: category, occurredAt: date, timeZoneIdentifier: zone, meal: meal),
            components: [IntakeComponent(componentID: slug, name: name, amount: amount, unit: unit)],
            product: product, now: date)
        return id
    }

    /// Saves the favorite a "Taken" logs from: one capsule of the synthetic magnesium.
    @discardableResult
    private func saveFavorite(
        _ favorites: FavoritesStore, id: String = "fav-magnesium", snapshot: String? = "s-magnesium",
        meal: String? = nil
    ) throws -> FavoriteTemplate {
        let favorite = FavoriteTemplate(
            id: id, displayName: "Example magnesium", category: "supplement",
            components: [
                FavoriteComponent(
                    componentID: "example-magnesium", name: "Example magnesium", amountText: "1", unitSymbol: "capsule"),
            ],
            productSnapshotID: snapshot, meal: meal)
        try favorites.add(favorite)
        return favorite
    }

    private func entries(on dayKey: String, in store: JournalStore) throws -> [Intake] {
        try store.activeIntakes().filter {
            $0.lifecycle == .active && IntakeCopier.dayKey($0.occurredAt, zoneIdentifier: $0.timeZoneIdentifier) == dayKey
        }
    }

    // MARK: Schedules

    func testScheduleRefusesWhatCannotBeAPlanAndSortsTimes() throws {
        XCTAssertNil(SupplementSchedule(times: []))
        XCTAssertNil(SupplementSchedule(times: [eight, eight]))
        XCTAssertNil(SupplementSchedule(times: (0..<7).map { ReminderTime(hour: $0, minute: 0) }))
        XCTAssertNil(SupplementSchedule(times: [eight], weekdays: []))
        XCTAssertNil(SupplementSchedule(times: [eight], weekdays: [0]))
        XCTAssertNil(SupplementSchedule(times: [eight], weekdays: [8]))
        XCTAssertNotNil(SupplementSchedule(times: (0..<6).map { ReminderTime(hour: $0, minute: 0) }))

        let schedule = try XCTUnwrap(SupplementSchedule(times: [twenty, eight], weekdays: [2, 4]))
        XCTAssertEqual(schedule.times, [eight, twenty])
        XCTAssertFalse(schedule.isEveryDay)
        XCTAssertTrue(SupplementSchedule.standard.isEveryDay)
        XCTAssertEqual(SupplementSchedule.standard.times, [eight])
    }

    func testSummaryAndSlotWords() throws {
        let schedule = try XCTUnwrap(SupplementSchedule(times: [twenty, eight], weekdays: [6, 2, 4]))
        XCTAssertEqual(SupplementStackText.summary(schedule, locale: british), "Mon, Wed, Fri at 08:00 and 20:00")
        XCTAssertEqual(SupplementStackText.summary(.standard, locale: british), "Every day at 08:00")
        XCTAssertEqual(
            SupplementStackText.slot(SupplementSlot(time: eight, state: .notLogged), locale: british), "08:00 · Not logged")
        XCTAssertEqual(
            SupplementStackText.slot(SupplementSlot(time: twenty, state: .later), locale: british), "20:00 · Later today")
        XCTAssertEqual(SupplementStackText.slot(SupplementSlot(time: eight, state: .taken), locale: british), "08:00 · Taken")
    }

    // MARK: Stored schedules

    func testStoreRoundTripsSchedulesAndEraseRemovesTheKey() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsSupplementStackStore(defaults: defaults)
        let schedule = try XCTUnwrap(
            SupplementSchedule(times: [eight, ReminderTime(hour: 20, minute: 30)], weekdays: [2, 4, 6]))
        try store.save(["fav-a": schedule, "fav-b": .standard])
        XCTAssertEqual(store.schedules(), ["fav-a": schedule, "fav-b": .standard])

        try store.eraseAll()
        XCTAssertNil(defaults.object(forKey: UserDefaultsSupplementStackStore.key))
        XCTAssertEqual(store.schedules(), [:])
    }

    func testStoreDropsDamagedSchedulesAndKeepsTheRest() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsSupplementStackStore(defaults: defaults)
        let stored = """
            {"fav-good": {"times": ["08:00", "20:00"], "weekdays": [1, 2, 3, 4, 5, 6, 7]},
             "fav-hour": {"times": ["25:00"], "weekdays": [1]},
             "fav-text": {"times": ["eight"], "weekdays": [1]},
             "fav-twice": {"times": ["08:00", "08:00"], "weekdays": [1]},
             "fav-no-days": {"times": ["08:00"], "weekdays": []},
             "fav-day": {"times": ["08:00"], "weekdays": [9]},
             "fav-repeated-day": {"times": ["08:00"], "weekdays": [1, 1]},
             "fav-shape": "every morning"}
            """
        defaults.set(Data(stored.utf8), forKey: UserDefaultsSupplementStackStore.key)
        let read = store.schedules()
        XCTAssertEqual(Set(read.keys), ["fav-good"])
        XCTAssertEqual(read["fav-good"]?.times, [eight, twenty])

        defaults.set(Data("[1, 2]".utf8), forKey: UserDefaultsSupplementStackStore.key)
        XCTAssertEqual(store.schedules(), [:])
        defaults.set("not data", forKey: UserDefaultsSupplementStackStore.key)
        XCTAssertEqual(store.schedules(), [:])
    }

    // MARK: Today's times

    func testEachEntryMarksTheTimeItBelongsToAndExtrasMarkNothing() throws {
        let schedule = try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))
        func states(_ logged: [Int], at minute: Int) -> [SupplementSlotState] {
            SupplementStackDay.slots(for: schedule, loggedMinutes: logged, minuteOfDay: minute).map(\.state)
        }
        let h = 60
        XCTAssertEqual(states([], at: 7 * h + 59), [.later, .later])
        XCTAssertEqual(states([], at: 8 * h), [.notLogged, .later])
        XCTAssertEqual(states([9 * h], at: 12 * h), [.taken, .later])
        // Early: a little before its time, or before every time, still counts for that time.
        XCTAssertEqual(states([7 * h + 50], at: 12 * h), [.taken, .later])
        XCTAssertEqual(states([6 * h], at: 12 * h), [.taken, .later])
        XCTAssertEqual(states([19 * h + 55], at: 21 * h), [.notLogged, .taken])
        // Late: the morning dose taken in the afternoon is still the morning's, not the evening's.
        XCTAssertEqual(states([14 * h + 30], at: 15 * h), [.taken, .later])
        XCTAssertEqual(states([18 * h], at: 18 * h + 30), [.taken, .later])
        // An hour early is still early.
        XCTAssertEqual(states([19 * h], at: 19 * h + 30), [.notLogged, .taken])
        // The morning was missed and the evening taken: the evening is marked, and an extra evening entry
        // never marks the missed morning.
        XCTAssertEqual(states([20 * h + 30], at: 21 * h), [.notLogged, .taken])
        XCTAssertEqual(states([20 * h + 40, 20 * h + 30], at: 21 * h), [.notLogged, .taken])
        XCTAssertEqual(states([9 * h, 10 * h, 11 * h], at: 12 * h), [.taken, .later])
        XCTAssertEqual(states([9 * h, 20 * h + 5], at: 21 * h), [.taken, .taken])
    }

    func testTheCountFollowsTheMarkedTimesAndSaysWhenMoreWasLogged() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        // Two entries in the evening, the morning missed; read at 21:00.
        try log(store, at: now.addingTimeInterval(8.5 * 3_600))
        try log(store, at: now.addingTimeInterval(8.6 * 3_600))
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now.addingTimeInterval(9 * 3_600))
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .taken])
        XCTAssertEqual(model.rows.first?.statusText, "1 of 2 taken today · logged 2 today")
    }

    func testAMissedMorningAndATakenEveningReadThatWay() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        // Wednesday 20:30 UTC, read at 21:00.
        try log(store, at: now.addingTimeInterval(8.5 * 3_600))
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now.addingTimeInterval(9 * 3_600))
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .taken])
        XCTAssertEqual(model.rows.first?.statusText, "1 of 2 taken today")
    }

    func testClockReadsTheWallClockOnTheDayDaylightSavingStarts() throws {
        // 2023-03-12 13:30 UTC: clocks in Chicago went from 02:00 to 03:00 that morning, so it is 08:30
        // there (UTC-5), not the 07:30 a standard-time offset would give.
        let clock = try XCTUnwrap(
            SupplementStackClock(now: Date(timeIntervalSince1970: 1_678_627_800), zoneIdentifier: "America/Chicago"))
        XCTAssertEqual(clock.dayKey, "2023-03-12")
        XCTAssertEqual(clock.weekday, 1)
        XCTAssertEqual(clock.minuteOfDay, 8 * 60 + 30)
        XCTAssertNil(SupplementStackClock(now: now, zoneIdentifier: "Not/AZone"))
    }

    // MARK: The list

    func testTakenLogsTheFavoriteWithItsLabelSnapshotAndUndoUnmarksIt() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let product = supplement()
        // Two days ago, so the snapshot is in the journal; it is not today and does not count.
        try log(store, at: now.addingTimeInterval(-2 * 86_400), product: product)
        try saveFavorite(favorites)
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)

        let candidate = try XCTUnwrap(model.candidates.first { $0.id == "favorite:fav-magnesium" })
        XCTAssertEqual(candidate.kind, .supplement)
        XCTAssertTrue(model.add(candidate, schedule: try XCTUnwrap(SupplementSchedule(times: [eight, twenty])), now: now))
        XCTAssertFalse(model.candidates.contains { $0.id == "favorite:fav-magnesium" })
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(row.slots.map(\.state), [.notLogged, .later])
        XCTAssertEqual(row.statusText, "0 of 2 taken today")
        XCTAssertEqual(row.kind, .supplement)

        XCTAssertTrue(model.markTaken(row, now: now))
        let logged = try entries(on: "2023-11-15", in: store)
        XCTAssertEqual(logged.count, 1)
        let entry = try XCTUnwrap(logged.first)
        XCTAssertEqual(entry.occurredAt, now)
        XCTAssertEqual(entry.category, "supplement")
        let revision = try XCTUnwrap(store.revisions(of: entry.id).first)
        XCTAssertEqual(revision.productSnapshotID, product.snapshotID)
        XCTAssertEqual(revision.components.map(\.amount), [1])
        XCTAssertEqual(revision.components.map(\.unit), [.capsule])
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.taken, .later])
        XCTAssertEqual(model.rows.first?.statusText, "1 of 2 taken today")
        XCTAssertEqual(model.undoToken?.intakeID, entry.id)

        XCTAssertTrue(model.undo(now: now))
        XCTAssertNil(model.undoToken)
        XCTAssertTrue(try entries(on: "2023-11-15", in: store).isEmpty)
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .later])
    }

    func testEntriesFromElsewhereCountOnTheirOwnLocalDayWhateverTheMeal() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let product = supplement()
        // Yesterday 23:00 UTC: not today.
        try log(store, at: now.addingTimeInterval(-13 * 3_600), product: product)
        // 02:00 UTC today, but 20:00 yesterday in Chicago, the zone it was logged in: not today either.
        try log(store, at: now.addingTimeInterval(-10 * 3_600), zone: "America/Chicago", product: product)
        // Today at 09:00 with lunch named, from the Library: counts.
        try log(store, at: now.addingTimeInterval(-3 * 3_600), meal: "lunch", product: product)
        // Another supplement today: does not count.
        try log(store, name: "Example zinc", at: now.addingTimeInterval(-3_600), product: supplement("s-zinc", name: "Example zinc"))
        try saveFavorite(favorites, meal: "breakfast")
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])

        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(row.loggedToday, 1)
        XCTAssertEqual(row.slots.map(\.state), [.taken, .later])
    }

    func testDayOffTheScheduleShowsNoTimes() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        // Mondays only; the fixture's day is a Wednesday.
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight], weekdays: [2]))])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertFalse(row.isDueToday)
        XCTAssertTrue(row.slots.isEmpty)
        XCTAssertEqual(row.statusText, "Not on today's schedule")
        XCTAssertEqual(row.kind, .supplement)
        XCTAssertTrue(row.canLog)
    }

    func testRemovedFavoriteLeavesTheListAndCannotBeLoggedFromAStaleRow() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let row = try XCTUnwrap(model.rows.first)

        try favorites.remove(id: "fav-magnesium")
        XCTAssertFalse(model.markTaken(row, now: now))
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertEqual(model.errorMessage, "This item is no longer on your supplements.")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(schedules.schedules()["fav-magnesium"])
    }

    func testRemoveTakesTheItemOffButKeepsTheFavorite() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)

        XCTAssertTrue(model.remove(favoriteID: "fav-magnesium", now: now))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(try favorites.list().map(\.id), ["fav-magnesium"])
        XCTAssertEqual(model.candidates.map(\.id), ["favorite:fav-magnesium"])
    }

    func testSetScheduleChangesTimesOnlyForAnItemOnTheList() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)

        let evening = try XCTUnwrap(SupplementSchedule(times: [twenty], weekdays: [4]))
        XCTAssertTrue(model.setSchedule(evening, for: "fav-magnesium", now: now))
        XCTAssertEqual(schedules.schedules()["fav-magnesium"], evening)
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.later])

        XCTAssertFalse(model.setSchedule(evening, for: "fav-other", now: now))
        XCTAssertNil(schedules.schedules()["fav-other"])
    }

    func testRecentSupplementIsOfferedAndAddingItSavesAFavorite() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try log(store, at: now.addingTimeInterval(-3_600), product: supplement())
        try log(store, name: "Oats", at: now.addingTimeInterval(-7_200), category: "food", amount: 40, unit: .g)
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)

        XCTAssertEqual(model.candidates.count, 1)
        let candidate = try XCTUnwrap(model.candidates.first)
        XCTAssertTrue(candidate.id.hasPrefix("recent:"))
        XCTAssertEqual(candidate.kind, .supplement)

        XCTAssertTrue(model.add(candidate, schedule: .standard, now: now))
        let saved = try XCTUnwrap(try favorites.list().first)
        XCTAssertEqual(saved.productSnapshotID, "s-magnesium")
        XCTAssertEqual(saved.category, "supplement")
        XCTAssertEqual(saved.components.map(\.amountText), ["1"])
        XCTAssertEqual(saved.components.map(\.unitSymbol), ["capsule"])
        XCTAssertEqual(schedules.schedules()[saved.id], .standard)
        XCTAssertEqual(model.rows.map(\.id), [saved.id])
        XCTAssertEqual(model.rows.first?.loggedToday, 1)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testNothingThatMatchesAnItemOnTheListIsOfferedOrAdded() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        // The same product logged with dinner, a second favorite of it with dinner, and the breakfast one
        // on the list: an entry of it would count for every one of them.
        try log(store, at: now.addingTimeInterval(-3_600), meal: "dinner", product: supplement())
        try saveFavorite(favorites, meal: "breakfast")
        let dinner = try saveFavorite(favorites, id: "fav-magnesium-dinner", meal: "dinner")
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        XCTAssertTrue(model.candidates.isEmpty)

        // A candidate from a picker opened before the list changed is refused as well: it is judged by what
        // the favorite holds when it is added.
        let stale = SupplementStackCandidate(
            id: "favorite:\(dinner.id)", title: dinner.displayName, detail: "1 capsule", kind: .supplement,
            source: .favorite(dinner.id))
        XCTAssertFalse(model.add(stale, schedule: .standard, now: now))
        XCTAssertEqual(model.errorMessage, "This is already on your supplements.")
        // A refused add is not a failed read: the list is still shown as it is.
        XCTAssertFalse(model.readFailed)
        XCTAssertEqual(Set(schedules.schedules().keys), ["fav-magnesium"])
    }

    func testMinuteRefreshMovesTimesOnWithoutReadingTheJournalUntilANewDay() throws {
        let inner = try makeStore()
        let store = StackReadCountingStore(inner: inner)
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)

        // Wednesday 07:30, then 08:30: the morning time passes with nothing logged.
        let morning = now.addingTimeInterval(-4.5 * 3_600)
        model.load(now: morning)
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.later, .later])
        let reads = store.activeIntakesCalls
        model.refreshClock(now: morning.addingTimeInterval(3_600))
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .later])
        XCTAssertEqual(store.activeIntakesCalls, reads)

        // Wednesday 23:30 with one entry, then Thursday 00:30: the new day is read again and starts empty.
        let lateEvening = now.addingTimeInterval(11.5 * 3_600)
        try log(inner, at: now.addingTimeInterval(11 * 3_600))
        model.load(now: lateEvening)
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .taken])
        let beforeMidnight = store.activeIntakesCalls
        model.refreshClock(now: lateEvening.addingTimeInterval(3_600))
        XCTAssertGreaterThan(store.activeIntakesCalls, beforeMidnight)
        XCTAssertEqual(model.rows.first?.loggedToday, 0)
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.later, .later])
    }

    func testUnreadableEntryIsReportedRatherThanReadAsNotTaken() throws {
        let inner = try makeStore()
        let store = StackReadCountingStore(inner: inner)
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        let entry = try log(inner, at: now.addingTimeInterval(-3_600))
        store.unreadableIntakeIDs = [entry]
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)

        model.load(now: now)
        XCTAssertEqual(model.unreadableEntriesToday, 1)
        XCTAssertEqual(model.rows.first?.loggedToday, 0)

        store.unreadableIntakeIDs = []
        model.load(now: now)
        XCTAssertEqual(model.unreadableEntriesToday, 0)
        XCTAssertEqual(model.rows.first?.loggedToday, 1)
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.taken, .later])
    }

    func testAFailedReadClearsWhatTheLastReadShowed() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try log(
            store, name: "Example zinc", at: now.addingTimeInterval(-3_600),
            product: supplement("s-zinc", name: "Example zinc"))
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.candidates.count, 1)

        favorites.close()
        model.load(now: now)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertEqual(model.errorMessage, "Could not read your supplements.")
        XCTAssertTrue(model.readFailed)
    }

    func testARecentStarredSinceThePickerOpenedIsAddedNotCopied() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try log(store, at: now.addingTimeInterval(-3_600), product: supplement())
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let candidate = try XCTUnwrap(model.candidates.first { $0.id.hasPrefix("recent:") })

        // Starred in another window while this picker was open.
        try saveFavorite(favorites, id: "fav-starred-elsewhere")
        XCTAssertTrue(model.add(candidate, schedule: .standard, now: now))
        XCTAssertEqual(try favorites.list().map(\.id), ["fav-starred-elsewhere"])
        XCTAssertEqual(Set(schedules.schedules().keys), ["fav-starred-elsewhere"])
    }

    func testPickerTimesRoundTripEveryMinuteInAZoneWithDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        for minute in 0..<(24 * 60) {
            let time = ReminderTime(hour: minute / 60, minute: minute % 60)
            let date = SupplementScheduleEditor.date(for: time, calendar: calendar)
            XCTAssertEqual(SupplementScheduleEditor.time(from: date, calendar: calendar), time)
            // Always on the same fixed day, never today, which may be a day the clocks change.
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            XCTAssertEqual([day.year, day.month, day.day], [2001, 1, 15])
        }
    }

    func testTheAppsReloadsReadTheJournalOnlyWhileTheListIsOnScreen() throws {
        let inner = try makeStore()
        let store = StackReadCountingStore(inner: inner)
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)

        model.reloadIfShown(now: now)
        XCTAssertEqual(store.activeIntakesCalls, 0)
        XCTAssertTrue(model.rows.isEmpty)

        model.appeared(now: now)
        XCTAssertEqual(model.rows.count, 1)
        let afterAppearing = store.activeIntakesCalls
        try log(inner, at: now.addingTimeInterval(-3_600))
        model.reloadIfShown(now: now)
        XCTAssertGreaterThan(store.activeIntakesCalls, afterAppearing)
        XCTAssertEqual(model.rows.first?.loggedToday, 1)

        // Shown twice (two windows), then closed in one: still followed.
        model.appeared(now: now)
        model.disappeared()
        let stillShown = store.activeIntakesCalls
        model.reloadIfShown(now: now)
        XCTAssertGreaterThan(store.activeIntakesCalls, stillShown)

        model.disappeared()
        let afterLeaving = store.activeIntakesCalls
        model.reloadIfShown(now: now)
        XCTAssertEqual(store.activeIntakesCalls, afterLeaving)
    }

    func testReplacedStoresDropTheUndoOfferAndWhatAHiddenListRead() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.appeared(now: now)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), now: now))
        XCTAssertNotNil(model.undoToken)

        // Shown: read again, and the offer is gone.
        model.storesWereReplaced(now: now)
        XCTAssertNil(model.undoToken)
        XCTAssertEqual(model.rows.count, 1)

        // Hidden: nothing read before is kept for the next appearance.
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), now: now))
        model.disappeared()
        model.storesWereReplaced(now: now)
        XCTAssertNil(model.undoToken)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testEraseEmptiesTheList() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        XCTAssertEqual(model.rows.count, 1)

        try (schedules as JournalErasing).eraseAll()
        model.load(now: now)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.candidates.map(\.id), ["favorite:fav-magnesium"])
    }

    func testUnreadableZoneShowsAMessageInsteadOfAList() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules, zone: "Not/AZone")
        model.load(now: now)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }
}
