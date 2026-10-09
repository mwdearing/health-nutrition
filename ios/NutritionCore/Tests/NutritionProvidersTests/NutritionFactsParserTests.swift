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

    /// The reasons a value was flagged for review. The dictionary is keyed by the string the parser uses,
    /// so the key type is named here rather than left to a leading-dot shorthand.
    private func reviewReasons(_ key: NutritionFactKey, _ panel: ParsedNutritionFacts) -> Set<ParsedValueReview.Reason>? {
        panel.valuesNeedingReview[key.rawValue]?.reasons
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
        XCTAssertEqual(reviewReasons(.sodium, panel), [.correctedLetterO])

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
        XCTAssertTrue(microSign.needsReview(.calcium), "a normalized microgram symbol is low confidence")

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

    func testGroupedThousandsAreKeptWholeAndAmbiguousGroupsStayUnknown() throws {
        let panel = parse([
            "Calories 1,000",
            "Sodium 12,500mg",
            "Iron 1,8mg",
            "Potassium 1,00mg",
        ])

        XCTAssertEqual(try amount(.calories, panel), dec("1000"))
        XCTAssertEqual(try unit(.calories, panel), .kcal)
        XCTAssertEqual(try amount(.sodium, panel), dec("12500"))
        XCTAssertEqual(try unit(.sodium, panel), .mg)
        XCTAssertEqual(value(.iron, panel), .unknown, "a group that is not three digits is never read")
        XCTAssertEqual(value(.potassium, panel), .unknown)
    }

    func testDailyValueRemovalStopsAtTheNextRowOnTheLine() throws {
        let panel = parse(["Trans Fat 0g Total Carbohydrate 20g 7%"])

        XCTAssertEqual(try amount(.transFat, panel), dec("0"))
        XCTAssertEqual(try amount(.carbohydrates, panel), dec("20"), "the next row keeps its own Daily Value")
        XCTAssertEqual(try unit(.carbohydrates, panel), .g)
    }

    func testIncludesAfterATransFatRowDoesNotHideIt() throws {
        let panel = parse([
            "Total Fat 12g 21% Trans Fat 0g Cholesterol 0mg 0% Includes 5g Added Sugars 25%",
        ])

        XCTAssertEqual(try amount(.fat, panel), dec("12"))
        XCTAssertEqual(try amount(.transFat, panel), dec("0"), "a later Includes is not this row's qualifier")
        XCTAssertEqual(try amount(.cholesterol, panel), dec("0"))
        XCTAssertEqual(try amount(.addedSugars, panel), dec("5"))
    }

    func testAnUnreadableRowDoesNotStopTheRestOfTheLine() throws {
        let panel = parse(["Total Fat 7oz Sodium 180mg"])

        XCTAssertEqual(value(.fat, panel), .unknown, "an unsupported unit is not resolved into one that exists")
        XCTAssertEqual(try amount(.sodium, panel), dec("180"), "the next row on the line is still read")
        XCTAssertEqual(try unit(.sodium, panel), .mg)
    }

    func testLeadingAmountsNeedAUnitAndAreNeverDailyValues() throws {
        let stated = parse(["Total Sugars 12g", "Includes 5g Added Sugars"])
        XCTAssertEqual(try amount(.addedSugars, stated), dec("5"))

        let unitless = parse(["Total Sugars 12g", "Includes 5 Added Sugars"])
        XCTAssertEqual(value(.addedSugars, unitless), .unknown, "a leading number without a unit is not a measure")

        let dailyValue = parse(["Total Sugars 12g 24%", "Includes 10% Added Sugars"])
        XCTAssertEqual(value(.addedSugars, dailyValue), .unknown, "a leading Daily Value is not an amount")
        XCTAssertEqual(try amount(.sugars, dailyValue), dec("12"))
    }

    func testServingSizeCorrectionsAreFlaggedForReview() throws {
        let corrected = parse(["Serving size 1 cup (24O mL)"])

        XCTAssertEqual(corrected.servingSize?.text, "1 cup (24O mL)", "the printed text is kept as it was read")
        XCTAssertEqual(corrected.servingSize?.quantity, Quantity(value: dec("240"), unit: .mL))
        XCTAssertEqual(corrected.servingSize?.review?.reasons, [.correctedLetterO])

        let clean = parse(["Serving size 2/3 cup (55g)"])
        XCTAssertEqual(clean.servingSize?.quantity, Quantity(value: dec("55"), unit: .g))
        XCTAssertNil(clean.servingSize?.review, "a serving size read as printed needs no review")
    }

    func testLeadingLetterOBeforeADecimalPointIsCorrected() throws {
        let panel = parse(["Total Sugars O.5g"])

        XCTAssertEqual(try amount(.sugars, panel), dec("0.5"))
        XCTAssertEqual(try unit(.sugars, panel), .g)
        XCTAssertEqual(reviewReasons(.sugars, panel), [.correctedLetterO])
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

    /// A supplement states its serving as a number of things rather than as a weight: "3 gummies",
    /// "1 gummy", "2 pieces". The count is the serving, and both spellings of a counted unit are read
    /// because the number decides the wording.
    func testServingSizeReadsGummiesAsACountedServing() {
        let plural = parse(["Serving size 3 gummies"])
        XCTAssertEqual(plural.servingSize?.text, "3 gummies", "the printed text is kept as it was read")
        XCTAssertEqual(plural.servingSize?.quantity, Quantity(value: dec("3"), unit: .gummy))
        XCTAssertNil(plural.servingSize?.review, "a count read as printed needs no review")

        let singular = parse(["Serving size 1 gummy"])
        XCTAssertEqual(singular.servingSize?.quantity, Quantity(value: dec("1"), unit: .gummy))

        let pieces = parse(["Serving size 2 pieces"])
        XCTAssertEqual(pieces.servingSize?.quantity, Quantity(value: dec("2"), unit: .piece))
        XCTAssertEqual(pieces.servingsPerContainer, nil)
        // The counts a panel already stated keep reading the same way.
        XCTAssertEqual(parse(["Serving size 2 capsules"]).servingSize?.quantity,
                       Quantity(value: dec("2"), unit: .capsule))
        XCTAssertEqual(parse(["Serving size 4 tablets"]).servingSize?.quantity,
                       Quantity(value: dec("4"), unit: .tablet))
        // A count beside a servings count on the same flattened line keeps both.
        let flattened = parse(["Serving size 3 gummies 60 servings per container"])
        XCTAssertEqual(flattened.servingSize?.quantity, Quantity(value: dec("3"), unit: .gummy))
        XCTAssertEqual(flattened.servingsPerContainer, dec("60"))
    }

    /// A counted unit is a serving measure, never a nutrient row's. A panel states no nutrient per
    /// gummy, so a row whose amount sits behind such a word keeps no amount rather than one in a unit
    /// nobody printed for it, and an unknown word is still no unit at all.
    func testNutrientRowsAreNeverReadInACountedUnit() {
        let counted = parse(["Total Fat 3 gummies"])
        XCTAssertEqual(value(.fat, counted), .unknown, "a nutrient is not stated per gummy")

        let unknown = parse(["Serving size 3 widgets"])
        XCTAssertNil(unknown.servingSize?.quantity, "a count the registry does not carry is not a measure")
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
        XCTAssertEqual(reviewReasons(.fat, panel), [.unexpectedUnit])
    }

    func testEmptyInputParsesToAnUnreadablePanel() {
        let panel = parse([])

        XCTAssertTrue(panel.isUnreadable)
        XCTAssertEqual(panel.nutrients.count, NutritionFactKey.allCases.count)
    }

    /// A flattened panel runs the rows that follow a leading amount onto the same line, so the rows
    /// behind "Includes 5g Added Sugars" are still read.
    func testRowsAfterALeadingAmountAreStillRead() throws {
        let panel = parse([
            "Total Sugars 12g",
            "Includes 5g Added Sugars 10% Protein 6g",
        ])

        XCTAssertEqual(try amount(.addedSugars, panel), dec("5"))
        XCTAssertEqual(try amount(.protein, panel), dec("6"), "the row behind the leading amount is not lost")
        XCTAssertEqual(try amount(.sugars, panel), dec("12"))
    }

    /// A name and its amount can land on separate lines, and the row behind that amount shares the line
    /// it was read from.
    func testASplitAmountKeepsReadingTheLineItCameFrom() throws {
        let panel = parse([
            "Total Fat",
            "9g 12% Sodium 210mg 9%",
        ])

        XCTAssertEqual(try amount(.fat, panel), dec("9"))
        XCTAssertEqual(try amount(.sodium, panel), dec("210"), "the unconsumed suffix is still parsed")
    }

    /// A bare number beside a percent sign is a Daily Value the capture flattened onto the row, not a
    /// calorie count.
    func testAPercentageBesideCaloriesIsNotACalorieCount() {
        let panel = parse(["Calories 10%"])

        XCTAssertEqual(value(.calories, panel), .unknown)
    }

    /// A heading merged with a nutrient row skips only its own text.
    func testFlattenedDailyValueHeadingOnlySkipsItsOwnText() throws {
        let panel = parse([
            "% Daily Value Total Fat 7g 9%",
            "Sodium 180mg 8%",
        ])

        XCTAssertEqual(try amount(.fat, panel), dec("7"))
        XCTAssertEqual(try amount(.sodium, panel), dec("180"))
    }

    /// Serving metadata flattened onto one line with another recognized field keeps both.
    func testFlattenedServingMetadataKeepsReadingTheRestOfTheLine() throws {
        let both = parse(["8 servings per container Serving size 1 cup (240mL)"])
        XCTAssertEqual(both.servingsPerContainer, dec("8"))
        XCTAssertEqual(both.servingSize?.quantity, Quantity(value: dec("240"), unit: .mL))

        let withCalories = parse(["Serving size 1 cup (240mL) Calories 100"])
        XCTAssertEqual(try amount(.calories, withCalories), dec("100"), "the row behind the size is read")
        XCTAssertEqual(withCalories.servingSize?.quantity, Quantity(value: dec("240"), unit: .mL))
    }

    /// The count is the number next to the marker, not an earlier number from the rest of the line.
    func testTheServingsCountIsTheNumberNextToTheMarker() {
        XCTAssertEqual(parse(["Net wt 12 oz About 6 servings per container"]).servingsPerContainer, dec("6"))
    }

    /// A count whose digits run straight into a letter is never read as the smaller number they spell.
    func testATruncatedServingsCountIsNotReadAsACompleteNumber() {
        XCTAssertNil(parse(["1O servings per container"]).servingsPerContainer)
    }

    /// An amount is only read in front of a name when the panel prints it there; a number that belongs to
    /// unrecognized text, or to the standard footnote, is left alone.
    func testLeadingAmountsAreOnlyReadFromARowThatPrintsOne() throws {
        XCTAssertEqual(value(.calcium, parse(["Magnesium 50mg Calcium"])), .unknown)
        XCTAssertEqual(
            value(.calories, parse(["2,000 calories a day is used for general nutrition advice"])),
            .unknown,
            "the standard footnote is not a calorie count"
        )
        XCTAssertEqual(
            try amount(.addedSugars, parse(["Total Sugars 12g", "Includes 5g Added Sugars"])),
            dec("5"),
            "a row that does print its amount in front of the name keeps it"
        )
    }

    /// A single-serving package states the singular wording.
    func testSingularServingPerContainerIsRecognized() {
        XCTAssertEqual(parse(["1 serving per container"]).servingsPerContainer, dec("1"))
    }

    /// An alias inside another word does not stop the search for a later whole-word occurrence.
    func testTheSearchContinuesPastAnAliasInsideAnotherWord() throws {
        let panel = parse(["Monosodium glutamate Sodium 180mg 8%"])

        XCTAssertEqual(try amount(.sodium, panel), dec("180"))
    }

    /// A label may put the qualifier between the marker and the count, as in "Servings Per Container
    /// About 8", with or without a colon.
    func testAQualifierBetweenTheMarkerAndTheCountIsSkipped() {
        XCTAssertEqual(parse(["Servings Per Container About 8"]).servingsPerContainer, dec("8"))
        XCTAssertEqual(parse(["Servings Per Container: About 8"]).servingsPerContainer, dec("8"))
    }

    /// Removing a heading that follows a percent sign leaves the percent sign where the row printed it,
    /// so `Calories 10% Daily Value` stays a Daily Value rather than becoming ten calories.
    func testAPercentSignInFrontOfAHeadingIsKept() {
        let panel = parse(["Calories 10% Daily Value"])

        XCTAssertEqual(value(.calories, panel), .unknown)
    }

    /// Flattened serving metadata in the other order: the size comes first and the count behind it, so the
    /// size keeps only its own measure and the count is still read.
    /// OCR can drop every space around the count. Parsing such a line must not trap; it may leave the
    /// serving fields unknown.
    func testACountWithNoSpacesAroundItDoesNotCrash() {
        let panel = parse(["Serving size8servings per container", "Serving size 1 cup8servings per container"])
        XCTAssertNotNil(panel)
        // A count glued to the closing parenthesis is not read (unknown is the safe answer), but parsing
        // the line must still return.
        XCTAssertNotNil(parse(["Serving size 1 cup (240mL)8 servings per container"]))
    }

    func testAServingSizeBeforeItsServingsCountKeepsBoth() {
        let panel = parse(["Serving size 1 cup (240mL) 8 servings per container"])

        XCTAssertEqual(panel.servingSize?.text, "1 cup (240mL)")
        XCTAssertEqual(panel.servingSize?.quantity, Quantity(value: dec("240"), unit: .mL))
        XCTAssertEqual(panel.servingsPerContainer, dec("8"))
    }

    /// A capture that runs the count against the marker colon, as in "Servings Per Container:12" or
    /// "Servings Per Container:About 8", still states its count.
    func testACountGluedToTheMarkerColonIsRead() {
        XCTAssertEqual(parse(["Servings Per Container:12"]).servingsPerContainer, dec("12"))
        XCTAssertEqual(parse(["Servings Per Container:About 8"]).servingsPerContainer, dec("8"))
    }

    /// A percent sign the capture spaced away from its number still belongs to that number, so
    /// "Calories 10 % Daily Value" is a Daily Value rather than ten calories.
    func testASpacedPercentSignStillBelongsToItsNumber() {
        XCTAssertEqual(value(.calories, parse(["Calories 10 % Daily Value"])), .unknown)
    }

    /// A nutrient word inside a serving description is part of the description and not the start of a
    /// row, so the whole measure and its 50 g are kept.
    func testAServingDescriptionMayContainANutrientWord() throws {
        let panel = parse(["Serving size 1 protein bar (50g)"])

        XCTAssertEqual(panel.servingSize?.text, "1 protein bar (50g)")
        XCTAssertEqual(panel.servingSize?.quantity, Quantity(value: dec("50"), unit: .g))
        XCTAssertEqual(value(.protein, panel), .unknown, "a word inside the description is not a row")
    }

    /// A capture that drops the qualifier leaves the amount alone in front of the name, as in
    /// "5g Added Sugars". A number in front of an unrecognized word is still that word's row.
    func testALeadingAmountWithoutItsQualifierIsRead() throws {
        let panel = parse(["Total Sugars 12g", "5g Added Sugars"])

        XCTAssertEqual(try amount(.addedSugars, panel), dec("5"))
        XCTAssertEqual(try unit(.addedSugars, panel), .g)
        XCTAssertEqual(try amount(.sugars, panel), dec("12"))
        XCTAssertEqual(
            value(.calcium, parse(["Magnesium 50mg Calcium"])),
            .unknown,
            "a number behind an unrecognized word is not this row's amount"
        )
    }

    /// A front-of-pack callout in front of a panel row is not a row of the panel, so an amount written in
    /// front of a name with no qualifier is only read for the rows that print their amount first.
    func testACalloutInFrontOfAPanelRowIsNotItsValue() throws {
        let panel = parse(["20g Protein", "Protein 6g"])

        XCTAssertEqual(try amount(.protein, panel), dec("6"), "the panel row is read, not the callout")
        XCTAssertEqual(value(.protein, parse(["20g Protein"])), .unknown)
        XCTAssertEqual(
            try amount(.addedSugars, parse(["Total Sugars 12g", "5g Added Sugars"])),
            dec("5"),
            "the rows that print their amount first still lose the qualifier"
        )
    }

    /// A heading that was flattened together with the rows behind it carries its own percent sign in
    /// front of its words, so the row beside it keeps the amount the label printed.
    func testAFlattenedHeadingKeepsItsOwnPercentSign() throws {
        let panel = parse(["Calories 250 % Daily Value* Total Fat 7g"])

        XCTAssertEqual(try amount(.calories, panel), dec("250"))
        XCTAssertEqual(try amount(.fat, panel), dec("7"))
        XCTAssertEqual(
            value(.calories, parse(["Calories 10 % Daily Value"])),
            .unknown,
            "a sign with no row behind the heading still belongs to its number"
        )
    }

    /// A name the serving metadata line ends with can take its amount from the next line, so it is a row
    /// of the panel rather than part of the serving description.
    func testASplitRowBehindTheServingSizeKeepsBoth() throws {
        let panel = parse(["Serving size 1 bar (50g) Protein", "6g"])

        XCTAssertEqual(panel.servingSize?.text, "1 bar (50g)")
        XCTAssertEqual(panel.servingSize?.quantity, Quantity(value: dec("50"), unit: .g))
        XCTAssertEqual(try amount(.protein, panel), dec("6"))
    }

    /// A percent sign that touches its number is that row's Daily Value whatever the heading does, while a
    /// sign the capture spaced in front of a heading it flattened with the rows behind it is the heading's.
    func testAPercentSignTouchingItsNumberStaysADailyValue() throws {
        let attached = parse(["Calories 10% Daily Value Total Fat 7g"])
        XCTAssertEqual(value(.calories, attached), .unknown)
        XCTAssertEqual(try amount(.fat, attached), dec("7"))

        let attachedBeforeAmount = parse(["Calories 10% Daily Value 5g Added Sugars"])
        XCTAssertEqual(value(.calories, attachedBeforeAmount), .unknown)

        let spaced = parse(["Calories 250 % Daily Value* Total Fat 7g"])
        XCTAssertEqual(try amount(.calories, spaced), dec("250"), "a spaced sign in front of a heading is the heading's")
        XCTAssertEqual(try amount(.fat, spaced), dec("7"))
    }

    /// Added Sugars is the only row read from a qualifier-free leading amount: every other row states its
    /// amount behind its name, so a callout in front of one is not a row of the panel.
    func testACalloutInFrontOfATransFatRowIsNotItsValue() throws {
        let panel = parse(["0g Trans Fat", "Trans Fat 1g"])

        XCTAssertEqual(try amount(.transFat, panel), dec("1"), "the panel row is read, not the callout")
        XCTAssertEqual(value(.transFat, parse(["0g Trans Fat"])), .unknown)
        XCTAssertEqual(
            try amount(.addedSugars, parse(["Total Sugars 12g", "5g Added Sugars"])),
            dec("5"),
            "the row that prints its amount first still loses the qualifier"
        )
    }

    /// A serving description can name a nutrient more than once before the row behind it, and each name is
    /// stepped over once, so the row is still found and the description is not swallowed.
    func testANutrientWordBeforeARowIsSteppedOverOnlyOnce() throws {
        let panel = parse(["Serving size 1 high protein bar Protein 6g"])

        XCTAssertEqual(panel.servingSize?.text, "1 high protein bar")
        XCTAssertEqual(try amount(.protein, panel), dec("6"))
    }

    // MARK: - The round the owner read on a phone

    /// A supplement panel prints its lot number and its best-by date on the same line as the serving,
    /// because that is where the space is. Neither belongs to the serving, so the measure ends where the
    /// measure ends: "3 Gummies", with the packaging text behind it left where it was printed.
    func testTheServingSizeStopsAfterTheMeasureAndNotAfterTheLotNumber() {
        let panel = parse([
            "Supplement Facts",
            "Serving Size: 3 Gummies LOT# : 260628007 Best",
            "Amount Per Serving",
            "Calories 30",
        ])

        XCTAssertEqual(panel.servingSize?.text, "3 Gummies", "the lot number is not part of the serving")
        XCTAssertEqual(panel.servingSize?.quantity, Quantity(value: dec("3"), unit: .gummy))
        // The packaging text behind it states no row, so it is nothing the panel has to answer for.
        XCTAssertTrue(panel.additionalNutrients.isEmpty, "a lot number is not a nutrient row")
        XCTAssertEqual(value(.calories, panel), .known(dec("30"), .kcal))
    }

    /// A panel may print a colon after the name it prints an amount behind. It is the label's own
    /// punctuation, so "Calories: 30" states thirty calories exactly as "Calories 30" does.
    func testCaloriesWithAColonAfterTheNameIsRead() throws {
        let panel = parse(["Calories: 30", "Total Fat: 0g", "Sodium: 180 mg"])

        XCTAssertEqual(value(.calories, panel), .known(dec("30"), .kcal))
        XCTAssertEqual(value(.fat, panel), .known(dec("0"), .g))
        XCTAssertEqual(try amount(.sodium, panel), dec("180"))
        XCTAssertEqual(try unit(.sodium, panel), .mg)
    }

    /// Added sugars is stated inside the total sugars row, with the amount in front of the name, as
    /// "Includes 3g Added Sugars". The row the table names is the one the label printed there.
    func testIncludesAddedSugarsWithTheAmountInFrontIsRead() throws {
        let panel = parse([
            "Total Sugars 4g",
            "Includes 3g Added Sugars",
        ])

        XCTAssertEqual(try amount(.sugars, panel), dec("4"))
        XCTAssertEqual(try amount(.addedSugars, panel), dec("3"))
        XCTAssertEqual(try unit(.addedSugars, panel), .g)
    }

    /// A supplement states compounds the fifteen journal nutrients do not name, and reading them is the
    /// point of scanning one. Such a row is kept under the label's own name and a slug of it, with its
    /// own amount and unit, and the rows the table does name are left alone.
    func testACreatineRowIsCollectedAsAnAdditionalNutrient() throws {
        let panel = parse([
            "Supplement Facts",
            "Serving Size: 3 Gummies",
            "Calories 30",
            "Total Carbohydrate 5g 2%",
            "Creatine Monohydrate 3g",
            "Vitamin D3 25mcg 15%",
            "Zinc 15mg 15% DV",
            "Coenzyme Q10 100mg †",
        ])

        let creatine = try XCTUnwrap(panel.additionalNutrient(for: "creatine-monohydrate"))
        XCTAssertEqual(creatine.name, "Creatine Monohydrate", "the row keeps the name the label printed")
        XCTAssertEqual(creatine.value, .known(dec("3"), .g))

        // The columns the label prints beside a row are not part of its amount.
        let zinc = try XCTUnwrap(panel.additionalNutrient(for: "zinc"))
        XCTAssertEqual(zinc.value, .known(dec("15"), .mg))
        let q10 = try XCTUnwrap(panel.additionalNutrient(for: "coenzyme-q10"))
        XCTAssertEqual(q10.value, .known(dec("100"), .mg))

        // A row the table already names is a nutrient row, never a second copy of one as a compound.
        XCTAssertNil(panel.additionalNutrient(for: "vitamin-d"))
        XCTAssertNil(panel.additionalNutrient(for: "carbohydrates"))
        XCTAssertNil(panel.additionalNutrient(for: "calories"))
        XCTAssertEqual(try amount(.calories, panel), dec("30"))
    }

    /// The rows a panel collects are the ones that state a name and an amount. A line that states
    /// neither is text the panel printed, not a compound the parser made up: an ingredients line has
    /// no amount on it, and neither does the footnote.
    func testALineThatStatesNoAmountIsNotAnAdditionalNutrient() {
        let panel = parse([
            "Supplement Facts",
            "Serving Size: 2 Capsules",
            "Calories 10",
            "Other Ingredients: Tapioca Syrup",
            "* The % Daily Value tells you how much a nutrient contributes to a daily diet.",
            "Questions? Call 1-800-555-0100",
        ])

        XCTAssertTrue(
            panel.additionalNutrients.isEmpty,
            "only a name with an amount is a row: \(panel.additionalNutrients.map(\.name))"
        )
        XCTAssertEqual(panel.servingSize?.text, "2 Capsules")
    }

    // MARK: - The fixes the owner asked for after round two

    /// Packaging print states no nutrient, so it is never collected as a compound row: a net weight, a
    /// lot number, a best-by date and the serving metadata all read as nothing.
    func testNetWeightAndOtherPackagingTextAreNotRows() {
        let panels = [
            ["NET WT 100 g"],
            ["Net weight 100 g"],
            ["Serving size 3 gummies"],
            ["Servings per container", "12"],
            ["Lot 123 Best by 2027"],
            ["Calories from fat 9g"],
        ]

        for lines in panels {
            let panel = parse(lines)
            XCTAssertTrue(
                panel.additionalNutrients.isEmpty,
                "packaging text is not a row: \(panel.additionalNutrients.map(\.name)) from \(lines)")
        }
    }

    /// A name that carries its chemical form is the nutrient it is built on, with the printed form kept
    /// as the display name. The search must not restart inside the rejected name and invent "Citrate"
    /// or "Bisglycinate" as compounds of their own.
    func testAChemicalFormNameStaysOneNutrientRow() throws {
        let panel = parse(["Calcium Citrate 200mg", "Iron Bisglycinate 25mg"])

        XCTAssertEqual(try amount(.calcium, panel), dec("200"))
        XCTAssertEqual(try unit(.calcium, panel), .mg)
        XCTAssertEqual(panel.displayName(for: .calcium), "Calcium Citrate", "the form is the display name")

        XCTAssertEqual(try amount(.iron, panel), dec("25"))
        XCTAssertEqual(panel.displayName(for: .iron), "Iron Bisglycinate")

        XCTAssertNil(panel.additionalNutrient(for: "citrate"))
        XCTAssertNil(panel.additionalNutrient(for: "bisglycinate"))
        XCTAssertTrue(panel.additionalNutrients.isEmpty)
    }

    /// An amount in international units is read, spaced or run against its number.
    func testInternationalUnitAmountIsCaptured() throws {
        let panel = parse(["Vitamin A 900IU", "Vitamin E 15 iu"])

        let a = try XCTUnwrap(panel.additionalNutrient(for: "vitamin-a"))
        XCTAssertEqual(a.value, .known(dec("900"), .iu))
        let e = try XCTUnwrap(panel.additionalNutrient(for: "vitamin-e"))
        XCTAssertEqual(e.value, .known(dec("15"), .iu))
    }

    /// A serving amount the capture printed with a letter O where a zero belongs still ends the serving
    /// where its measure ends, so the packaging text behind it is not swallowed into the serving.
    func testACorrectedLetterOEndsTheServingSizeBeforeTheLotNumber() {
        let panel = parse(["Serving Size: 3O g LOT# : 123", "Calories 30"])

        XCTAssertEqual(panel.servingSize?.text, "3O g", "the printed text is kept as read")
        XCTAssertEqual(panel.servingSize?.quantity, Quantity(value: dec("30"), unit: .g))
        XCTAssertEqual(panel.servingSize?.review?.reasons, [.correctedLetterO])
        XCTAssertTrue(panel.additionalNutrients.isEmpty, "the lot number is not a row")
        XCTAssertEqual(value(.calories, panel), .known(dec("30"), .kcal))
    }

    /// A column-by-column capture leaves a compound's name on one line and its amount on the next, and
    /// the two are one row, exactly as a named nutrient row split across lines is.
    func testAColumnSplitCompoundRowIsOneRow() throws {
        let panel = parse(["Creatine Monohydrate", "3g"])

        let creatine = try XCTUnwrap(panel.additionalNutrient(for: "creatine-monohydrate"))
        XCTAssertEqual(creatine.name, "Creatine Monohydrate")
        XCTAssertEqual(creatine.value, .known(dec("3"), .g))
    }

    /// A compound's amount can land on the next line beside the rows that follow it, and those rows
    /// are still read rather than being skipped with the line the amount came from: the split read
    /// consumes the amount, not the whole of the line behind it.
    func testASplitCompoundAmountStillReadsTheRowsBesideIt() throws {
        let panel = parse(["Creatine", "3g Protein 2g Choline 5g"])

        let creatine = try XCTUnwrap(panel.additionalNutrient(for: "creatine"))
        XCTAssertEqual(creatine.value, .known(dec("3"), .g))
        XCTAssertEqual(try amount(.protein, panel), dec("2"), "the named row behind the amount is read")
        XCTAssertEqual(try unit(.protein, panel), .g)
        let choline = try XCTUnwrap(panel.additionalNutrient(for: "choline"))
        XCTAssertEqual(choline.value, .known(dec("5"), .g))
    }

    /// A compound row states a bound the same way a named row does, so "Less than 1 g" is captured
    /// as a below-reporting-threshold value rather than lost between the name and the number.
    func testACompoundBoundIsCapturedAsBelowReportingThreshold() throws {
        let panel = parse(["Creatine Monohydrate Less than 1 g"])

        let creatine = try XCTUnwrap(panel.additionalNutrient(for: "creatine-monohydrate"))
        XCTAssertEqual(creatine.name, "Creatine Monohydrate")
        XCTAssertEqual(creatine.value, .belowReportingThreshold(.g))
    }

    /// A flattened line can run a unitless calorie count into a compound row. The compound is segmented
    /// off first, so the calories keep their 30 and the compound is captured rather than lost.
    func testAUnitlessCalorieCountAndACompoundOnOneLineAreBothRead() throws {
        let panel = parse(["Calories 30 Creatine 3g"])

        XCTAssertEqual(value(.calories, panel), .known(dec("30"), .kcal))
        let creatine = try XCTUnwrap(panel.additionalNutrient(for: "creatine"))
        XCTAssertEqual(creatine.value, .known(dec("3"), .g))
    }

    /// A flattened line can run a compound in front of the first named row, and the text a named row
    /// does not claim on either side of it is still read: "Creatine 3g Protein 2g Choline 5g" gives all
    /// three, rather than dropping the compound before the named row.
    func testACompoundBeforeAndAfterANamedRowOnAFlattenedLineIsKept() throws {
        let panel = parse(["Creatine 3g Protein 2g Choline 5g"])

        let creatine = try XCTUnwrap(panel.additionalNutrient(for: "creatine"))
        XCTAssertEqual(creatine.value, .known(dec("3"), .g))
        let choline = try XCTUnwrap(panel.additionalNutrient(for: "choline"))
        XCTAssertEqual(choline.value, .known(dec("5"), .g))
        XCTAssertEqual(try amount(.protein, panel), dec("2"))
        XCTAssertEqual(try unit(.protein, panel), .g)
    }

    /// A name that merely begins with a nutrient is not that nutrient. Only a name whose remaining word
    /// states a known chemical form is the nutrient it is built on, so "Iron Support Blend 25mg" stays
    /// a compound of its own rather than being pulled into iron.
    func testANameThatOnlyStartsWithANutrientStaysItsOwnCompound() throws {
        let panel = parse(["Iron Support Blend 25mg", "Calcium Citrate 200mg"])

        let blend = try XCTUnwrap(panel.additionalNutrient(for: "iron-support-blend"))
        XCTAssertEqual(blend.value, .known(dec("25"), .mg))
        XCTAssertNil(panel.additionalNutrient(for: "iron"))
        XCTAssertEqual(value(.iron, panel), .unknown, "the blend is not iron")

        // The form list still promotes a name that does state one.
        XCTAssertEqual(try amount(.calcium, panel), dec("200"))
        XCTAssertEqual(panel.displayName(for: .calcium), "Calcium Citrate")
    }

    /// A panel whose heading says Supplement Facts is a supplement, and its rows are read exactly as
    /// carefully: Vitamin D is Vitamin D whichever panel prints it.
    func testASupplementFactsHeadingMakesThePanelASupplement() throws {
        let panel = parse([
            "Supplement Facts",
            "Sample daily multi, invented for tests",
            "Serving size 1 tablet",
            "Amount per serving",
            "Vitamin D 25mcg 125%",
            "Calcium 200mg 20%",
            "* The % Daily Value tells you how much a nutrient contributes to a daily diet.",
        ])

        XCTAssertEqual(panel.panelKind, .supplementFacts)
        XCTAssertTrue(panel.isSupplementPanel)
        XCTAssertEqual(panel.panelKind.productKind, .supplement)
        XCTAssertEqual(try amount(.vitaminD, panel), dec("25"))
        XCTAssertEqual(try amount(.calcium, panel), dec("200"))
        // A supplement says nothing about fat, and that is not a missing row to chase: the rows it prints
        // are read, and the rows it does not print are simply not there.
        XCTAssertEqual(value(.fat, panel), .unknown)
        XCTAssertFalse(panel.isUnreadable)
    }

    /// The heading arrives from a camera in whatever case the label set it in, and a heading that is
    /// somewhere in the text rather than alone on its line is still the heading.
    func testTheSupplementHeadingIsReadInAnyCaseAndAnywhereInTheLine() {
        XCTAssertEqual(
            parse(["Example Supplement Facts blend panel", "Vitamin D 25mcg"]).panelKind, .supplementFacts)
        XCTAssertEqual(parse(["SUPPLEMENT FACTS"]).panelKind, .supplementFacts)
    }

    /// A Nutrition Facts panel, and a panel with no heading at all, are both foods. Losing the heading
    /// costs the label its kind and nothing else, which is the safe direction: a food recorded as a
    /// supplement would drop out of the day's count, and the reverse is a word on the review screen.
    func testAPanelWithoutTheSupplementHeadingIsAFood() {
        XCTAssertEqual(parse(fullPanel).panelKind, .nutritionFacts)
        XCTAssertEqual(parse(fullPanel).panelKind.productKind, .food)
        XCTAssertEqual(parse([]).panelKind, .nutritionFacts)
        // A food panel that happens to list a vitamin still names the same rows as a supplement does, so
        // only the heading tells them apart.
        XCTAssertEqual(parse(["Vitamin D 2mcg 10%"]).panelKind, .nutritionFacts)
    }

    private func needsUnit(_ panel: ParsedNutritionFacts, _ key: NutritionFactKey) -> Bool {
        if case .known = panel.value(for: key) { return true }
        return false
    }
}
