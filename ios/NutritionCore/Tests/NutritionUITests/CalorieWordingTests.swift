import Foundation
import NutritionDomain
import XCTest
@testable import NutritionUI

/// Calories is a label or heading with a capital C. Inside a phrase the word is lowercase, with the
/// singular for exactly one (approved wording, #516).
@MainActor
final class CalorieWordingTests: XCTestCase {
    func testADiaryDayTotalReadsInLowercaseWithItsCount() {
        XCTAssertEqual(JournalViewModel.energyText(totals: totals(kcal: 400)), "400 calories")
        XCTAssertEqual(JournalViewModel.energyText(totals: totals(kcal: 1)), "1 calorie")
        XCTAssertEqual(JournalViewModel.energyText(totals: totals(kcal: Decimal(string: "0.4")!)), "less than 1 calorie")
    }

    func testASectionCaptionReadsInLowercaseWithItsCount() {
        XCTAssertEqual(energyCaption(250), "250 calories")
        XCTAssertEqual(energyCaption(1), "1 calorie")
    }

    func testAnActiveEnergyOfOneCalorieIsSingular() {
        XCTAssertEqual(BodyActivityViewModel.calorieWord("1"), "calorie")
        XCTAssertEqual(BodyActivityViewModel.calorieWord("250"), "calories")
    }

    func testAZeroEnergyGoalIsNoGoal() {
        XCTAssertNil(TodayViewModel.energyGoal(nil))
        XCTAssertNil(TodayViewModel.energyGoal(0))
        XCTAssertNil(TodayViewModel.energyGoal(-5))
        XCTAssertEqual(TodayViewModel.energyGoal(2000), 2000)
    }

    private func totals(kcal: Decimal) -> DailyTotals {
        let total = NutrientTotal(
            value: .known(kcal, .kcal),
            coverage: Coverage(knownCount: 1, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: false))
        return DailyTotals(totals: ["energy": total])
    }

    /// A partial day reads its known sum as "at least", the same copy the energy goal bar uses (#1407).
    func testAPartialDayEnergyReadsAtLeast() {
        // One known entry of 400 calories and one entry with no energy: a partial day.
        let total = NutrientTotal(
            value: .unknown,
            coverage: Coverage(knownCount: 1, totalCount: 2, hasBelowReportingThreshold: false, hasUnknown: true))
        let partial = DailyTotals(
            totals: ["energy": total], knownSums: ["energy": .known(Decimal(400), .kcal)],
            missingCounts: ["energy": 1])
        XCTAssertEqual(JournalViewModel.energyText(totals: partial), "at least 400 calories")
    }

    /// A partial day under 1 calorie keeps its partial marker and never reads as a complete "less than 1" (#1407 review P2).
    func testAPartialDayUnderOneCalorieReadsSoFar() {
        let total = NutrientTotal(
            value: .unknown,
            coverage: Coverage(knownCount: 1, totalCount: 2, hasBelowReportingThreshold: false, hasUnknown: true))
        let partial = DailyTotals(
            totals: ["energy": total], knownSums: ["energy": .known(Decimal(string: "0.4")!, .kcal)],
            missingCounts: ["energy": 1])
        XCTAssertEqual(JournalViewModel.energyText(totals: partial), "less than 1 calorie so far")
    }
}
