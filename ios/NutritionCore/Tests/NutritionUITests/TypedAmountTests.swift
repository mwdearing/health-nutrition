import Foundation
import NutritionDomain
import XCTest
@testable import NutritionUI

/// An amount typed into a field is read with the separator of the device's region; stored text is not.
final class TypedAmountTests: XCTestCase {
    func testACommaIsTheDecimalSeparatorWhereTheRegionUsesOne() {
        XCTAssertEqual(AmountParser.parseTyped("2,5", decimalSeparator: ","), Decimal(string: "2.5"))
        XCTAssertEqual(AmountParser.parseTyped(" 0,25 ", decimalSeparator: ","), Decimal(string: "0.25"))
        // A point is still a point there.
        XCTAssertEqual(AmountParser.parseTyped("2.5", decimalSeparator: ","), Decimal(string: "2.5"))
        XCTAssertEqual(AmountParser.parseTyped("250", decimalSeparator: ","), Decimal(250))
    }

    /// A comma region's "1,000" could be a thousands separator, and reading it as 1.0 would save a thousandth of the
    /// amount with no warning, so it is refused. Real decimals, including three decimals after a zero, still read.
    func testAThousandsStyleCommaIsRefusedInACommaRegion() {
        XCTAssertNil(AmountParser.parseTyped("1,000", decimalSeparator: ","))
        XCTAssertNil(AmountParser.parseTyped("12,500", decimalSeparator: ","))
        XCTAssertNil(AmountParser.parseTyped("999,999", decimalSeparator: ","))
        XCTAssertEqual(AmountParser.parseTyped("2,50", decimalSeparator: ","), Decimal(string: "2.5"))
        XCTAssertEqual(AmountParser.parseTyped("2,5", decimalSeparator: ","), Decimal(string: "2.5"))
        XCTAssertEqual(AmountParser.parseTyped("0,125", decimalSeparator: ","), Decimal(string: "0.125"))
        XCTAssertEqual(AmountParser.parseTyped("1,5000", decimalSeparator: ","), Decimal(string: "1.5"))
        XCTAssertEqual(AmountParser.normalizedTyped("1,000", decimalSeparator: ","), "1,000", "left as typed so it is refused")
        XCTAssertTrue(AmountParser.isRefusedThousandsSeparator("1,000", decimalSeparator: ","))
        XCTAssertFalse(AmountParser.isRefusedThousandsSeparator("1,000", decimalSeparator: "."), "a point region refuses it as before")
        XCTAssertFalse(AmountParser.isRefusedThousandsSeparator("2,5", decimalSeparator: ","))
        XCTAssertEqual(AmountParser.thousandsSeparatorMessage, "Type the amount without a thousands separator, or use a point for a decimal.")
    }

    func testACommaIsRefusedWhereTheRegionUsesAPoint() {
        XCTAssertNil(AmountParser.parseTyped("2,5", decimalSeparator: "."))
        XCTAssertNil(AmountParser.parseTyped("1,000", decimalSeparator: "."))
        XCTAssertNil(AmountParser.parseTyped("2,5", decimalSeparator: nil))
        XCTAssertEqual(AmountParser.parseTyped("2.5", decimalSeparator: "."), Decimal(string: "2.5"))
    }

    func testMixedOrRepeatedSeparatorsAreRefusedEverywhere() {
        XCTAssertNil(AmountParser.parseTyped("1.234,5", decimalSeparator: ","))
        XCTAssertNil(AmountParser.parseTyped("1,234,5", decimalSeparator: ","))
        XCTAssertNil(AmountParser.parseTyped(",", decimalSeparator: ","))
        XCTAssertNil(AmountParser.parseTyped("0,0", decimalSeparator: ","))
        XCTAssertNil(AmountParser.parseTyped("", decimalSeparator: ","))
    }

    /// Recipe nutrient fields take zero as a value, and read a typed comma the same way.
    @MainActor
    func testARecipeNutrientFieldReadsATypedComma() {
        XCTAssertEqual(
            RecipeEditorViewModel.parseNonNegative("2,5", decimalSeparator: ","), Decimal(string: "2.5"))
        XCTAssertEqual(RecipeEditorViewModel.parseNonNegative("0,0", decimalSeparator: ","), Decimal(0))
        XCTAssertEqual(RecipeEditorViewModel.parseNonNegative("0.5", decimalSeparator: ","), Decimal(string: "0.5"))
        XCTAssertNil(RecipeEditorViewModel.parseNonNegative("2,5", decimalSeparator: "."))
        XCTAssertNil(RecipeEditorViewModel.parseNonNegative("1,5,0", decimalSeparator: ","))
    }

    /// The Entry screen compares what was typed with the stored text, which always uses a point.
    @MainActor
    func testTheEntryAmountMatchesItsStoredTextWhenTypedWithAComma() {
        XCTAssertTrue(EntryDetailViewModel.sameAmountText("2.5", "2,5", decimalSeparator: ","))
        XCTAssertTrue(EntryDetailViewModel.sameAmountText("2.5", "2,50", decimalSeparator: ","))
        XCTAssertFalse(EntryDetailViewModel.sameAmountText("2.5", "2,6", decimalSeparator: ","))
        XCTAssertFalse(EntryDetailViewModel.sameAmountText("2.5", "2,5", decimalSeparator: "."))
        // The stored side is never read with the region's separator.
        XCTAssertFalse(EntryDetailViewModel.sameAmountText("2,5", "2.5", decimalSeparator: ","))
    }

    /// A label correction may name a unit after the number.
    func testALabelCorrectionReadsATypedComma() {
        XCTAssertEqual(
            NutrientAmountParser.parseTyped("2,5 g", decimalSeparator: ","),
            NutrientAmountParser.Amount(value: Decimal(string: "2.5")!, unit: .g))
        XCTAssertEqual(
            NutrientAmountParser.parseTyped("0,5", decimalSeparator: ","),
            NutrientAmountParser.Amount(value: Decimal(string: "0.5")!, unit: nil))
        XCTAssertEqual(
            NutrientAmountParser.parseTyped("2.5 g", decimalSeparator: ","),
            NutrientAmountParser.Amount(value: Decimal(string: "2.5")!, unit: .g))
        XCTAssertNil(NutrientAmountParser.parseTyped("2,5 g", decimalSeparator: "."))
        XCTAssertNil(NutrientAmountParser.parseTyped("1.234,5 g", decimalSeparator: ","))
        XCTAssertNil(NutrientAmountParser.parse("2,5 g"))
    }

    /// Stored and exported text never depends on the region.
    func testStoredTextIsStillReadWithAPointOnly() {
        XCTAssertNil(AmountParser.parse("2,5"))
        XCTAssertEqual(AmountParser.parse("2.5"), Decimal(string: "2.5"))
    }
}
