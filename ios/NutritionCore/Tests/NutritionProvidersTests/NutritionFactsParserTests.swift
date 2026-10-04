import Foundation
import NutritionDomain
import XCTest
@testable import NutritionProviders

/// The panels below are synthetic. No real product and no real brand is named anywhere in this file.
final class NutritionFactsParserTests: XCTestCase {
    private func dec(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private func parse(_ lines: [String]) -> ParsedNutritionFacts {
        NutritionFactsParser.parse(lines: lines)
    }

    private func value(_ key: NutritionFactKey, _ panel: ParsedNutritionFacts) -> NutrientValue {
        panel.value(for: key)
    }

    private func amount(_ key: NutritionFactKey, _ panel: ParsedNutritionFacts) throws -> Decimal {
        guard case .known(let amount, _) = panel.value(for: key) else {
            XCTFail("expected \(key.rawValue) to be a known amount")
            return Decimal(0)
        }
        return amount
    }

    private func unit(_ key: NutritionFactKey, _ panel: ParsedNutritionFacts) throws -> MeasureUnit {
        guard case .known(_, let unit) = panel.value(for: key) else {
            XCTFail("expected \(key.rawValue) to carry a unit")
            return .g
        }
        return unit
    }

    /// A complete panel as OCR would hand it over: one row per line, the % Daily Value column
    /// separated by two spaces, a synthetic product invented for these tests.
    private var fullPanel: [String] {
        [
            "Nutrition Facts",
            "Synthetic Cereal, invented for tests",
            "8 servings per container",
            "Serving size 3/4 cup (55g)",
            "Amount per serving",
            "Calories 250",
            "% Daily Value*",
            "Total Fat 7g 9%",
            "  Saturated Fat 3g 15%",
            "  Trans Fat 0g",
            "Cholesterol 0mg 0%",
            "Sodium 180mg 8%",
            "Total Carbohydrate 37g 13%",
            "  Dietary Fiber 4g 14%",
            "  Total Sugars 12g",
            "    Includes 5g Added Sugars",
            "Protein 6g 12%",
            "Vitamin D 2mcg 10%",
            "Calcium 120mg 10%",
            "Iron 1.8mg 10%",
            "Potassium 350mg 8%",
            "* The % Daily Value tells you how much a nutrient contributes to a daily diet.",
        ]
    }

    func testFullSyntheticPanelIsParsed() throws {
        let panel = parse(fullPanel)

        XCTAssertEqual(panel.servingSize?.text, "3/4 cup (55g)")
        XCTAssertEqual(panel.servingSize?.quantity, Quantity(value: dec("55"), unit: .g))
        XCTAssertEqual(panel.servingsPerContainer, dec("8"))

        XCTAssertEqual(value(.calories, panel), .known(dec("250"), .kcal))
        XCTAssertEqual(value(.fat, panel), .known(dec("7"), .g))
        XCTAssertEqual(value(.saturatedFat, panel), .known(dec("3"), .g))
        XCTAssertEqual(value(.transFat, panel), .known(dec("0"), .g))
        XCTAssertEqual(value(.cholesterol, panel), .known(dec("0"), .mg))
        XCTAssertEqual(value(.sodium, panel), .known(dec("180"), .mg))
        XCTAssertEqual(value(.carbohydrates, panel), .known(dec("37"), .g))
        XCTAssertEqual(value(.fiber, panel), .known(dec("4"), .g))
        XCTAssertEqual(value(.sugars, panel), .known(dec("12"), .g))
        XCTAssertEqual(value(.addedSugars, panel), .known(dec("5"), .g))
        XCTAssertEqual(value(.protein, panel), .known(dec("6"), .g))
        XCTAssertEqual(value(.vitaminD, panel), .known(dec("2"), .mcg))
        XCTAssertEqual(value(.calcium, panel), .known(dec("120"), .mg))
        XCTAssertEqual(value(.iron, panel), .known(dec("1.8"), .mg))
        XCTAssertEqual(value(.potassium, panel), .known(dec("350"), .mg))
        XCTAssertTrue(panel.reviewKeys.isEmpty, "a clean panel needs no review")
    }

    func testEveryJournalKeyIsAlwaysPresent() throws {
        let panel = parse(fullPanel)

        XCTAssertEqual(Set(panel.nutrients.keys), Set(NutritionFactKey.allCases.map(\.rawValue)))
        XCTAssertEqual(NutritionFactKey.allCases.count, 15)
    }

    func testLetterOIsReadAsZeroAndFlaggedForReview() throws {
        let panel = parse([
            "Nutrition Facts",
            "Sodium 1O mg 4%",
            "Total Fat Og",
            "Vitamin D 3mcg 15%",
        ])

        XCTAssertEqual(try amount(.sodium, panel), dec("10"))
        XCTAssertEqual(try unit(.sodium, panel), .mg)
        XCTAssertTrue(panel.needsReview(.sodium), "a corrected letter O is low confidence")
        XCTAssertEqual(panel.valuesNeedingReview[.sodium.rawValue]?.reasons, [.correctedLetterO])

        XCTAssertEqual(try amount(.fat, panel), dec("0"))
        XCTAssertTrue(panel.needsReview(.fat))
        XCTAssertFalse(panel.needsReview(.vitaminD), "an untouched row is not low confidence")
    }

    func testUnitSpacingVariantsAndMicrogramSymbols() throws {
        let tight = parse([
            "Sodium 140mg",
            "Total Fat 12g",
            "Vitamin D 2mcg",
        ])
        XCTAssertEqual(try amount(.sodium, tight), dec("140"))
        XCTAssertEqual(try unit(.sodium, tight), .mg)
        XCTAssertEqual(try amount(.fat, tight), dec("12"))
        XCTAssertEqual(try unit(.fat, tight), .g)
        XCTAssertEqual(try unit(.vitaminD, tight), .mcg)

        let spaced = parse([
            "Total Fat 12 g",
            "Calcium 30 mg",
        ])
        XCTAssertEqual(try amount(.fat, spaced), dec("12"))
        XCTAssertEqual(try unit(.fat, spaced), .g)
        XCTAssertEqual(try amount(.calcium, spaced), dec("30"))
        XCTAssertEqual(try unit(.calcium, spaced), .mg)

        let microSign = parse(["Calcium 45 \u{00B5}g"])
        XCTAssertEqual(try amount(.calcium, microSign), dec("45"))
        XCTAssertEqual(try unit(.calcium, microSign), .mcg)
        XCTAssertTrue(microSign.needsReview(.calcium), "a normalised microgram symbol is low confidence")

        let greekMu = parse(["Vitamin D 1.5 \u{03BC}g"])
        XCTAssertEqual(try unit(.vitaminD, greekMu), .mcg)
        XCTAssertTrue(greekMu.needsReview(.vitaminD))
    }

    func testARowThatLostItsUnitStaysUnknown() {
        // A bare number on a row that prints no unit of its own is a number the parser will not put a
        // unit on: only the Calories row carries its unit in the panel header.
        let panel = parse(["Sodium 140", "Fat 7"])

        XCTAssertEqual(value(.sodium, panel), .unknown)
        XCTAssertEqual(value(.fat, panel), .unknown)
        XCTAssertEqual(parse(["Calories 250"]).value(for: .calories), .known(dec("250"), .kcal))
    }

    func testMissingNutrientIsUnknownAndNeverZero() {
        let panel = parse([
            "Nutrition Facts",
            "Serving size 1 cup (240mL)",
            "Calories 180",
            "Total Fat 4g",
        ])

        XCTAssertEqual(value(.potassium, panel), .unknown)
        XCTAssertEqual(value(.transFat, panel), .unknown)
        XCTAssertEqual(value(.addedSugars, panel), .unknown)
        // A row the panel does not state is unknown, which is not the same amount as a stated zero.
        XCTAssertNotEqual(value(.potassium, panel), NutrientValue.known(Decimal(0), .mg))
        XCTAssertNotEqual(value(.potassium, panel), NutrientValue.known(Decimal(0), .g))
        XCTAssertNil(panel.value(for: .potassium).quantity)
    }

    func testPercentDailyValueColumnIsNeverTakenAsAnAmount() throws {
        let panel = parse([
            "Total Fat 12g 21%",
            "Sodium 320mg 14%",
            "Calcium 30 mg 3%",
        ])

        XCTAssertEqual(try amount(.fat, panel), dec("12"))
        XCTAssertEqual(try amount(.sodium, panel), dec("320"))
        XCTAssertEqual(try amount(.calcium, panel), dec("30"))
        XCTAssertFalse(panel.needsReview(.fat), "the % column is skipped, not guessed at")
    }

    func testLessThanValuesBecomeBelowReportingThreshold() throws {
        let words = parse(["Trans Fat Less than 1g 2%"])
        XCTAssertEqual(value(.transFat, words), .belowReportingThreshold(.g))
        XCTAssertFalse(needsUnit(words, .transFat), "a bound states a unit, not an amount")

        let symbol = parse(["Saturated Fat < 0.5g"])
        XCTAssertEqual(value(.saturatedFat, symbol), .belowReportingThreshold(.g))
        XCTAssertFalse(symbol.needsReview(.saturatedFat), "a stated bound is read as printed")

        let noUnit = parse(["Sodium Less than 5 mg"])
        XCTAssertEqual(value(.sodium, noUnit), .belowReportingThreshold(.mg))
    }

    func testDecimalAmountsAreExact() throws {
        let panel = parse([
            "Total Sugars 0.5 g",
            "Iron 1.8mg",
            "Serving size 1 piece (12.5g)",
            "3.5 servings per container",
        ])

        XCTAssertEqual(try amount(.sugars, panel), dec("0.5"))
        XCTAssertEqual(try amount(.iron, panel), dec("1.8"))
        XCTAssertEqual(panel.servingSize?.quantity, Quantity(value: dec("12.5"), unit: .g))
        XCTAssertEqual(panel.servingsPerContainer, dec("3.5"))
    }

    func testGarbageAndUnrelatedLinesAreIgnored() {
        let panel = parse([
            "",
            "   ",
            "zzzqqq ###",
            "Synthetic Cereal, invented for tests",
            "Distributed by Sample Grocer Co.",
            "Store in a cool place",
            "Questions? Call 1-800-555-0100",
            "* The % Daily Value tells you how much a nutrient contributes to a daily diet.",
            "Calories 90",
        ])

        XCTAssertEqual(value(.calories, panel), .known(dec("90"), .kcal))
        XCTAssertEqual(value(.fat, panel), .unknown)
        XCTAssertEqual(value(.protein, panel), .unknown)
        XCTAssertNil(panel.servingSize)
        XCTAssertFalse(panel.isUnreadable)
    }

    func testPanelWithNoAmountsAtAllIsUnreadable() {
        let panel = parse(["Nutrition Facts", "noise line", "another unrelated line"])

        XCTAssertTrue(panel.isUnreadable)
        XCTAssertNil(panel.servingSize)
        XCTAssertNil(panel.servingsPerContainer)
        XCTAssertTrue(panel.nutrients.values.allSatisfy { $0 == .unknown })
    }

    func testServingSizeWithGramsAndHouseholdMeasure() throws {
        let grams = parse(["Serving size 2/3 cup (55g)"])
        XCTAssertEqual(grams.servingSize?.text, "2/3 cup (55g)")
        XCTAssertEqual(grams.servingSize?.quantity, Quantity(value: dec("55"), unit: .g))

        let volume = parse(["Serving size 1 cup (240mL)"])
        XCTAssertEqual(volume.servingSize?.text, "1 cup (240mL)")
        XCTAssertEqual(volume.servingSize?.quantity, Quantity(value: dec("240"), unit: .mL))

        let volumeSpaced = parse(["Serving size: 3/4 cup (355 ml)"])
        XCTAssertEqual(volumeSpaced.servingSize?.quantity, Quantity(value: dec("355"), unit: .mL))

        let householdOnly = parse(["Serving size 1 large biscuit"])
        XCTAssertEqual(householdOnly.servingSize?.text, "1 large biscuit")
        XCTAssertNil(householdOnly.servingSize?.quantity, "a household measure with no stated amount is not guessed at")
    }

    func testServingsPerContainerVariants() throws {
        XCTAssertEqual(parse(["8 servings per container"]).servingsPerContainer, dec("8"))
        XCTAssertEqual(parse(["Servings Per Container: 12"]).servingsPerContainer, dec("12"))
        XCTAssertEqual(parse(["About 6 servings per container"]).servingsPerContainer, dec("6"))
        XCTAssertNil(parse(["Serving size 1 cup (240mL)"]).servingsPerContainer)
    }

    func testAmountSplitOntoTheNextLine() throws {
        let panel = parse([
            "Total Fat",
            "9g 12%",
            "Sodium 210mg 9%",
        ])

        XCTAssertEqual(try amount(.fat, panel), dec("9"))
        XCTAssertEqual(try unit(.fat, panel), .g)
        XCTAssertEqual(try amount(.sodium, panel), dec("210"))
    }

    func testSeveralRowsOnOneLineAreReadInOrder() throws {
        let panel = parse(["Total Fat 12g 21%  Saturated Fat 4g 20%  Sodium 300mg 13%"])

        XCTAssertEqual(try amount(.fat, panel), dec("12"))
        XCTAssertEqual(try amount(.saturatedFat, panel), dec("4"))
        XCTAssertEqual(try amount(.sodium, panel), dec("300"))
    }

    func testAddedSugarsIsNotReadAsSugars() throws {
        let panel = parse([
            "Total Sugars 12g",
            "Includes 5g Added Sugars 25%",
        ])

        XCTAssertEqual(try amount(.sugars, panel), dec("12"))
        XCTAssertEqual(try amount(.addedSugars, panel), dec("5"))
    }

    func testTransFatInsideSaturatedFatIsNotItsOwnRow() throws {
        let panel = parse(["Saturated Fat 3g 15%  Includes 2g Trans Fat 25%"])

        XCTAssertEqual(try amount(.saturatedFat, panel), dec("3"))
        XCTAssertEqual(value(.transFat, panel), .unknown, "a breakdown of another row is not its own nutrient")
    }

    func testReviewFlagsOnlyMarkLowConfidenceValues() {
        let panel = parse([
            "Total Fat 12g 21%",
            "Sodium 1O mg 4%",
            "Calcium 30 mg 3%",
            "Potassium 350mg",
        ])

        XCTAssertFalse(panel.needsReview(.fat))
        XCTAssertTrue(panel.needsReview(.sodium))
        XCTAssertFalse(panel.needsReview(.calcium))
        XCTAssertEqual(panel.reviewKeys, [.sodium])
        XCTAssertEqual(panel.reviewCount, 1)
    }

    func testUnexpectedUnitIsFlaggedForReview() throws {
        let panel = parse(["Total Fat 120mg"])

        XCTAssertEqual(try amount(.fat, panel), dec("120"))
        XCTAssertEqual(try unit(.fat, panel), .mg, "the printed unit is kept, not rewritten")
        XCTAssertTrue(panel.needsReview(.fat))
        XCTAssertEqual(panel.valuesNeedingReview[.fat.rawValue]?.reasons, [.unexpectedUnit])
    }

    func testEmptyInputParsesToAnUnreadablePanel() {
        let panel = parse([])

        XCTAssertTrue(panel.isUnreadable)
        XCTAssertEqual(panel.nutrients.count, NutritionFactKey.allCases.count)
    }

    private func needsUnit(_ panel: ParsedNutritionFacts, _ key: NutritionFactKey) -> Bool {
        if case .known = panel.value(for: key) { return true }
        return false
    }
}
