import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The goal bar's states as a model: what the figure reads, whether there is a fraction to draw, and
/// what a screen reader is told. The view only renders these.
@MainActor
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
        XCTAssertEqual(model.valueText, "1,150 mg")
        XCTAssertNil(model.fraction)
        XCTAssertEqual(model.accessibilityText, "Sodium, 1,150 milligrams")
    }

    func testNoGoalBarStillDrawsAnEmptyTrackSoItLinesUpWithGoalRows() {
        let noGoal = GoalBarModel.make(
            line: line("sodium", .known(Decimal(1150), .mg)), hasEntries: true, missingCount: 0)
        XCTAssertEqual(noGoal.state, .noGoal)
        XCTAssertNil(noGoal.fraction)
        XCTAssertTrue(noGoal.showsTrack, "a no-goal bar keeps its empty track")
    }

    func testGoalBarCannotTotalNeverYieldsAFractionAndNamesTheMissingEntries() {
        let one = GoalBarModel.make(
            line: line("fiber", .unknown, goal: goal("fiber", Decimal(30), .g)),
            hasEntries: true, missingCount: 1)
        XCTAssertEqual(one.state, .cannotTotal)
        XCTAssertEqual(one.valueText, "No data")
        XCTAssertNil(one.fraction)
        XCTAssertNil(one.goalMarker)
        XCTAssertEqual(one.reason, "1 entry has no fiber value")
        XCTAssertEqual(one.accessibilityText, "Fiber, no data, 1 entry has no fiber value")
        let partly = GoalBarModel.make(
            line: line("fiber", .unknown, goal: goal("fiber", Decimal(30), .g)),
            hasEntries: true, missingCount: 1, someKnown: true)
        XCTAssertEqual(partly.state, .cannotTotal)
        XCTAssertEqual(partly.valueText, "Can't total yet", "some entries known: not No data")
        XCTAssertEqual(partly.reason, "1 entry has no fiber value")
        XCTAssertNil(partly.fraction)
        XCTAssertEqual(partly.accessibilityText, "Fiber, 1 entry has no fiber value")
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
        XCTAssertEqual(model.valueText, "1,000 mg of 2 g")
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

    func testPartialKnownSumShowsTheSumWithTheMissingValueNote() {
        let partial = NutrientProgressLine(
            nutrient: "fiber", amount: .known(Decimal(5), .g), goal: nil, isPartial: true)
        let bar = GoalBarModel.make(line: partial, hasEntries: true, missingCount: 1)
        XCTAssertEqual(bar.state, .noGoal)
        XCTAssertEqual(bar.valueText, "5 g")
        XCTAssertEqual(bar.reason, "1 entry has no fiber value")
    }

    func testPartialGoalBarSpeaksThePartialNote() {
        let partial = NutrientProgressLine(
            nutrient: "fiber", amount: .unknown, goal: goal("fiber", Decimal(30), .g), isPartial: true,
            knownSum: .known(Decimal(10), .g))
        let bar = GoalBarModel.make(line: partial, hasEntries: true, missingCount: 1)
        XCTAssertEqual(bar.state, .progress)
        XCTAssertEqual(bar.accessibilityText, "Fiber, 10 grams of 30 grams, 1 entry has no fiber value")
    }

    func testDiaryPartialDayNotesTheCountFromTheSameTotal() {
        let total = NutrientTotal(
            value: .unknown,
            coverage: Coverage(knownCount: 1, totalCount: 2, hasBelowReportingThreshold: false, hasUnknown: true))
        let totals = DailyTotals(
            totals: ["protein": total], knownSums: ["protein": .known(Decimal(12), .g)],
            missingCounts: ["protein": 1])
        let bars = JournalViewModel.headerBars(
            totals: totals, goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)],
            hasFoodEntries: true, unitSystem: .metric)
        XCTAssertEqual(bars.first?.reason, "1 entry has no protein value")
        XCTAssertEqual(bars.first?.state, .progress)
    }

    func testPartialSumLeavesBelowThresholdOutAndKeepsTheKnownPart() {
        let values: [NutrientValue] = [.known(Decimal(5), .g), .belowReportingThreshold(nil)]
        XCTAssertEqual(DailyTotalsBuilder.partialKnownSum(values, nutrient: "fiber"), .known(Decimal(5), .g))
        let total = NutrientTotal(
            value: .unknown,
            coverage: Coverage(knownCount: 1, totalCount: 2, hasBelowReportingThreshold: true, hasUnknown: false))
        let line = NutrientProgressLine.make(
            nutrient: "fiber", total: total, goal: nil, knownSum: .known(Decimal(5), .g))
        XCTAssertTrue(line.isPartial, "a bound makes the day partial, not whole")
        XCTAssertEqual(line.shownAmount, .known(Decimal(5), .g))
    }

    func testPartialSumStaysUnknownWhenNothingIsKnownOrBounded() {
        XCTAssertNil(DailyTotalsBuilder.partialKnownSum([.unknown, .unknown], nutrient: "fiber"))
    }

    func testPartialSumIsZeroWhenEveryEntryIsBelowThreshold() {
        XCTAssertEqual(
            DailyTotalsBuilder.partialKnownSum([.belowReportingThreshold(.g), .belowReportingThreshold(.g)], nutrient: "fiber"),
            .known(Decimal(0), .g))
    }

    func testBelowThresholdOnlyDayShowsZeroWithTheNote() {
        let bounded = NutrientProgressLine.make(
            nutrient: "fiber",
            total: NutrientTotal(
                value: .unknown,
                coverage: Coverage(knownCount: 0, totalCount: 2, hasBelowReportingThreshold: true, hasUnknown: false)),
            goal: nil, knownSum: .known(Decimal(0), .g))
        let bar = GoalBarModel.make(line: bounded, hasEntries: true, missingCount: 0)
        XCTAssertEqual(bar.valueText, "0 g")
        XCTAssertEqual(bar.reason, "Some entries can't be added up for fiber")
    }
}
