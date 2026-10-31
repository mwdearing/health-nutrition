import Combine
import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Diary's day header adds what other apps logged to Apple Health that day, as Today does, so the header reads
/// the whole day wherever an entry was logged (Mike, 2026-10-30).
/// Every component states 100 kcal of energy and nothing else, so a day's journal energy is known.
private struct EnergyFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        nutrient == "energy" ? .known(100, .kcal) : .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        value(for: component, nutrient: nutrient)
    }
}

@MainActor
final class DiaryHealthTotalsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// A day whose only entry is a glass of water, so the journal itself states no energy and no protein.
    private func waterOnlyDay(goals: GoalStore? = nil) throws -> (JournalViewModel, String) {
        let journal = try makeJournal()
        try journal.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Example water", amount: 250, unit: .mL)],
            product: nil, now: now)
        let model = JournalViewModel(
            store: journal, goals: goals, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        let key = JournalViewModel.dayKey(now, zone: TimeZone(identifier: "UTC")!)
        return (model, key)
    }

    /// Energy another app logged that day shows in the day header.
    func testTheDayHeaderEnergyIncludesHealthEnergyFromOtherApps() throws {
        let (model, key) = try waterOnlyDay()
        model.load(now: now)
        XCTAssertNil(model.sections.first { $0.id == key }?.energyText, "journal-only, the day states no energy")

        model.outsideIntakeByDay[key] = .read(values: ["energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertEqual(model.sections.first { $0.id == key }?.energyText, "620 Calories")
    }

    /// A goal bar in the day header counts what another app logged to Health that day.
    func testTheDayHeaderGoalBarIncludesHealthAmountsFromOtherApps() throws {
        let goals = InMemoryGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: 60, unit: .g))
        let (model, key) = try waterOnlyDay(goals: goals)
        model.outsideIntakeByDay[key] = .read(values: ["protein": 30], readKeys: ["protein"])
        model.load(now: now)

        let bar = try XCTUnwrap(model.sections.first { $0.id == key }?.headerBars.first { $0.id == "protein" })
        XCTAssertEqual(bar.state, .progress)
        XCTAssertEqual(bar.fraction, Decimal(string: "0.5"))
    }

    /// Health read for one day never changes another day's header, while it does change its own day's.
    func testHealthForOneDayLeavesOtherDaysJournalOnly() throws {
        let journal = try makeJournal()
        let yesterday = now.addingTimeInterval(-86_400)
        for occurredAt in [yesterday, now] {
            try journal.create(
                Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: occurredAt,
                       timeZoneIdentifier: "UTC"),
                components: [IntakeComponent(componentID: "water", name: "Example water", amount: 250, unit: .mL)],
                product: nil, now: occurredAt)
        }
        let model = JournalViewModel(store: journal, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        let utc = TimeZone(identifier: "UTC")!
        let key = JournalViewModel.dayKey(now, zone: utc), otherKey = JournalViewModel.dayKey(yesterday, zone: utc)
        model.outsideIntakeByDay[otherKey] = .read(values: ["energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertEqual(model.sections.first { $0.id == otherKey }?.energyText, "620 Calories")
        XCTAssertNil(model.sections.first { $0.id == key }?.energyText)
    }

    /// The Diary reads Health for a day as it comes on screen and adds it to that day's header.
    func testLoadingHealthForADayAddsItToThatDaysHeader() async throws {
        let (model, key) = try waterOnlyDay()
        var asked: [(Date, Date)] = []
        model.healthDayReader = { start, end in
            asked.append((start, end))
            return HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"]))
        }
        model.load(now: now)
        await model.loadHealthTotals(forDayKey: key, now: now)
        XCTAssertEqual(model.sections.first { $0.id == key }?.energyText, "620 Calories")
        let day = try XCTUnwrap(JournalViewModel.dayInterval(forKey: key, zone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(asked.first?.0, day.start, "the read starts at the day's start in the Diary's zone")
    }

    /// A past day is read once and kept; today is read again, because more can still be logged elsewhere.
    func testAPastDayIsReadOnceAndTodayIsReadAgain() async throws {
        let (model, key) = try waterOnlyDay()
        var reads = 0
        model.healthDayReader = { _, _ in
            reads += 1
            return HealthDayRead(.read(values: [:], readKeys: ["energy"]))
        }
        let tomorrow = now.addingTimeInterval(86_400)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        XCTAssertEqual(reads, 1, "a past day is read once")
        await model.loadHealthTotals(forDayKey: key, now: now)
        await model.loadHealthTotals(forDayKey: key, now: now)
        XCTAssertEqual(reads, 3, "today is read each time")
    }

    /// A past day that read "not connected" is read again later, so connecting Health later fills it in.
    func testAPastDayThatWasNotConnectedIsReadAgain() async throws {
        let (model, key) = try waterOnlyDay()
        var connected = false
        var reads = 0
        model.healthDayReader = { _, _ in
            reads += 1
            return HealthDayRead(connected ? .read(values: ["energy": 620], readKeys: ["energy"]) : .notConnected)
        }
        let tomorrow = now.addingTimeInterval(86_400)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        connected = true
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.sections.first { $0.id == key }?.energyText, "620 Calories")
    }

    /// A day across a daylight-saving change is that day in the zone: 23 hours when the clocks go forward.
    func testADaylightSavingDayIsTwentyThreeHoursLong() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let day = try XCTUnwrap(JournalViewModel.dayInterval(forKey: "2026-03-08", zone: zone))
        XCTAssertEqual(day.end.timeIntervalSince(day.start), 23 * 3600)
    }

    /// A key that names no real day is refused rather than read as some other day.
    func testAKeyThatNamesNoRealDayIsRefused() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertNil(JournalViewModel.dayInterval(forKey: "2026-02-31", zone: utc))
        XCTAssertNil(JournalViewModel.dayInterval(forKey: "not-a-day", zone: utc))
        XCTAssertNotNil(JournalViewModel.dayInterval(forKey: "2026-02-28", zone: utc))
    }

    /// One food entry on `now`'s day, with the given lookup.
    private func foodDay(lookup: NutrientFactsLookup) throws -> (JournalViewModel, String) {
        let journal = try makeJournal()
        try journal.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Example oats", amount: 40, unit: .g)],
            product: nil, now: now)
        let model = JournalViewModel(
            store: journal, lookup: lookup, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        return (model, JournalViewModel.dayKey(now, zone: TimeZone(identifier: "UTC")!))
    }

    /// A day whose food has no energy is not shown as Health's figure alone: the header stays journal-only.
    func testAFoodDayWithUnknownEnergyIsNotShownAsHealthsFigureAlone() throws {
        let (model, key) = try foodDay(lookup: UnknownNutrientFacts())
        model.outsideIntakeByDay[key] = .read(values: ["energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertNotEqual(model.sections.first { $0.id == key }?.energyText, "620 Calories")
    }

    /// A Health read that did not complete leaves the journal's known energy showing, not blank.
    func testAnIncompleteHealthReadKeepsTheJournalsEnergy() throws {
        let (model, key) = try foodDay(lookup: EnergyFacts())
        model.outsideIntakeByDay[key] = .read(values: [:], readKeys: [])
        model.load(now: now)
        XCTAssertEqual(model.sections.first { $0.id == key }?.energyText, "100 Calories")
    }

    /// A day read while it was today is read again in full once it is past, so later Health entries count.
    func testADayReadAsTodayIsReadAgainOnceItIsPast() async throws {
        let (model, key) = try waterOnlyDay()
        var reads = 0
        model.healthDayReader = { _, _ in
            reads += 1
            return HealthDayRead(.read(values: [:], readKeys: ["energy"]))
        }
        await model.loadHealthTotals(forDayKey: key, now: now)
        let tomorrow = now.addingTimeInterval(86_400)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        XCTAssertEqual(reads, 2, "read as today, then once in full as a past day, then kept")
    }

    /// A past day read in one zone is read again after the Diary's zone changes.
    func testAPastDayIsReadAgainAfterTheZoneChanges() async throws {
        let journal = try makeJournal()
        var zone = "UTC"
        let model = JournalViewModel(store: journal, timeZoneProvider: { zone }, locale: Locale(identifier: "en_US"))
        var reads = 0
        model.healthDayReader = { _, _ in
            reads += 1
            return HealthDayRead(.read(values: [:], readKeys: ["energy"]))
        }
        await model.loadHealthTotals(forDayKey: "2020-01-15", now: now)
        await model.loadHealthTotals(forDayKey: "2020-01-15", now: now)
        zone = "America/New_York"
        await model.loadHealthTotals(forDayKey: "2020-01-15", now: now)
        XCTAssertEqual(reads, 2, "kept in UTC, read again in New York")
    }

    /// A background Health read does not clear a copy's Undo notice.
    func testAHealthReadKeepsTheCopyUndoNotice() async throws {
        let journal = try makeJournal()
        let yesterday = now.addingTimeInterval(-86_400)
        try journal.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: yesterday, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Example oats", amount: 40, unit: .g)],
            product: nil, now: yesterday)
        let model = JournalViewModel(store: journal, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        model.load(now: now)
        let pastKey = JournalViewModel.dayKey(yesterday, zone: TimeZone(identifier: "UTC")!)
        XCTAssertNotNil(model.copyDayToToday(pastKey, now: now))
        let notice = try XCTUnwrap(model.copyNotice)
        model.healthDayReader = { _, _ in HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"])) }
        await model.loadHealthTotals(forDayKey: JournalViewModel.dayKey(now, zone: TimeZone(identifier: "UTC")!), now: now)
        XCTAssertEqual(model.copyNotice, notice)
    }

    /// A past day whose read had a failed query is read again, so a passing failure does not stick.
    func testAPastDayWithAFailedQueryIsReadAgain() async throws {
        let (model, key) = try waterOnlyDay()
        var reads = 0
        model.healthDayReader = { _, _ in
            reads += 1
            return HealthDayRead(.read(values: [:], readKeys: []), complete: reads > 1)
        }
        let tomorrow = now.addingTimeInterval(86_400)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        XCTAssertEqual(reads, 2, "read again after the failed read, then kept")
    }

    /// An older read that finishes after a newer one for the same day does not overwrite the newer figures.
    func testAnOlderReadFinishingLateDoesNotOverwriteANewerOne() async throws {
        let (model, key) = try waterOnlyDay()
        var calls = 0
        var releaseFirst: CheckedContinuation<Void, Never>?
        model.healthDayReader = { _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { releaseFirst = $0 }
                return HealthDayRead(.read(values: ["energy": 100], readKeys: ["energy"]))
            }
            return HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"]))
        }
        model.load(now: now)
        let first = Task { await model.loadHealthTotals(forDayKey: key, now: now) }
        while releaseFirst == nil { await Task.yield() }
        await model.loadHealthTotals(forDayKey: key, now: now)
        releaseFirst?.resume()
        await first.value
        XCTAssertEqual(model.sections.first { $0.id == key }?.energyText, "620 Calories")
    }

    /// Erase all data forgets every day's Health figures, and a read still running then is dropped.
    func testForgettingHealthTotalsClearsHeadersAndDropsARunningRead() async throws {
        let (model, key) = try waterOnlyDay()
        model.healthDayReader = { _, _ in HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"])) }
        model.load(now: now)
        let tomorrow = now.addingTimeInterval(86_400)
        await model.loadHealthTotals(forDayKey: key, now: tomorrow)
        XCTAssertNotNil(model.outsideIntakeByDay[key])

        var release: CheckedContinuation<Void, Never>?
        model.healthDayReader = { _, _ in
            await withCheckedContinuation { release = $0 }
            return HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"]))
        }
        model.forgetHealthTotals()
        let running = Task { await model.loadHealthTotals(forDayKey: key, now: tomorrow) }
        while release == nil { await Task.yield() }
        model.forgetHealthTotals()
        release?.resume()
        await running.value
        XCTAssertTrue(model.outsideIntakeByDay.isEmpty)
        model.load(now: now)
        XCTAssertNil(model.sections.first { $0.id == key }?.energyText)
    }

    /// A read that finishes after the Diary's zone changed is dropped, and the day is read again in the new zone.
    func testAReadThatFinishesAfterAZoneChangeIsDropped() async throws {
        let journal = try makeJournal()
        var zone = "UTC"
        let model = JournalViewModel(store: journal, timeZoneProvider: { zone }, locale: Locale(identifier: "en_US"))
        var reads = 0
        model.healthDayReader = { _, _ in
            reads += 1
            if reads == 1 { zone = "America/New_York" }
            return HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"]))
        }
        await model.loadHealthTotals(forDayKey: "2020-01-15", now: now)
        XCTAssertNil(model.outsideIntakeByDay["2020-01-15"], "the read for the old zone's day is not kept")
        await model.loadHealthTotals(forDayKey: "2020-01-15", now: now)
        await model.loadHealthTotals(forDayKey: "2020-01-15", now: now)
        XCTAssertEqual(reads, 2, "read again in the new zone, then kept")
    }

    /// A read that returns the same figures as before does not rebuild the Diary.
    func testAReadWithTheSameFiguresDoesNotReload() async throws {
        let (model, key) = try waterOnlyDay()
        model.healthDayReader = { _, _ in HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"])) }
        await model.loadHealthTotals(forDayKey: key, now: now)
        var rebuilds = 0
        let watch = model.$sections.dropFirst().sink { _ in rebuilds += 1 }
        await model.loadHealthTotals(forDayKey: key, now: now)
        watch.cancel()
        XCTAssertEqual(rebuilds, 0, "no reload for unchanged figures")
    }

    /// A day whose clocks change at midnight starts at the zone's real start of day, not at a shifted instant.
    func testADayWhoseMidnightIsSkippedStartsAtTheZonesStartOfDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = try XCTUnwrap(JournalViewModel.dayInterval(forKey: "2018-11-04", zone: zone))
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2018, month: 11, day: 4, hour: 12)))
        XCTAssertEqual(day.start, calendar.startOfDay(for: noon))
        XCTAssertEqual(day.end.timeIntervalSince(day.start), 23 * 3600)
    }

    /// After the Diary's zone changes, a past day's Health figures read for the old zone no longer show.
    func testAZoneChangeForgetsHealthFiguresForTheOldZone() async throws {
        let journal = try makeJournal()
        try journal.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Example water", amount: 250, unit: .mL)],
            product: nil, now: now)
        var zone = "UTC"
        let model = JournalViewModel(store: journal, timeZoneProvider: { zone }, locale: Locale(identifier: "en_US"))
        model.healthDayReader = { _, _ in HealthDayRead(.read(values: ["energy": 620], readKeys: ["energy"])) }
        model.load(now: now)
        let key = JournalViewModel.dayKey(now, zone: TimeZone(identifier: "UTC")!)
        await model.loadHealthTotals(forDayKey: key, now: now.addingTimeInterval(3 * 86_400))
        XCTAssertNotNil(model.outsideIntakeByDay[key])
        zone = "Asia/Tokyo"
        model.load(now: now)
        XCTAssertTrue(model.outsideIntakeByDay.isEmpty, "figures read for UTC days are forgotten")
    }
}
