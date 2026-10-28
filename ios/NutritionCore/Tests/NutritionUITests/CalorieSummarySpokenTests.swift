import Foundation
import XCTest
@testable import NutritionUI

@MainActor
final class CalorieSummarySpokenTests: XCTestCase {
    /// VoiceOver reads remaining, then "Food, N calories" and "Burned, N calories", as one line.
    func testSpokenSummaryNamesFoodAndBurnedAsLabels() throws {
        let calories = CalorieRemaining(
            goal: 2000, food: 500, isPartial: false, partialNote: nil, burned: 120, remaining: 1620)
        // Thousands are grouped by the device locale, so the expected figures come from the same formatter.
        let remaining = BodyActivityViewModel.whole(1620)
        let food = BodyActivityViewModel.whole(500)
        let burned = BodyActivityViewModel.whole(120)
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: nil, footnote: "of 2000 Calories goal"),
            "\(remaining) calories remaining, Food, \(food) calories, Burned, \(burned) calories, "
                + "of 2000 Calories goal")
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

    /// With the goal off and a known food total, the summary shows no Remaining, so VoiceOver speaks none
    /// either: the line is Food alone when Health gave no burned reading.
    func testSpokenSummaryWithTheGoalOffAndAKnownFoodSpeaksNoRemaining() throws {
        let calories = CalorieRemaining.make(
            goal: nil, food: 500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy")
        let spoken = NourishTodayHeader.spokenSummary(calories, partial: calories.partialNote, footnote: nil)
        XCTAssertEqual(spoken, "Food, \(BodyActivityViewModel.whole(500)) calories")
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("remaining"))
    }

    /// A partial day with no missing entry (a below-threshold amount) still speaks the fallback note.
    func testSpokenSummaryKeepsTheFallbackNoteForABelowThresholdDay() throws {
        let calories = CalorieRemaining.make(
            goal: 2000, food: 500, partial: true, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: calories.partialNote, footnote: nil),
            "\(BodyActivityViewModel.whole(1500)) calories remaining, "
                + "Food, \(BodyActivityViewModel.whole(500)) calories, "
                + "Some entries can't be added up for energy")
    }

    /// The goal footnote is read only while Remaining shows: a day without a goal has no Remaining for it to qualify.
    func testTheSummaryFootnoteIsReadOnlyWhileRemainingShows() throws {
        let withGoal = CalorieRemaining.make(
            goal: 2000, food: 500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy")
        let withoutGoal = CalorieRemaining.make(
            goal: nil, food: 500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertTrue(withGoal.showsRemaining)
        XCTAssertFalse(withoutGoal.showsRemaining)
        XCTAssertEqual(
            NourishTodayHeader.summaryFootnote(withGoal, ringFootnote: "of 2,000 Calories goal"),
            "of 2,000 Calories goal")
        XCTAssertNil(NourishTodayHeader.summaryFootnote(withoutGoal, ringFootnote: "of 2,000 Calories goal"))
    }
}
