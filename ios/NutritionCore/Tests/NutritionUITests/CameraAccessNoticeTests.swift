import XCTest
@testable import NutritionUI

final class CameraAccessNoticeTests: XCTestCase {
    func testBarcodeAccessOffAlsoOffersTyping() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .denied, sheet: .barcode),
            "Camera access is off. Turn it on in Settings to scan, or type the digits instead.")
        XCTAssertTrue(CameraAccessNotice.offersOpenSettings(for: .denied))
    }

    func testLabelAccessOffSaysToTurnItOnInSettings() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .denied, sheet: .label),
            "Camera access is off. Turn it on in Settings to scan.")
        XCTAssertTrue(CameraAccessNotice.offersOpenSettings(for: .denied))
    }

    func testRestrictedAccessIsTheSameAsDeniedPerSheet() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .restricted, sheet: .barcode),
            CameraAccessNotice.barcodeAccessOffMessage)
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .restricted, sheet: .label),
            CameraAccessNotice.labelAccessOffMessage)
        XCTAssertTrue(CameraAccessNotice.offersOpenSettings(for: .restricted))
    }

    func testBarcodeSheetKeepsItsTypeInFallback() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .authorized, sheet: .barcode),
            "The camera could not be started. Type the digits instead.")
        XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: .authorized))
    }

    func testLabelSheetStartFailureUsesPlainCopy() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .notDetermined, sheet: .label),
            "The camera could not be started.")
        XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: .notDetermined))
    }
}
