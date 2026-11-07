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
}
