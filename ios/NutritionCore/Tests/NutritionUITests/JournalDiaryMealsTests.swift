import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class JournalDiaryMealsTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(_ id: String, meal: String?) -> JournalRow {
        JournalRow(
            id: id, title: "Oats", detail: "40 g", occurredAt: when, timeZoneIdentifier: "UTC", meal: meal, countsAs: .food)
    }

    /// A Diary day with no entries lists the four named meals, all empty, and no "Other".
    func testDiaryDayWithNoEntriesListsAllFourMealsEmpty() {
        let groups = JournalViewModel.diaryMealGroups(for: [])
        XCTAssertEqual(groups.map(\.title), ["Breakfast", "Lunch", "Dinner", "Snack"])
        XCTAssertTrue(groups.allSatisfy { $0.rows.isEmpty })
    }

    /// A day where only lunch has entries still lists all four meals in order; the empty ones are kept.
    func testDiaryDayWithOneMealKeepsTheOtherNamedMealsEmpty() {
        let groups = JournalViewModel.diaryMealGroups(for: [row("a", meal: "Lunch")])
        XCTAssertEqual(groups.map(\.title), ["Breakfast", "Lunch", "Dinner", "Snack"])
        XCTAssertEqual(groups.map { $0.rows.count }, [0, 1, 0, 0])
    }

    /// "Other" appears last, and only when an entry has no named meal.
    func testOtherComesLastOnlyWhenAnEntryHasNoNamedMeal() {
        let groups = JournalViewModel.diaryMealGroups(for: [row("a", meal: nil), row("b", meal: "Dinner")])
        XCTAssertEqual(groups.map(\.title), ["Breakfast", "Lunch", "Dinner", "Snack", "Other"])
        XCTAssertEqual(groups.last?.rows.count, 1)
    }

    /// An empty named meal opens the add with its own meal; "Other" has no add.
    func testAddOpensWithTheGroupsOwnMeal() {
        XCTAssertEqual(JournalViewModel.addMeal(forGroupTitle: "Dinner"), .dinner)
        XCTAssertEqual(JournalViewModel.addMeal(forGroupTitle: "Snack"), .snack)
        XCTAssertNil(JournalViewModel.addMeal(forGroupTitle: "Other"))
    }

    /// The add row belongs to the day the add flow logs to: today in the given zone, and only that day.
    func testAddRowIsOfferedOnlyForToday() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(JournalViewModel.isAddDay("2023-11-14", now: when, zone: utc))
        XCTAssertFalse(JournalViewModel.isAddDay("2023-11-13", now: when, zone: utc))
        XCTAssertFalse(JournalViewModel.isAddDay("2023-11-15", now: when, zone: utc))
    }

    /// Today's day shows all four named meals, so an empty meal keeps its card and its add row.
    func testTodayShowsEmptyMealCards() {
        let groups = JournalViewModel.diaryMealGroups(for: [row("a", meal: "Lunch")])
        let utc = TimeZone(identifier: "UTC")!
        let visible = JournalViewModel.visibleMealGroups(groups, sectionID: "2023-11-14", now: when, zone: utc)
        XCTAssertEqual(visible.map(\.title), ["Breakfast", "Lunch", "Dinner", "Snack"])
        XCTAssertEqual(visible.map { $0.rows.count }, [0, 1, 0, 0])
    }

    /// A past day shows only meals with entries; an empty meal's card is gone there.
    func testPastDayShowsOnlyMealsWithEntries() {
        let groups = JournalViewModel.diaryMealGroups(for: [row("a", meal: "Lunch")])
        let visible = JournalViewModel.visibleMealGroups(groups, sectionID: "2023-11-13", now: when, zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(visible.map(\.title), ["Lunch"])
        XCTAssertEqual(visible.first?.rows.count, 1)
    }

    /// A past day with no entries shows no meal cards at all.
    func testPastDayWithNoEntriesShowsNothing() {
        let groups = JournalViewModel.diaryMealGroups(for: [])
        XCTAssertEqual(
            JournalViewModel.visibleMealGroups(groups, sectionID: "2023-11-13", now: when, zone: TimeZone(identifier: "UTC")!).count, 0)
    }

    /// Near midnight, the add row must sit on the section an entry added now lands in, in the zone the add flow
    /// stamps. Here it is 01:40 UTC on the 15th, which is 17:40 on the 14th in Los Angeles: the add lands on the 14th
    /// there, so the row sits on the 14th and not on the neighbouring 15th.
    func testAddRowSitsOnTheSectionAnAddNowLandsIn() {
        let nearMidnight = Date(timeIntervalSince1970: 1_700_012_400)  // 2023-11-15 01:40 UTC
        let utc = TimeZone(identifier: "UTC")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

        XCTAssertEqual(JournalViewModel.addDayID(now: nearMidnight, zone: utc), "2023-11-15")
        XCTAssertEqual(JournalViewModel.addDayID(now: nearMidnight, zone: losAngeles), "2023-11-14")
        XCTAssertTrue(JournalViewModel.isAddDay("2023-11-14", now: nearMidnight, zone: losAngeles))
        XCTAssertFalse(JournalViewModel.isAddDay("2023-11-15", now: nearMidnight, zone: losAngeles))
        XCTAssertTrue(JournalViewModel.isAddDay("2023-11-15", now: nearMidnight, zone: utc))
        XCTAssertFalse(JournalViewModel.isAddDay("2023-11-14", now: nearMidnight, zone: utc))
    }

    /// The default argument of the day helpers is the device zone the add flow stamps. The view's row goes through
    /// `showsAddRow`, which is covered below.
    func testAddRowDefaultZoneIsTheDeviceZone() {
        let nearMidnight = Date(timeIntervalSince1970: 1_700_012_400)
        let deviceID = JournalViewModel.addDayID(now: nearMidnight, zone: TimeZone.current)
        XCTAssertEqual(JournalViewModel.addDayID(now: nearMidnight), deviceID)
        XCTAssertTrue(JournalViewModel.isAddDay(deviceID, now: nearMidnight))
    }

    /// The model decides the add row in its own journal zone, so the row cannot drift from the arrows and Copy to today.
    func testShowsAddRowFollowsTheJournalZone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let nearMidnight = Date(timeIntervalSince1970: 1_700_012_400)  // 2023-11-15 01:40 UTC

        let losAngeles = JournalViewModel(store: store, timeZoneIdentifier: "America/Los_Angeles", locale: Locale(identifier: "en_US"))
        XCTAssertTrue(losAngeles.showsAddRow(sectionID: "2023-11-14", now: nearMidnight))
        XCTAssertFalse(losAngeles.showsAddRow(sectionID: "2023-11-15", now: nearMidnight))

        let utc = JournalViewModel(store: store, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        XCTAssertTrue(utc.showsAddRow(sectionID: "2023-11-15", now: nearMidnight))
        XCTAssertFalse(utc.showsAddRow(sectionID: "2023-11-14", now: nearMidnight))
    }

    /// The journal's production default zone is the device zone, the zone the add flow stamps new entries with.
    func testJournalDefaultZoneIsTheDeviceZone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let journal = JournalViewModel(store: store, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(journal.dayZone.identifier, TimeZone.current.identifier)
    }

    /// With only yesterday's entries, today still gets a section, so its four meal cards and add rows show.
    func testTodayGetsASectionWhenOnlyYesterdayHasEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let now = Date(timeIntervalSince1970: 1_700_012_400)  // 2023-11-15 01:40 UTC
        let yesterday = now.addingTimeInterval(-86_400)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: yesterday, timeZoneIdentifier: "UTC", meal: "Lunch"),
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)],
            product: nil, now: yesterday)

        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        journal.load(now: now)

        let today = try XCTUnwrap(journal.diarySections.first)
        XCTAssertEqual(today.id, "2023-11-15")
        // The Diary builds the four named meals for a day from its rows; the section's own list keeps its contract.
        let diary = JournalViewModel.diaryMealGroups(for: today.rows)
        XCTAssertEqual(diary.map(\.title), ["Breakfast", "Lunch", "Dinner", "Snack"])
        XCTAssertTrue(diary.allSatisfy { $0.rows.isEmpty })
        XCTAssertFalse(today.isCollapsedByDefault)
        XCTAssertTrue(journal.showsAddRow(sectionID: today.id, now: now))
        // The section list the jump, copy and collapse code reads is unchanged: today is not in it.
        XCTAssertFalse(journal.sections.contains { $0.id == "2023-11-15" })
    }

    /// A successful read with no entries lists nothing on the Diary path the view renders, and the journal reports
    /// its empty state. Without the readable-entry condition in load, today's empty section would appear here.
    func testEmptyJournalListsNothingOnTheDiaryPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        journal.load(now: Date(timeIntervalSince1970: 1_700_012_400))

        XCTAssertTrue(journal.diarySections.isEmpty)
        XCTAssertNil(journal.todaySection)
        XCTAssertTrue(journal.isEmpty)
    }
}
