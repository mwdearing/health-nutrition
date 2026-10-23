import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

/// A drink logged in fluid ounces against a label that states its serving in milliliters is scaled by a
/// factor with no finite decimal form: 24 fl oz is 709.7647095 mL, and 709.7647095 / 710 runs to every
/// digit a `Decimal` holds. The day's totals keep those digits, as they should; every screen that shows
/// one of them shows it rounded, at the precision the vitamins and minerals screen uses for a nutrient,
/// and energy in whole kilocalories.
@MainActor
final class ScaledAmountDisplayTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// A drink whose label states its values for a 710 mL bottle.
    private func bottle() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-bottle", productID: "product-bottle", name: "Electrolyte drink",
            labelBasis: "per serving (710 mL)", catalogOrigin: "test", catalogVersion: "1",
            nutrients: [
                "energy": .known(Decimal(10), .kcal),
                "carbohydrate": .known(Decimal(1), .g),
                "sodium": .known(Decimal(30), .mg),
            ])
    }

    /// 24 fl oz, stored the way the Add screen stores it: as the milliliters it stands for.
    private func twentyFourFluidOunces() -> [IntakeComponent] {
        let stored = AddIntakeViewModel.storedMetric(amount: 24, unit: .flOz)
        return [IntakeComponent(
            componentID: "electrolyte-drink", name: "Electrolyte drink", amount: stored.amount, unit: stored.unit)]
    }

    private func dayTotals() throws -> DailyTotals {
        let store = try makeStore()
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: when, timeZoneIdentifier: "UTC")
        try store.create(intake, components: twentyFourFluidOunces(), product: bottle(), now: when)
        return try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotNutrientFacts(),
            nutrients: ["energy", "carbohydrate", "sodium"])
    }

    private func amount(_ totals: DailyTotals, _ nutrient: String) throws -> Decimal {
        guard case .known(let amount, _) = try XCTUnwrap(totals.total(for: nutrient)).value else {
            XCTFail("\(nutrient) has no known total")
            return 0
        }
        return amount
    }

    private func line(_ totals: DailyTotals, _ nutrient: String, goal: Decimal? = nil, unit: MeasureUnit = .g)
        -> NutrientProgressLine
    {
        NutrientProgressLine.make(
            nutrient: nutrient, total: totals.total(for: nutrient),
            goal: goal.map { NutrientGoal(nutrient: nutrient, target: $0, unit: unit) })
    }

    // MARK: The reported shape

    /// The total itself keeps the long quotient: this is what reached the screen unrounded.
    func testTheDayTotalCarriesMoreDigitsThanAnyScreenShows() throws {
        let totals = try dayTotals()
        let carbohydrate = try amount(totals, "carbohydrate")
        XCTAssertNotEqual(DisplayRounding.rounded(carbohydrate, fractionDigits: 10), carbohydrate)
        XCTAssertNotEqual(DisplayRounding.rounded(try amount(totals, "sodium"), fractionDigits: 10),
                          try amount(totals, "sodium"))
    }

    // MARK: Today

    /// The goal bars under the macros: a bar with a goal and one without, read and spoken.
    func testGoalBarsShowTheScaledTotalRounded() throws {
        let totals = try dayTotals()
        for system in [UnitSystem.metric, .usCustomary] {
            let sodium = GoalBarModel.make(
                line: line(totals, "sodium"), hasEntries: true, missingCount: 0, unitSystem: system)
            XCTAssertEqual(sodium.valueText, "30 mg")
            XCTAssertEqual(sodium.state, .noGoal)
            XCTAssertEqual(sodium.accessibilityText, "Sodium, 30 milligrams")

            let carbohydrate = GoalBarModel.make(
                line: line(totals, "carbohydrate", goal: 250), hasEntries: true, missingCount: 0, unitSystem: system)
            XCTAssertEqual(carbohydrate.valueText, "1 g of 250 g")
            XCTAssertEqual(carbohydrate.accessibilityText, "Carbohydrate, 1 grams of 250 grams")

            let energy = GoalBarModel.make(
                line: line(totals, "energy", goal: 2000, unit: .kcal), hasEntries: true, missingCount: 0,
                unitSystem: system)
            XCTAssertEqual(energy.valueText, "10 Calories of 2,000 Calories")
        }
    }

    /// The bar is still drawn from the exact total: rounding is for the words only.
    func testTheBarFractionStaysExact() throws {
        let totals = try dayTotals()
        let carbohydrate = GoalBarModel.make(
            line: line(totals, "carbohydrate", goal: 250), hasEntries: true, missingCount: 0)
        XCTAssertEqual(carbohydrate.fraction, try amount(totals, "carbohydrate") / 250)
    }

    /// The calorie ring and the three macro columns at the top of Today.
    func testTodayHeaderFiguresAreRounded() throws {
        let totals = try dayTotals()
        XCTAssertEqual(NourishTodayHeader.figure(for: line(totals, "carbohydrate")), "1 g")
        XCTAssertEqual(NourishTodayHeader.figure(for: line(totals, "energy")), "10 Calories")
        XCTAssertEqual(NourishTodayHeader.figure(for: nil), "—")
        XCTAssertEqual(
            NourishTodayHeader.ringFootnote(for: NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)),
            "of 2,000 Calories goal")
    }

    // MARK: Journal

    /// The day summary line and the day's energy in the Journal.
    func testJournalDayLinesAreRounded() throws {
        let totals = try dayTotals()
        XCTAssertEqual(line(totals, "carbohydrate", goal: 250).text, "Carbohydrate 1 g of 250 g")
        XCTAssertEqual(line(totals, "sodium").text, "Sodium 30 mg")
        XCTAssertEqual(JournalViewModel.energyText(totals: totals), "10 Calories")
    }

    // MARK: A scaled label value

    /// "This adds" while logging and the entry's adds afterwards scale the label value by the same factor.
    func testScaledLabelValuesAreRounded() throws {
        let components = twentyFourFluidOunces()
        let factor = try XCTUnwrap(
            DailyTotalsBuilder.scalingFactor(labelBasis: bottle().labelBasis, logged: components))
        let line = ThisAddsLine(
            key: "sodium", displayName: "Sodium", value: NutrientValue.known(30, .mg).scaled(by: factor),
            cannotScale: false)
        XCTAssertEqual(line.text, "30 mg")

        // What an entry adds reads as Today will total it, even where the amount logged is the label's own
        // basis: the label's own figure stays exact under All values.
        let wholeBasis = ThisAddsLine(
            key: "protein", displayName: "Protein", value: NutrientValue.known(Decimal(string: "1.25")!, .g)
                .scaled(by: 1),
            cannotScale: false)
        XCTAssertEqual(wholeBasis.text, "1.3 g")
        XCTAssertEqual(LookedUpProduct.shownText(.known(Decimal(string: "1.25")!, .g)), "1.25 g")

        let adds = EntryDetailViewModel.adds(of: bottle(), logged: components)
        XCTAssertEqual(adds.first { $0.key == "sodium" }?.amountText, "30 mg")
        XCTAssertEqual(adds.first { $0.key == LookedUpProduct.energyKcal }?.amountText, "10 Calories")
    }

    /// A quick add edited to a third of its serving says so in its row title without the long quotient,
    /// while a whole number of servings still reads exactly as typed.
    func testQuickAddRowTitleRoundsAPartServing() {
        let product = ProductDefinition(
            snapshotID: "quick-x", productID: "quick-x", name: "Quick add", labelBasis: "per serving",
            catalogOrigin: "quick_add", catalogVersion: "1",
            nutrients: ["energyKcal": .known(250, .kcal), "protein": .known(10, .g)])
        let third = [IntakeComponent(
            componentID: "quick-add", name: "Quick add", amount: Decimal(1) / Decimal(3), unit: .serving)]
        XCTAssertEqual(
            QuickAddViewModel.rowTitle(components: third, product: product),
            "\(AmountText.title(third)) · 83 Calories, 3.3 g protein")
        let one = [IntakeComponent(componentID: "quick-add", name: "Quick add", amount: 1, unit: .serving)]
        XCTAssertEqual(
            QuickAddViewModel.rowTitle(components: one, product: product),
            "\(AmountText.title(one)) · 250 Calories, 10 g protein")
    }

    // MARK: The rule

    /// An amount too small for two fraction digits still reads as something, never as a zero, in words
    /// and to a screen reader.
    func testATinyAmountReadsAsLessThanTheSmallestFigure() {
        let tiny = AmountDisplay.nutrient(Decimal(string: "0.004")!, unit: .mg)
        XCTAssertEqual(tiny.text, "< 0.01 mg")
        XCTAssertEqual(tiny.spokenAmount, "less than 0.01")
        XCTAssertEqual(AmountDisplay.nutrient(Decimal(string: "0.4")!, unit: .kcal).text, "< 1 Calories")
        XCTAssertEqual(AmountDisplay.nutrient(0, unit: .mg).text, "0 mg")
    }

    /// Today and the vitamins and minerals screen read the same nutrient the same way.
    func testNutrientFiguresMatchTheVitaminsAndMineralsScreen() {
        let amounts = ["0.004", "0.125", "0.99966860492957746478873239436619718309", "1.25", "2.04",
                       "29.9900581478873239436619718309859154927", "1234.56"].map { Decimal(string: $0)! }
        for amount in amounts {
            for unit in [MeasureUnit.g, .mg, .mcg] {
                XCTAssertEqual(
                    AmountDisplay.nutrient(amount, unit: unit).text, NutrientGapRow.figure(amount, unit),
                    "\(amount) \(unit.symbol)")
            }
        }
    }
}
