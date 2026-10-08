import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The goal bar's states as a model: what the figure reads, whether there is a fraction to draw, and
/// what a screen reader is told. The view only renders these.
final class GoalBarTests: XCTestCase {
    private func line(
        _ nutrient: String, _ amount: NutrientValue, goal: NutrientGoal? = nil
    ) -> NutrientProgressLine {
        NutrientProgressLine(nutrient: nutrient, amount: amount, goal: goal)
    }

    private func goal(_ nutrient: String, _ target: Decimal, _ unit: MeasureUnit) -> NutrientGoal {
        NutrientGoal(nutrient: nutrient, target: target, unit: unit)
    }

    func testGoalBarProgressStateDrawsTheFractionOfTheTarget() {
        let model = GoalBarModel.make(
            line: line("protein", .known(Decimal(30), .g), goal: goal("protein", Decimal(60), .g)),
            hasEntries: true, missingCount: 0)
        XCTAssertEqual(model.state, .progress)
        XCTAssertEqual(model.valueText, "30 g of 60 g")
        XCTAssertEqual(model.fraction, Decimal(string: "0.5"))
        XCTAssertNil(model.goalMarker)
        XCTAssertNil(model.reason)
        XCTAssertEqual(model.accessibilityText, "Protein, 30 grams of 60 grams")
    }

    func testGoalBarOverGoalKeepsTheRealFigureAndCapsTheFractionAtOne() {
        let model = GoalBarModel.make(
            line: line("carbohydrate", .known(Decimal(262), .g), goal: goal("carbohydrate", Decimal(230), .g)),
            hasEntries: true, missingCount: 0)
        XCTAssertEqual(model.state, .overGoal)
        XCTAssertEqual(model.valueText, "262 g of 230 g")
        XCTAssertEqual(model.fraction, Decimal(1))
        XCTAssertNotNil(model.goalMarker)
        XCTAssertGreaterThan(model.goalMarker ?? Decimal(0), Decimal(0))
        XCTAssertLessThan(model.goalMarker ?? Decimal(1), Decimal(1))
        XCTAssertEqual(model.accessibilityText, "Carbohydrate, 262 grams of 230 grams, over goal")
    }

    func testGoalBarNoGoalStateIsTheValueAloneWithoutAFraction() {
        let model = GoalBarModel.make(
            line: line("sodium", .known(Decimal(1150), .mg)), hasEntries: true, missingCount: 0)
        XCTAssertEqual(model.state, .noGoal)
        XCTAssertEqual(model.valueText, "1150 mg")
        XCTAssertNil(model.fraction)
        XCTAssertEqual(model.accessibilityText, "Sodium, 1150 milligrams")
    }

    func testGoalBarCannotTotalNeverYieldsAFractionAndNamesTheMissingEntries() {
        let one = GoalBarModel.make(
            line: line("fiber", .unknown, goal: goal("fiber", Decimal(30), .g)),
            hasEntries: true, missingCount: 1)
        XCTAssertEqual(one.state, .cannotTotal)
        XCTAssertEqual(one.valueText, "Can't total yet")
        XCTAssertNil(one.fraction)
        XCTAssertNil(one.goalMarker)
        XCTAssertEqual(one.reason, "1 entry has no fiber value")
        XCTAssertEqual(one.accessibilityText, "Fiber, can't total yet, 1 entry has no fiber value")
        let two = GoalBarModel.make(
            line: line("fiber", .unknown), hasEntries: true, missingCount: 2)
        XCTAssertEqual(two.reason, "2 entries have no fiber value")
    }

    func testGoalBarCannotTotalWithNoReportedGapUsesTheGenericReason() {
        let model = GoalBarModel.make(
            line: line("zinc", .belowReportingThreshold(.mg)), hasEntries: true, missingCount: 0)
        XCTAssertEqual(model.state, .cannotTotal)
        XCTAssertEqual(model.reason, "Some entries can't be added up for zinc")
    }

    func testGoalBarCannotTotalForWaterUsesTheSkippedEntrySentence() {
        let model = GoalBarModel.make(
            line: line("water", .unknown), hasEntries: true, missingCount: 0, skippedWaterCount: 2)
        XCTAssertEqual(model.state, .cannotTotal)
        XCTAssertEqual(
            model.reason, "2 water entries have a unit that is not a volume and are not counted.")
    }

    func testGoalBarNothingLoggedDiffersFromAKnownZero() {
        let goalled = goal("protein", Decimal(60), .g)
        let nothing = GoalBarModel.make(
            line: line("protein", .unknown, goal: goalled), hasEntries: false, missingCount: 0)
        XCTAssertEqual(nothing.state, .nothingLogged)
        XCTAssertEqual(nothing.valueText, "Nothing logged yet")
        XCTAssertNil(nothing.fraction)
        XCTAssertEqual(nothing.accessibilityText, "Protein, nothing logged yet, goal 60 grams")
        let zero = GoalBarModel.make(
            line: line("protein", .known(Decimal(0), .g), goal: goalled), hasEntries: true, missingCount: 0)
        XCTAssertEqual(zero.state, .progress)
        XCTAssertEqual(zero.valueText, "0 g of 60 g")
        XCTAssertEqual(zero.fraction, Decimal(0))
        XCTAssertNotEqual(nothing, zero)
    }

    func testGoalBarComparesATargetInAnotherUnitInTheTotalsUnit() {
        let model = GoalBarModel.make(
            line: line("sodium", .known(Decimal(1000), .mg), goal: goal("sodium", Decimal(2), .g)),
            hasEntries: true, missingCount: 0)
        XCTAssertEqual(model.state, .progress)
        XCTAssertEqual(model.valueText, "1000 mg of 2 g")
        XCTAssertEqual(model.fraction, Decimal(string: "0.5"))
    }

    func testGoalBarKeepsTheLineTextModelUntouched() {
        let source = line("protein", .known(Decimal(42), .g), goal: goal("protein", Decimal(60), .g))
        _ = GoalBarModel.make(line: source, hasEntries: true, missingCount: 0)
        XCTAssertEqual(source.text, "Protein 42 g of 60 g")
        XCTAssertEqual(line("zinc", .unknown).text, "Zinc unknown")
    }

    func testKindTagMarksSupplementsAndDrinksButNotFood() {
        XCTAssertNil(KindTag.title(for: .food))
        XCTAssertEqual(KindTag.title(for: .supplement), "Supplement")
        XCTAssertEqual(KindTag.title(for: .drink), "Drink")
    }
}
