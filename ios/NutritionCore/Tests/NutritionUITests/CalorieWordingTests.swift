import Foundation
import NutritionDomain
import XCTest
@testable import NutritionUI

/// Calories is a label or heading with a capital C. Inside a phrase the word is lowercase, with the
/// singular for exactly one (approved wording, #516).
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

    private func totals(kcal: Decimal) -> DailyTotals {
        let total = NutrientTotal(
            value: .known(kcal, .kcal),
            coverage: Coverage(knownCount: 1, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: false))
        return DailyTotals(totals: ["energy": total])
    }
}
