import XCTest
@testable import NutritionDomain

/// The percent split's arithmetic, each figure worked out by hand in its test: grams are the energy
/// goal times the share, divided by 4 kcal per gram for protein and carbohydrate and 9 for fat.
final class MacroSplitTests: XCTestCase {
    func testAThirtyFortyThirtySplitOfTwoThousandKcal() throws {
        let split = try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30)
        // 600 / 4 = 150, 800 / 4 = 200, 600 / 9 = 66.67 -> 67
        XCTAssertEqual(
            try split.grams(forEnergyKcal: 2000), MacroSplit.Grams(protein: 150, carbohydrate: 200, fat: 67))
    }

    func testAnAwkwardEnergyGoalRoundsEachMacroToWholeGrams() throws {
        let split = try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30)
        // 645 / 4 = 161.25 -> 161, 860 / 4 = 215, 645 / 9 = 71.67 -> 72
        XCTAssertEqual(
            try split.grams(forEnergyKcal: 2150), MacroSplit.Grams(protein: 161, carbohydrate: 215, fat: 72))
    }

    func testSharesThatDoNotTotalHundredAreRefusedWithTheirTotal() {
        XCTAssertThrowsError(try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 20)) {
            XCTAssertEqual($0 as? MacroSplit.SplitError, .doesNotTotalHundred(total: 90))
        }
        XCTAssertThrowsError(try MacroSplit(proteinPercent: 40, carbohydratePercent: 40, fatPercent: 30)) {
            XCTAssertEqual($0 as? MacroSplit.SplitError, .doesNotTotalHundred(total: 110))
        }
    }

    func testAZeroOrNegativeShareIsRefused() {
        XCTAssertThrowsError(try MacroSplit(proteinPercent: 0, carbohydratePercent: 60, fatPercent: 40)) {
            XCTAssertEqual($0 as? MacroSplit.SplitError, .shareNotPositive)
        }
        XCTAssertThrowsError(try MacroSplit(proteinPercent: -10, carbohydratePercent: 70, fatPercent: 40)) {
            XCTAssertEqual($0 as? MacroSplit.SplitError, .shareNotPositive)
        }
    }

    func testAnEnergyGoalOfZeroIsRefused() throws {
        let split = try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30)
        XCTAssertThrowsError(try split.grams(forEnergyKcal: 0)) {
            XCTAssertEqual($0 as? MacroSplit.SplitError, .energyNotPositive)
        }
    }

    func testAShareThatRoundsToNoGramsIsRefused() throws {
        let split = try MacroSplit(proteinPercent: 1, carbohydratePercent: 98, fatPercent: 1)
        // 1% of 100 kcal is 1 kcal: 0.25 g of protein and 0.11 g of fat, both 0 g when rounded.
        XCTAssertThrowsError(try split.grams(forEnergyKcal: 100)) {
            XCTAssertEqual($0 as? MacroSplit.SplitError, .roundsToNothing)
        }
    }

    func testGramGoalsReadBackAsWholePercentsOfTheEnergyGoal() throws {
        // 150 * 4 = 600 -> 30%, 200 * 4 = 800 -> 40%, 67 * 9 = 603 -> 30.15% -> 30
        let percents = try XCTUnwrap(
            MacroSplit.percents(
                ofEnergyKcal: 2000, grams: MacroSplit.Grams(protein: 150, carbohydrate: 200, fat: 67)))
        XCTAssertEqual(percents, MacroSplit.Grams(protein: 30, carbohydrate: 40, fat: 30))
        XCTAssertNil(
            MacroSplit.percents(ofEnergyKcal: 0, grams: MacroSplit.Grams(protein: 1, carbohydrate: 1, fat: 1)))
    }

    func testRoundingAloneNeverLeavesTheShownPercentsShortOfHundred() throws {
        // 102 * 4 = 408 -> 20.4%, 252 * 4 = 1008 -> 50.4%, 65 * 9 = 585 -> 29.25%. Plain rounding shows
        // 20, 50, 29 (99). The exact shares total 100.05, so the missing point goes to the largest remainder,
        // the tied 0.4s going to the earlier share.
        let percents = try XCTUnwrap(
            MacroSplit.percents(
                ofEnergyKcal: 2000, grams: MacroSplit.Grams(protein: 102, carbohydrate: 252, fat: 65)))
        XCTAssertEqual(percents, MacroSplit.Grams(protein: 21, carbohydrate: 50, fat: 29))
        XCTAssertEqual(percents.protein + percents.carbohydrate + percents.fat, 100)
    }

    func testSharesThatAreFarFromHundredKeepTheirPlainRounding() throws {
        // 100 * 4 = 400 -> 20%, 100 * 4 = 400 -> 20%, 100 * 9 = 900 -> 45%: a total of 85 is not rounding.
        let percents = try XCTUnwrap(
            MacroSplit.percents(
                ofEnergyKcal: 2000, grams: MacroSplit.Grams(protein: 100, carbohydrate: 100, fat: 100)))
        XCTAssertEqual(percents, MacroSplit.Grams(protein: 20, carbohydrate: 20, fat: 45))
    }
}
