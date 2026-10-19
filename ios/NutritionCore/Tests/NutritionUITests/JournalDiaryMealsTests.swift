import Foundation
import XCTest
@testable import NutritionUI

@MainActor
final class JournalDiaryMealsTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(_ id: String, meal: String?) -> JournalRow {
        JournalRow(
            id: id, title: "Oats", detail: "40 g", occurredAt: when, timeZoneIdentifier: "UTC", meal: meal)
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

    /// The row's own call uses the default zone, the device zone the add flow stamps. It must agree with the
    /// explicit device zone, so a regression in the default would fail here.
    func testAddRowDefaultZoneIsTheDeviceZone() {
        let nearMidnight = Date(timeIntervalSince1970: 1_700_012_400)
        let deviceID = JournalViewModel.addDayID(now: nearMidnight, zone: TimeZone.current)
        XCTAssertEqual(JournalViewModel.addDayID(now: nearMidnight), deviceID)
        XCTAssertTrue(JournalViewModel.isAddDay(deviceID, now: nearMidnight))
    }
}
