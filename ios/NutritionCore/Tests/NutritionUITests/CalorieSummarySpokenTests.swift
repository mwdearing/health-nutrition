import Foundation
import XCTest
@testable import NutritionUI

final class CalorieSummarySpokenTests: XCTestCase {
    /// VoiceOver reads remaining, then "Food, N calories" and "Burned, N calories", as one line.
    func testSpokenSummaryNamesFoodAndBurnedAsLabels() throws {
        let calories = CalorieRemaining(goal: 2000, food: 500, isPartial: false, burned: 120, remaining: 1620)
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: nil, footnote: "of 2000 Calories goal"),
            "1,620 calories remaining, Food, 500 calories, Burned, 120 calories, of 2000 Calories goal")
    }

    /// Burned is left out when Health gave no reading, and the partial note joins the line when present.
    func testSpokenSummaryOmitsBurnedWithoutAReadingAndKeepsThePartialNote() throws {
        let calories = CalorieRemaining(goal: 2000, food: 500, isPartial: true, burned: nil, remaining: 1500)
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: "Some entries have no calories", footnote: nil),
            "1,500 calories remaining, Food, 500 calories, Some entries have no calories")
    }
}
