import XCTest
@testable import NutritionUI

final class CameraAccessNoticeTests: XCTestCase {
    func testDeniedAccessSaysToTurnItOnInSettingsOnBothSheets() {
        for sheet in [CameraSheet.barcode, .label] {
            XCTAssertEqual(
                CameraAccessNotice.failureMessage(for: .denied, sheet: sheet),
                "Camera access is off. Turn it on in Settings to scan.")
        }
        XCTAssertTrue(CameraAccessNotice.offersOpenSettings(for: .denied))
    }

    func testRestrictedAccessIsTheSameAsDenied() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .restricted, sheet: .barcode), CameraAccessNotice.accessOffMessage)
        XCTAssertTrue(CameraAccessNotice.offersOpenSettings(for: .restricted))
    }

    func testBarcodeSheetKeepsItsTypeInFallback() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .authorized, sheet: .barcode),
            "The camera could not be started. Type the digits instead.")
        XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: .authorized))
    }

    func testLabelSheetKeepsItsValuesFallback() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .notDetermined, sheet: .label),
            "The camera could not be started. Type the values in instead.")
        XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: .notDetermined))
    }
}
