import XCTest
@testable import NutritionUI

final class AddScannerAvailabilityTests: XCTestCase {
    func testSupportedHardwareEnablesBothTilesEvenWhenAccessIsDenied() {
        // The Add tiles follow hardware support only, so a denied or restricted camera can still open its sheet.
        let availability = AddScannerAvailability.forSupport(true)
        XCTAssertTrue(availability.barcode)
        XCTAssertTrue(availability.label)
    }

    func testUnsupportedHardwareDisablesBothTilesWithTheirHelpText() {
        let availability = AddScannerAvailability.forSupport(false)
        XCTAssertFalse(availability.barcode)
        XCTAssertFalse(availability.label)
        XCTAssertEqual(availability.barcodeExplanation, "This device can't scan barcodes. Type the digits instead.")
        XCTAssertEqual(availability.labelExplanation, "This device can't scan labels. Type the values instead.")
    }
}
