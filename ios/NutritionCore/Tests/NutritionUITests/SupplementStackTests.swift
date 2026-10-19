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

    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?, unitRemovals: [String])throws -> IntakeRevision {
        try inner.editRemovingUnits(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier, unitRemovals: unitRemovals)
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

    func testEntriesFillTimesInOrderAndOnlyPassedTimesReadNotLogged() throws {
        let schedule = try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))
        func states(_ taken: Int, _ minute: Int) -> [SupplementSlotState] {
            SupplementStackDay.slots(
                for: schedule, recordedMinutes: [], unrecordedCount: taken, minuteOfDay: minute
            ).map(\.state)
        }
        XCTAssertEqual(states(0, 7 * 60 + 59), [.later, .later])
        XCTAssertEqual(states(0, 8 * 60), [.notLogged, .later])
        XCTAssertEqual(states(0, 12 * 60), [.notLogged, .later])
        XCTAssertEqual(states(1, 12 * 60), [.taken, .later])
        XCTAssertEqual(states(2, 12 * 60), [.taken, .taken])
        XCTAssertEqual(states(3, 12 * 60), [.taken, .taken])
        XCTAssertEqual(states(1, 21 * 60), [.taken, .notLogged])
    }

    func testARecordedTimeIsMarkedAndUnrecordedEntriesFillTheRest() throws {
        let schedule = try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))
        func states(_ recorded: [Int], _ unrecorded: Int, _ minute: Int) -> [SupplementSlotState] {
            SupplementStackDay.slots(
                for: schedule, recordedMinutes: recorded, unrecordedCount: unrecorded, minuteOfDay: minute
            ).map(\.state)
        }
        let h = 60
        // The morning was missed and the evening Taken: the evening is marked.
        XCTAssertEqual(states([20 * h], 0, 21 * h), [.notLogged, .taken])
        // An evening tap early, at dinner, still marks the evening.
        XCTAssertEqual(states([20 * h], 0, 18 * h + 30), [.notLogged, .taken])
        // An entry logged elsewhere fills the time still open.
        XCTAssertEqual(states([20 * h], 1, 21 * h), [.taken, .taken])
        // A recorded time the schedule no longer has, or one recorded twice, fills like an unrecorded entry.
        XCTAssertEqual(states([12 * h], 0, 21 * h), [.taken, .notLogged])
        XCTAssertEqual(states([20 * h, 20 * h], 0, 21 * h), [.taken, .taken])
        // More than there are times marks nothing more.
        XCTAssertEqual(states([8 * h, 20 * h], 2, 21 * h), [.taken, .taken])
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

    /// Two takes of the same favorite give two offers with the same text and different intake ids, so the toast
    /// keys each offer on its own id.
    func testTwoTakesOfTheSameFavoriteGiveTwoOffersWithDifferentIds() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let product = supplement()
        // Two days ago, so the product snapshot is in the journal for the repeat to copy.
        try log(store, at: now.addingTimeInterval(-2 * 86_400), product: product)
        try saveFavorite(favorites)
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let candidate = try XCTUnwrap(model.candidates.first { $0.id == "favorite:fav-magnesium" })
        XCTAssertTrue(model.add(candidate, schedule: try XCTUnwrap(SupplementSchedule(times: [eight, twenty])), now: now))
        let row = try XCTUnwrap(model.rows.first)

        XCTAssertTrue(model.markTaken(row, at: eight, now: now))
        let first = try XCTUnwrap(model.undoToken)
        XCTAssertTrue(model.markTaken(row, at: twenty, now: now))
        let second = try XCTUnwrap(model.undoToken)
        XCTAssertEqual(first.message, second.message)
        XCTAssertNotEqual(first.intakeID, second.intakeID)
    }

    /// The supplement load reads the logged units 3 times when nothing fails: call 1 is the read at load (line 150), call 2
    /// the read in makeCandidates (line 371), call 3 the recents read. Failing call 1 throws at load, so only 1 read runs (#415).
    func testSupplementLoadShowsNothingWhenItsOwnUnitReadFails() throws {
        let store = UnitReadCountingStore(inner: try makeStore())
        store.failsOnUnitReadCall = 1
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites)
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        XCTAssertEqual(store.unitReadCalls, 1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    /// Guards the read order: a full supplement load makes exactly 3 logged-unit reads and shows no error (#415).
    func testFullSupplementLoadReadsLoggedUnitsExactlyThreeTimes() throws {
        let store = UnitReadCountingStore(inner: try makeStore())
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites)
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        XCTAssertEqual(store.unitReadCalls, 3)
        XCTAssertNil(model.errorMessage)
    }

    /// The supplement load reads the logged units 3 times when nothing fails. This test fails call 2, the read in
    /// makeCandidates (line 371), so call 1 succeeds and the load stops at 2 reads (#415).
    func testSupplementCandidatesShowNothingWhenTheirOwnUnitReadFails() throws {
        let store = UnitReadCountingStore(inner: try makeStore())
        store.failsOnUnitReadCall = 2
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites)
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        XCTAssertEqual(store.unitReadCalls, 2)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.candidates.isEmpty)
    }

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
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.taken, .notLogged])
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

    func testARecentErasedSinceThePickerOpenedIsNotSavedBack() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try log(store, at: now.addingTimeInterval(-3_600), product: supplement())
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let candidate = try XCTUnwrap(model.candidates.first { $0.id.hasPrefix("recent:") })

        // Erased in another window while this picker's editor was open.
        try store.eraseAll()
        let replacementsBefore = model.replacements
        model.storesWereReplaced(now: now)
        XCTAssertEqual(model.replacements, replacementsBefore + 1)
        XCTAssertFalse(model.add(candidate, schedule: .standard, now: now))
        XCTAssertEqual(model.errorMessage, "Could not add it to your supplements.")
        XCTAssertTrue(try favorites.list().isEmpty)
        XCTAssertTrue(schedules.schedules().isEmpty)
    }

    func testARecentStarredMeanwhileWithOtherAmountsIsRefusedAndTheFavoriteOffered() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try log(store, at: now.addingTimeInterval(-3_600), amount: 2, product: supplement())
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let candidate = try XCTUnwrap(model.candidates.first { $0.id.hasPrefix("recent:") })

        // One capsule starred elsewhere; the picker showed two. A second favorite of the same item would be
        // removed with the first by the Library's star, so nothing is saved.
        try saveFavorite(favorites, id: "fav-one-capsule")
        XCTAssertFalse(model.add(candidate, schedule: .standard, now: now))
        XCTAssertEqual(model.errorMessage, "Could not add it to your supplements.")
        XCTAssertEqual(try favorites.list().map(\.id), ["fav-one-capsule"])
        XCTAssertTrue(schedules.schedules().isEmpty)
        XCTAssertEqual(model.candidates.map(\.id), ["favorite:fav-one-capsule"])
    }

    func testARecentIsRefusedWhenAnyFavoriteOfItHasOtherAmounts() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try log(store, at: now.addingTimeInterval(-3_600), amount: 2, product: supplement())
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let candidate = try XCTUnwrap(model.candidates.first { $0.id.hasPrefix("recent:") })

        // Starred twice elsewhere, with different meals: once with the picker's two capsules, once with one.
        func favorite(_ id: String, _ amount: String, meal: String) -> FavoriteTemplate {
            FavoriteTemplate(
                id: id, displayName: "Example magnesium", category: "supplement",
                components: [
                    FavoriteComponent(
                        componentID: "example-magnesium", name: "Example magnesium", amountText: amount,
                        unitSymbol: "capsule"),
                ],
                productSnapshotID: "s-magnesium", meal: meal)
        }
        try favorites.add(favorite("fav-two", "2", meal: "breakfast"))
        try favorites.add(favorite("fav-one", "1", meal: "lunch"))
        XCTAssertFalse(model.add(candidate, schedule: .standard, now: now))
        XCTAssertEqual(model.errorMessage, "Could not add it to your supplements.")
        XCTAssertTrue(schedules.schedules().isEmpty)
        XCTAssertEqual(Set(model.candidates.map(\.id)), ["favorite:fav-two", "favorite:fav-one"])
    }

    func testARecentWhoseAmountsChangedSinceThePickerOpenedIsNotSaved() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try log(store, at: now.addingTimeInterval(-3_600), amount: 2, product: supplement())
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        model.load(now: now)
        let candidate = try XCTUnwrap(model.candidates.first { $0.id.hasPrefix("recent:") })

        // A newer entry of the same item with one capsule, logged in another window.
        try log(store, at: now.addingTimeInterval(-60), amount: 1, product: supplement())
        XCTAssertFalse(model.add(candidate, schedule: .standard, now: now))
        XCTAssertEqual(model.errorMessage, "Could not add it to your supplements.")
        XCTAssertTrue(try favorites.list().isEmpty)
        XCTAssertTrue(schedules.schedules().isEmpty)
        // The picker now offers the amounts the journal holds.
        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertNotEqual(model.candidates.first, candidate)
    }

    func testATakenForATimeMarksThatTimeAndUndoAndDeleteDropTheMark() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        // Wednesday 20:30: the morning was missed, the evening is taken.
        let evening = now.addingTimeInterval(8.5 * 3_600)
        model.load(now: evening)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), at: twenty, now: evening))
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .taken])
        XCTAssertEqual(model.rows.first?.statusText, "1 of 2 taken today")
        let entry = try XCTUnwrap(model.undoToken?.intakeID)
        XCTAssertEqual(schedules.takenMarks()[entry]?.timeOfDay, twenty)

        XCTAssertTrue(model.undo(now: evening))
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .notLogged])
        XCTAssertTrue(schedules.takenMarks().isEmpty)

        // A Taken with no time fills the earliest open time, as an entry logged elsewhere does.
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), now: evening))
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.taken, .notLogged])
        XCTAssertTrue(schedules.takenMarks().isEmpty)

        // A mark whose entry is deleted elsewhere goes with it.
        model.clearUndo()
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), at: twenty, now: evening))
        let marked = try XCTUnwrap(model.undoToken?.intakeID)
        try store.delete(intakeID: marked, now: evening)
        model.load(now: evening)
        XCTAssertNil(schedules.takenMarks()[marked])

        // A time the schedule does not have is not recorded.
        let noon = ReminderTime(hour: 12, minute: 0)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), at: noon, now: evening))
        XCTAssertTrue(schedules.takenMarks().isEmpty)
    }

    func testUndoTakenDeletesTheEntryARecordedTimeCameFromAfterTheOfferIsGone() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        // Wednesday 08:05: the 20:00 line is tapped by mistake, and the Undo offer lapses.
        let morning = now.addingTimeInterval(-3.9 * 3_600)
        model.load(now: morning)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), at: twenty, now: morning))
        model.clearUndo()
        let evening = try XCTUnwrap(model.rows.first?.slots.last)
        XCTAssertEqual(evening.state, .taken)
        let entry = try XCTUnwrap(evening.recordedEntryID)

        XCTAssertTrue(model.undoTaken(evening, now: morning))
        XCTAssertTrue(try store.activeIntakes().filter { $0.lifecycle == .active && $0.id == entry }.isEmpty)
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.notLogged, .later])
        XCTAssertTrue(schedules.takenMarks().isEmpty)

        // A time an entry logged elsewhere filled names no entry, so there is nothing to undo here.
        try log(store, at: morning)
        model.load(now: morning)
        let filled = try XCTUnwrap(model.rows.first?.slots.first)
        XCTAssertEqual(filled.state, .taken)
        XCTAssertNil(filled.recordedEntryID)
        XCTAssertFalse(model.undoTaken(filled, now: morning))
        XCTAssertEqual(model.rows.first?.loggedToday, 1)
    }

    func testAMarkGoesWhenItsEntrysTimeIsCorrectedInTheJournal() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        // Wednesday 08:05: Taken for 08:00.
        let morning = now.addingTimeInterval(-3.9 * 3_600)
        model.load(now: morning)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), at: eight, now: morning))
        let entry = try XCTUnwrap(model.undoToken?.intakeID)
        XCTAssertNotNil(model.rows.first?.slots.first?.recordedEntryID)

        // The entry's time is corrected in the Journal to 20:30.
        let evening = now.addingTimeInterval(8.5 * 3_600)
        let revision = try XCTUnwrap(store.revisions(of: entry).first)
        try store.edit(
            intakeID: entry, components: revision.components, product: nil, changeReason: "time", now: evening,
            occurredAt: evening, timeZoneIdentifier: "UTC")
        model.load(now: evening)
        XCTAssertNil(schedules.takenMarks()[entry])
        // The entry now fills like any unrecorded one, and offers no Undo Taken.
        XCTAssertEqual(model.rows.first?.slots.map(\.state), [.taken, .notLogged])
        XCTAssertNil(model.rows.first?.slots.first?.recordedEntryID)
    }

    func testMarksFromAnotherDayAreDropped() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": try XCTUnwrap(SupplementSchedule(times: [eight, twenty]))])
        let model = makeModel(store: store, favorites: favorites, schedules: schedules)
        let yesterday = now.addingTimeInterval(-86_400)
        model.load(now: yesterday)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), at: eight, now: yesterday))
        XCTAssertEqual(schedules.takenMarks().count, 1)

        model.load(now: now)
        XCTAssertTrue(schedules.takenMarks().isEmpty)
        XCTAssertEqual(model.rows.first?.loggedToday, 0)
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

        let window = UUID()
        let other = UUID()
        model.appeared(window, now: now)
        XCTAssertEqual(model.rows.count, 1)
        let afterAppearing = store.activeIntakesCalls
        try log(inner, at: now.addingTimeInterval(-3_600))
        model.reloadIfShown(now: now)
        XCTAssertGreaterThan(store.activeIntakesCalls, afterAppearing)
        XCTAssertEqual(model.rows.first?.loggedToday, 1)

        // Shown in a second window, then closed there: still followed. The first window's appearance
        // reported again is still one screen.
        model.appeared(other, now: now)
        model.appeared(window, now: now)
        model.disappeared(other)
        let stillShown = store.activeIntakesCalls
        model.reloadIfShown(now: now)
        XCTAssertGreaterThan(store.activeIntakesCalls, stillShown)

        model.disappeared(window)
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
        let screen = UUID()
        model.appeared(screen, now: now)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), now: now))
        XCTAssertNotNil(model.undoToken)

        // Shown: read again, and the offer is gone.
        model.storesWereReplaced(now: now)
        XCTAssertNil(model.undoToken)
        XCTAssertEqual(model.rows.count, 1)

        // Hidden: nothing read before is kept for the next appearance, and an offer made while hidden goes.
        model.disappeared(screen)
        XCTAssertTrue(model.markTaken(try XCTUnwrap(model.rows.first), now: now))
        XCTAssertNotNil(model.undoToken)
        model.storesWereReplaced(now: now)
        XCTAssertNil(model.undoToken)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testStoreKeepsReadableMarksAndEraseRemovesThemToo() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsSupplementStackStore(defaults: defaults)
        let mark = SupplementTakenMark(favoriteID: "fav-a", dayKey: "2023-11-15", time: twenty, loggedAt: now)
        try store.saveTakenMarks(["entry-a": mark])
        XCTAssertEqual(store.takenMarks(), ["entry-a": mark])

        let stored = """
            {"entry-good": {"favoriteID": "fav-a", "dayKey": "2023-11-15", "time": "20:00", "loggedAt": 0},
             "entry-time": {"favoriteID": "fav-a", "dayKey": "2023-11-15", "time": "25:00", "loggedAt": 0},
             "entry-no-date": {"favoriteID": "fav-a", "dayKey": "2023-11-15", "time": "20:00"},
             "entry-shape": "evening"}
            """
        defaults.set(Data(stored.utf8), forKey: UserDefaultsSupplementStackStore.takenKey)
        XCTAssertEqual(Set(store.takenMarks().keys), ["entry-good"])

        try store.save(["fav-a": .standard])
        try store.eraseAll()
        XCTAssertNil(defaults.object(forKey: UserDefaultsSupplementStackStore.key))
        XCTAssertNil(defaults.object(forKey: UserDefaultsSupplementStackStore.takenKey))
    }

    // MARK: Upper limits

    private let men31 = ReferenceGroup(sex: .male, ageBand: .years31To50)

    /// A product whose label states `nutrients` per 100 g, logged as 100 g so the day holds exactly those.
    private func labelled(
        _ snapshot: String, name: String, kind: ProductKind, nutrients: [String: NutrientValue]
    ) -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshot, productID: "p-\(snapshot)", name: name, labelBasis: "per 100 g",
            catalogOrigin: "test", catalogVersion: "1", kind: kind, nutrients: nutrients)
    }

    private func makeLimitModel(
        store: JournalStore, favorites: FavoritesStore, schedules: SupplementStackStoring,
        group: ReferenceGroup?
    ) -> (SupplementStackViewModel, InMemoryDisplayPreferences) {
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(group)
        let model = SupplementStackViewModel(
            store: store, favorites: favorites, schedules: schedules, lookup: SnapshotNutrientFacts(),
            referencePreferences: preferences, timeZoneIdentifier: "UTC")
        return (model, preferences)
    }

    func testASupplementAboveASupplementOnlyLimitIsListedAndMarkedLikeTheVitaminsScreen() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let magnesium = labelled(
            "s-magnesium-400", name: "Example magnesium", kind: .supplement, nutrients: ["magnesium": .known(400, .mg)])
        try log(store, at: now.addingTimeInterval(-3_600), amount: 100, unit: .g, product: magnesium)
        try saveFavorite(favorites, snapshot: "s-magnesium-400")
        try schedules.save(["fav-magnesium": .standard])
        let (model, preferences) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: men31)
        model.load(now: now)

        XCTAssertTrue(model.hasReferenceGroup)
        XCTAssertFalse(model.limitCheckFailed)
        XCTAssertEqual(model.limitRows.map(\.nutrient), ["magnesium"])
        XCTAssertEqual(model.rows.first?.aboveUpperLimit, [NutrientNames.displayName(for: "magnesium")])

        // The vitamins and minerals screen reads the same day and reports the same rows.
        let gaps = NutrientGapsViewModel(store: store, lookup: SnapshotNutrientFacts(), preferences: preferences)
        gaps.load(now: now)
        XCTAssertEqual(model.limitRows, gaps.rows.filter { $0.status == .aboveUpperLimit })
    }

    func testFoodCountsOnlyTowardAnAllSourcesLimit() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        // The supplement on the list was logged two days ago, so only its label is in the journal today.
        let multi = labelled(
            "s-multi", name: "Example magnesium", kind: .supplement,
            nutrients: ["magnesium": .known(50, .mg), "vitaminC": .known(100, .mg)])
        try log(store, at: now.addingTimeInterval(-2 * 86_400), amount: 100, unit: .g, product: multi)
        // Today's food states more magnesium than the supplement limit and more vitamin C than the limit
        // on everything eaten and taken.
        let food = labelled(
            "s-food", name: "Example fortified cereal", kind: .food,
            nutrients: ["magnesium": .known(600, .mg), "vitaminC": .known(2_500, .mg)])
        try log(
            store, name: "Example fortified cereal", at: now.addingTimeInterval(-3_600), category: "food",
            amount: 100, unit: .g, product: food)
        try saveFavorite(favorites, snapshot: "s-multi")
        try schedules.save(["fav-magnesium": .standard])
        let (model, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: men31)
        model.load(now: now)

        XCTAssertEqual(model.limitRows.map(\.nutrient), ["vitaminC"])
        XCTAssertEqual(model.rows.first?.aboveUpperLimit, [NutrientNames.displayName(for: "vitaminC")])
    }

    func testWithoutAGroupOrALabelThereIsNothingToMark() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let magnesium = labelled(
            "s-magnesium-400", name: "Example magnesium", kind: .supplement, nutrients: ["magnesium": .known(400, .mg)])
        try log(store, at: now.addingTimeInterval(-3_600), amount: 100, unit: .g, product: magnesium)
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])

        let (noGroup, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: nil)
        noGroup.load(now: now)
        XCTAssertFalse(noGroup.hasReferenceGroup)
        XCTAssertTrue(noGroup.limitRows.isEmpty)
        XCTAssertEqual(noGroup.rows.first?.aboveUpperLimit, [])

        // With a group the day is above the limit, but an item with no label states nothing to mark.
        let (grouped, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: men31)
        grouped.load(now: now)
        XCTAssertEqual(grouped.limitRows.map(\.nutrient), ["magnesium"])
        XCTAssertEqual(grouped.rows.first?.aboveUpperLimit, [])
    }

    func testTheLimitCheckReadsTheJournalNoMoreThanTheListDoes() throws {
        let inner = try makeStore()
        let store = StackReadCountingStore(inner: inner)
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let magnesium = labelled(
            "s-magnesium-400", name: "Example magnesium", kind: .supplement, nutrients: ["magnesium": .known(400, .mg)])
        try log(inner, at: now.addingTimeInterval(-3_600), amount: 100, unit: .g, product: magnesium)
        try saveFavorite(favorites, snapshot: "s-magnesium-400")
        try schedules.save(["fav-magnesium": .standard])

        let (noGroup, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: nil)
        let before = store.activeIntakesCalls
        noGroup.load(now: now)
        let withoutGroup = store.activeIntakesCalls - before

        let (grouped, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: men31)
        let start = store.activeIntakesCalls
        grouped.load(now: now)
        XCTAssertEqual(grouped.limitRows.map(\.nutrient), ["magnesium"])
        XCTAssertEqual(store.activeIntakesCalls - start, withoutGroup)
    }

    func testAFailedLimitCheckIsSaidAndTheListStillShows() throws {
        let inner = try makeStore()
        let store = StackReadCountingStore(inner: inner)
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let entry = try log(inner, at: now.addingTimeInterval(-3_600))
        store.unreadableIntakeIDs = [entry]
        try saveFavorite(favorites, snapshot: nil)
        try schedules.save(["fav-magnesium": .standard])
        let (model, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: men31)
        model.load(now: now)
        XCTAssertTrue(model.limitCheckFailed)
        XCTAssertTrue(model.limitRows.isEmpty)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertFalse(model.readFailed)
    }

    func testReplacedStoresClearTheLimitNotesOfAHiddenList() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let magnesium = labelled(
            "s-magnesium-400", name: "Example magnesium", kind: .supplement, nutrients: ["magnesium": .known(400, .mg)])
        try log(store, at: now.addingTimeInterval(-3_600), amount: 100, unit: .g, product: magnesium)
        try saveFavorite(favorites, snapshot: "s-magnesium-400")
        try schedules.save(["fav-magnesium": .standard])
        let (model, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: men31)
        let screen = UUID()
        model.appeared(screen, now: now)
        XCTAssertFalse(model.limitRows.isEmpty)
        model.disappeared(screen)
        model.storesWereReplaced(now: now)
        XCTAssertTrue(model.limitRows.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testAnItemWhoseLabelUsesAnAliasIsMarkedLikeTheDaysTally() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let vitaminC = labelled(
            "s-vitamin-c", name: "Example magnesium", kind: .supplement, nutrients: ["vitamin-c": .known(2_500, .mg)])
        try log(store, at: now.addingTimeInterval(-3_600), amount: 100, unit: .g, product: vitaminC)
        try saveFavorite(favorites, snapshot: "s-vitamin-c")
        try schedules.save(["fav-magnesium": .standard])
        let (model, _) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: men31)
        model.load(now: now)
        XCTAssertEqual(model.limitRows.map(\.nutrient), ["vitaminC"])
        XCTAssertEqual(model.rows.first?.aboveUpperLimit, [NutrientNames.displayName(for: "vitaminC")])
    }

    func testAGroupChosenElsewhereIsPickedUpByTheMinuteRefresh() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        let schedules = try makeSchedules()
        let magnesium = labelled(
            "s-magnesium-400", name: "Example magnesium", kind: .supplement, nutrients: ["magnesium": .known(400, .mg)])
        try log(store, at: now.addingTimeInterval(-3_600), amount: 100, unit: .g, product: magnesium)
        try saveFavorite(favorites, snapshot: "s-magnesium-400")
        try schedules.save(["fav-magnesium": .standard])
        let (model, preferences) = makeLimitModel(store: store, favorites: favorites, schedules: schedules, group: nil)
        model.load(now: now)
        XCTAssertFalse(model.hasReferenceGroup)

        // Chosen on Vitamins and minerals in another window.
        preferences.setReferenceGroup(men31)
        model.refreshClock(now: now.addingTimeInterval(60))
        XCTAssertTrue(model.hasReferenceGroup)
        XCTAssertEqual(model.limitRows.map(\.nutrient), ["magnesium"])
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
