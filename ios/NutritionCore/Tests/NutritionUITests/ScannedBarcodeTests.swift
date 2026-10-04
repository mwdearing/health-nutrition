import XCTest
@testable import NutritionUI

/// The camera hands over whatever the scanner read, including whitespace and codes this app does
/// not look up. `ScannedBarcode.normalize` is the one place that decides whether a payload is a
/// barcode the intake form can use, so a scan can never put something in the field that a typed
/// barcode of the same digits would have been rejected for.
///
/// Every code below is invented: the digits are made up and the check digit is computed from them,
/// so no number a real product carries appears here.
final class ScannedBarcodeTests: XCTestCase {
    /// Whitespace around the payload is trimmed, so a scanner that appends a newline, or that pads
    /// the code it read, still fills the field.
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(ScannedBarcode.normalize(" 2001234567893\n"), "2001234567893")
        XCTAssertEqual(ScannedBarcode.normalize("\t200123456788 "), "200123456788")
    }

    /// Letters are rejected: no barcode carries them, and a code with a letter in it would be
    /// refused by the lookup anyway.
    func testRejectsLetters() {
        XCTAssertNil(ScannedBarcode.normalize("20012345678ab"))
        XCTAssertNil(ScannedBarcode.normalize("ABCDEFGH"))
    }

    /// An empty or whitespace-only payload is nothing to look up, so it normalizes to nil.
    func testRejectsEmptyPayload() {
        XCTAssertNil(ScannedBarcode.normalize(""))
        XCTAssertNil(ScannedBarcode.normalize("   "))
    }

    /// The GS1 check digit has to be right, as it does for a typed barcode: the last digit of
    /// 2001234567893 is the correct check digit, 2001234567890 is not.
    func testRejectsWrongCheckDigit() {
        XCTAssertEqual(ScannedBarcode.normalize("2001234567893"), "2001234567893")
        XCTAssertNil(ScannedBarcode.normalize("2001234567890"))
    }

    /// EAN-13: 13 digits with a valid check digit.
    func testAcceptsValidEAN13() {
        XCTAssertEqual(ScannedBarcode.normalize("2001234567893"), "2001234567893")
    }

    /// UPC-A: 12 digits with a valid check digit.
    func testAcceptsValidUPC_A() {
        XCTAssertEqual(ScannedBarcode.normalize("200123456788"), "200123456788")
    }

    /// EAN-8: 8 digits with a valid check digit.
    func testAcceptsValidEAN8() {
        XCTAssertEqual(ScannedBarcode.normalize("20012342"), "20012342")
    }

    /// Lengths other than 8, 12 or 13 are not looked up, scanned or typed.
    func testRejectsOtherLengths() {
        XCTAssertNil(ScannedBarcode.normalize("1234567"))
        XCTAssertNil(ScannedBarcode.normalize("12345678901234"))
    }

    /// A UPC-E payload stands for a GTIN-12 with the zeros the printed code leaves out, so it is
    /// expanded rather than looked up as the eight digits it shows.
    func testExpandsUPCEToItsGTIN12() {
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234558"), "012345000058")
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234565"), "012345000065")
        XCTAssertEqual(ScannedBarcode.expandUPCE("11234555"), "112345000055")
    }

    /// The last of the six compressed digits says where the omitted zeros go, so every value of it
    /// expands differently, and each result is a GTIN-12 with a correct check digit.
    func testExpandsEveryUPCECompressionCase() {
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234505"), "012000003455")
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234514"), "012100003454")
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234523"), "012200003453")
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234531"), "012300000451")
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234543"), "012340000053")
        XCTAssertEqual(ScannedBarcode.expandUPCE("01234596"), "012345000096")
    }

    /// The check digit in a UPC-E payload is the one of the expanded code, so a payload carrying
    /// the wrong one is rejected instead of expanding into a number that does not exist.
    func testRejectsUPCEWithWrongCheckDigit() {
        XCTAssertNil(ScannedBarcode.expandUPCE("01234559"))
        XCTAssertNil(ScannedBarcode.expandUPCE("01234550"))
    }

    /// UPC-E has eight digits and the number systems 0 and 1 only, so anything else is a different
    /// symbology and is left to `normalize`.
    func testRejectsPayloadsThatAreNotUPCE() {
        XCTAssertNil(ScannedBarcode.expandUPCE("20012342"))
        XCTAssertNil(ScannedBarcode.expandUPCE("0123455"))
        XCTAssertNil(ScannedBarcode.expandUPCE("0123455x8"))
        XCTAssertNil(ScannedBarcode.expandUPCE(""))
    }

    /// The compressed digits of a UPC-E payload pass the EAN-8 check, which is exactly why the
    /// scanner expands them before normalizing instead of normalizing what it read: 01234558 would
    /// otherwise be looked up as a GTIN-8 that is not on the package.
    func testUPCEPayloadAlsoPassesTheEAN8CheckSoExpansionIsNeeded() {
        XCTAssertEqual(ScannedBarcode.normalize("01234558"), "01234558")
        XCTAssertNotEqual(
            ScannedBarcode.expandUPCE("01234558"), ScannedBarcode.normalize("01234558"))
    }

    /// A scanned barcode ends in the same accepted form a typed one does, expansion first for UPC-E.
    func testExpandedBarcodeIsAcceptedByNormalize() {
        guard let expanded = ScannedBarcode.expandUPCE("01234558") else {
            return XCTFail("01234558 is a valid UPC-E payload")
        }
        XCTAssertEqual(ScannedBarcode.normalize(expanded), expanded)
    }
}
