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

    /// Today keeps hiding empty meals: a day with no entries lists nothing, and a lunch-only day lists lunch only.
    func testTodayStillHidesEmptyMeals() {
        XCTAssertEqual(JournalViewModel.mealGroups(for: []).map(\.title), [])
        XCTAssertEqual(
            JournalViewModel.mealGroups(for: [row("a", meal: "Lunch")]).map(\.title), ["Lunch"])
    }

    /// An empty named meal opens the add with its own meal; "Other" has no add.
    func testAddOpensWithTheGroupsOwnMeal() {
        XCTAssertEqual(JournalViewModel.addMeal(forGroupTitle: "Dinner"), .dinner)
        XCTAssertEqual(JournalViewModel.addMeal(forGroupTitle: "Snack"), .snack)
        XCTAssertNil(JournalViewModel.addMeal(forGroupTitle: "Other"))
    }
}
