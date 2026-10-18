import Foundation
import XCTest
@testable import NutritionUI

final class CalorieSummarySpokenTests: XCTestCase {
    /// VoiceOver reads remaining, then "Food, N calories" and "Burned, N calories", as one line.
    func testSpokenSummaryNamesFoodAndBurnedAsLabels() throws {
        let calories = CalorieRemaining(goal: 2000, food: 500, isPartial: false, burned: 120, remaining: 1620)
        // Thousands are grouped by the device locale, so the expected figures come from the same formatter.
        let remaining = BodyActivityViewModel.whole(1620), food = BodyActivityViewModel.whole(500), burned = BodyActivityViewModel.whole(120)
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: nil, footnote: "of 2000 Calories goal"),
            "\(remaining) calories remaining, Food, \(food) calories, Burned, \(burned) calories, of 2000 Calories goal")
    }

    /// Burned is left out when Health gave no reading, and the partial note joins the line when present.
    func testSpokenSummaryOmitsBurnedWithoutAReadingAndKeepsThePartialNote() throws {
        let calories = CalorieRemaining(goal: 2000, food: 500, isPartial: true, burned: nil, remaining: 1500)
        let remaining = BodyActivityViewModel.whole(1500), food = BodyActivityViewModel.whole(500)
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: "Some entries have no calories", footnote: nil),
            "\(remaining) calories remaining, Food, \(food) calories, Some entries have no calories")
    }
}
