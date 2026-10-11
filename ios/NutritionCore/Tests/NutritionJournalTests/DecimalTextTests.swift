import Foundation
import XCTest
@testable import NutritionJournal

final class DecimalTextTests: XCTestCase {
    func testDecodePreservesExactValuesAndSupportedDecimalSpellings() throws {
        let cases: [(String, String)] = [
            ("0", "0"), ("-0", "0"), ("+12.50", "12.5"),
            (".5", "0.5"), ("1.", "1"), ("1e+2", "100"),
            ("-1.25E-2", "-0.0125"), ("00012.3400", "12.34"),
        ]

        for (text, expected) in cases {
            let value = try XCTUnwrap(DecimalText.decode(text), text)
            XCTAssertEqual(DecimalText.encode(value), expected, text)
        }
    }

    func testDecodeRejectsMalformedOrRoundedValues() {
        XCTAssertNil(DecimalText.decode("1.2.3"))
        XCTAssertNil(DecimalText.decode("1e"))
        XCTAssertNil(DecimalText.decode("--1"))
        XCTAssertNil(DecimalText.decode("1234567890123456789012345678901234567890123")) // 43 digits
        XCTAssertNil(DecimalText.decode("1e128"))
        XCTAssertNil(DecimalText.decode("1e-128"))
    }

    func testThirtyEightSignificantDigitsAndZeroPaddingRemainExact() throws {
        let thirtyEight = "12345678901234567890123456789012345678"
        let exact = try XCTUnwrap(DecimalText.decode(thirtyEight))
        XCTAssertEqual(DecimalText.encode(exact), thirtyEight)

        // The terminal zero is a place-value zero, so this still has 38 significant digits.
        let paddedInteger = thirtyEight + "0"
        let padded = try XCTUnwrap(DecimalText.decode(paddedInteger))
        XCTAssertEqual(DecimalText.encode(padded), paddedInteger)
        let leadingZeros = String(repeating: "0", count: 20) + thirtyEight
        XCTAssertEqual(DecimalText.encode(try XCTUnwrap(DecimalText.decode(leadingZeros))), thirtyEight)

        // Fractional trailing zeros also carry no additional precision.
        XCTAssertEqual(DecimalText.encode(try XCTUnwrap(DecimalText.decode("1." + String(repeating: "0", count: 40)))), "1")
    }

    func testAdjustedExponentBoundsMatchProviderPolicy() throws {
        for text in ["1e127", "1e-127", "0e0"] {
            XCTAssertNotNil(DecimalText.decode(text), text)
        }
        for text in ["1e128", "1e-128"] {
            XCTAssertNil(DecimalText.decode(text), text)
        }
    }
}
