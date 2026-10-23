import Foundation
import XCTest
@testable import NutritionUI

@MainActor
final class CalorieSummarySpokenTests: XCTestCase {
    /// VoiceOver reads remaining, then "Food, N calories" and "Burned, N calories", as one line.
    func testSpokenSummaryNamesFoodAndBurnedAsLabels() throws {
        let calories = CalorieRemaining(goal: 2000, food: 500, isPartial: false, partialNote: nil, burned: 120, remaining: 1620)
        // Thousands are grouped by the device locale, so the expected figures come from the same formatter.
        let remaining = BodyActivityViewModel.whole(1620), food = BodyActivityViewModel.whole(500), burned = BodyActivityViewModel.whole(120)
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: nil, footnote: "of 2000 Calories goal"),
            "\(remaining) calories remaining, Food, \(food) calories, Burned, \(burned) calories, of 2000 Calories goal")
    }

    /// Burned is left out when Health gave no reading, and the partial note joins the line when present.
    func testSpokenSummaryOmitsBurnedWithoutAReadingAndKeepsThePartialNote() throws {
        let calories = CalorieRemaining.make(
            goal: 2000, food: 500, partial: true, missingCount: 1, burned: nil, energyLabel: "Energy")
        let remaining = BodyActivityViewModel.whole(1500), food = BodyActivityViewModel.whole(500)
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: calories.partialNote, footnote: nil),
            "\(remaining) calories remaining, Food, \(food) calories, 1 entry has no energy value")
    }

    /// With the goal off there is no Remaining, so the line is Food and Burned, then the same partial note.
    func testSpokenSummaryWithTheGoalOffKeepsFoodBurnedAndTheNote() throws {
        let calories = CalorieRemaining.make(
            goal: nil, food: 500, partial: true, missingCount: 2, burned: 120, energyLabel: "Energy")
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: calories.partialNote, footnote: nil),
            "Food, 500 calories, Burned, 120 calories, 2 entries have no energy value")
    }

    /// A partial day with no missing entry (a below-threshold amount) still speaks the fallback note.
    func testSpokenSummaryKeepsTheFallbackNoteForABelowThresholdDay() throws {
        let calories = CalorieRemaining.make(
            goal: 2000, food: 500, partial: true, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: calories.partialNote, footnote: nil),
            "\(BodyActivityViewModel.whole(1500)) calories remaining, Food, \(BodyActivityViewModel.whole(500)) calories, Some entries can't be added up for energy")
    }
}
