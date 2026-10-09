import Foundation
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

    /// Stored and exported text never depends on the region.
    func testStoredTextIsStillReadWithAPointOnly() {
        XCTAssertNil(AmountParser.parse("2,5"))
        XCTAssertEqual(AmountParser.parse("2.5"), Decimal(string: "2.5"))
    }
}
