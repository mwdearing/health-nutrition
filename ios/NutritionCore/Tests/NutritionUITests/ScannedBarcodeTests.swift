import XCTest
@testable import NutritionUI

/// The camera hands over whatever the scanner read, including whitespace and codes this app does
/// not look up. `ScannedBarcode.normalize` is the one place that decides whether a payload is a
/// barcode the intake form can use, so a scan can never put something in the field that a typed
/// barcode of the same digits would have been rejected for.
final class ScannedBarcodeTests: XCTestCase {
    /// Whitespace around the payload is trimmed, so a scanner that appends a newline or a scanner
    /// that pads the code still fills the field.
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(ScannedBarcode.normalize(" 4006381333931\n"), "4006381333931")
        XCTAssertEqual(ScannedBarcode.normalize("\t500011263796 "), "500011263796")
    }

    /// Letters are rejected: no barcode carries them, and a code with a letter in it would be
    /// refused by the lookup anyway.
    func testRejectsLetters() {
        XCTAssertNil(ScannedBarcode.normalize("40063813339ab"))
        XCTAssertNil(ScannedBarcode.normalize("ABCDEFGH"))
    }

    /// An empty or whitespace-only payload is nothing to look up, so it normalizes to nil.
    func testRejectsEmptyPayload() {
        XCTAssertNil(ScannedBarcode.normalize(""))
        XCTAssertNil(ScannedBarcode.normalize("   "))
    }

    /// The GS1 check digit has to be right, as it does for a typed barcode: the last digit of
    /// 4006381333931 is the correct check digit, 4006381333930 is not.
    func testRejectsWrongCheckDigit() {
        XCTAssertEqual(ScannedBarcode.normalize("4006381333931"), "4006381333931")
        XCTAssertNil(ScannedBarcode.normalize("4006381333930"))
    }

    /// EAN-13: 13 digits with a valid check digit.
    func testAcceptsValidEAN13() {
        XCTAssertEqual(ScannedBarcode.normalize("4006381333931"), "4006381333931")
    }

    /// UPC-A: 12 digits with a valid check digit.
    func testAcceptsValidUPC_A() {
        XCTAssertEqual(ScannedBarcode.normalize("500011263796"), "500011263796")
    }

    /// EAN-8: 8 digits with a valid check digit.
    func testAcceptsValidEAN8() {
        XCTAssertEqual(ScannedBarcode.normalize("96385074"), "96385074")
    }

    /// Lengths other than 8, 12 or 13 are not looked up, scanned or typed.
    func testRejectsOtherLengths() {
        XCTAssertNil(ScannedBarcode.normalize("1234567"))
        XCTAssertNil(ScannedBarcode.normalize("12345678901234"))
    }
}
