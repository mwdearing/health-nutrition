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

    func testRestrictedHasItsOwnCopyAndNoSettingsButton() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .restricted, sheet: .barcode),
            "Camera access is restricted on this phone. Type the digits instead.")
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .restricted, sheet: .label),
            "Camera access is restricted on this phone.")
        XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: .restricted))
    }

    func testAuthorizedAndNotDeterminedKeepStartFailureCopy() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .authorized, sheet: .barcode),
            "The camera could not be started. Type the digits instead.")
        XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: .authorized))
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .notDetermined, sheet: .label),
            "The camera could not be started.")
        XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: .notDetermined))
    }

    func testUnsupportedDeviceWinsOverEveryAccessState() {
        for access in [CameraAccessState.authorized, .notDetermined, .denied, .restricted] {
            XCTAssertEqual(
                CameraAccessNotice.unavailableMessage(isSupported: false, access: access, isAvailable: false, sheet: .barcode),
                "This device cannot scan barcodes. Type the digits instead.")
            XCTAssertEqual(
                CameraAccessNotice.unavailableMessage(isSupported: false, access: access, isAvailable: true, sheet: .label),
                "This device cannot read text with the camera.")
        }
    }

    func testDeniedWithScannerUnavailableStillShowsAccessOff() {
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .denied, isAvailable: false, sheet: .barcode),
            "Camera access is off. Turn it on in Settings to scan, or type the digits instead.")
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .denied, isAvailable: false, sheet: .label),
            "Camera access is off. Turn it on in Settings to scan.")
    }

    func testDeniedWithScannerAvailableStillShowsAccessOff() {
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .denied, isAvailable: true, sheet: .label),
            "Camera access is off. Turn it on in Settings to scan.")
    }

    func testRestrictedWithScannerUnavailableShowsRestricted() {
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .restricted, isAvailable: false, sheet: .label),
            "Camera access is restricted on this phone.")
    }

    func testAuthorizedWithScannerUnavailableShowsStartFailure() {
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .authorized, isAvailable: false, sheet: .barcode),
            "The camera could not be started. Type the digits instead.")
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .authorized, isAvailable: false, sheet: .label),
            "The camera could not be started.")
    }

    func testNotDeterminedWithScannerUnavailableShowsStartFailure() {
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .notDetermined, isAvailable: false, sheet: .label),
            "The camera could not be started.")
    }

    func testReadyCameraHasNoMessage() {
        XCTAssertNil(CameraAccessNotice.unavailableMessage(isSupported: true, access: .authorized, isAvailable: true, sheet: .barcode))
        XCTAssertNil(CameraAccessNotice.unavailableMessage(isSupported: true, access: .notDetermined, isAvailable: true, sheet: .label))
    }

    func testRestrictedWithScannerAvailableShowsRestricted() {
        XCTAssertEqual(
            CameraAccessNotice.unavailableMessage(isSupported: true, access: .restricted, isAvailable: true, sheet: .barcode),
            "Camera access is restricted on this phone. Type the digits instead.")
    }

    func testStoppedMidSessionShowsAccessOffOnlyWhenAccessIsOff() {
        XCTAssertEqual(
            CameraAccessNotice.stoppedMessage(access: .denied, sheet: .barcode, fallback: "Scanning stopped."),
            "Camera access is off. Turn it on in Settings to scan, or type the digits instead.")
        XCTAssertEqual(
            CameraAccessNotice.stoppedMessage(access: .restricted, sheet: .label, fallback: "The camera stopped."),
            "Camera access is restricted on this phone.")
        XCTAssertEqual(
            CameraAccessNotice.stoppedMessage(access: .authorized, sheet: .label, fallback: "The camera stopped."),
            "The camera stopped.")
    }

    func testReturningWithAccessAllowedClearsTheFailureOnBothSheets() {
        XCTAssertNil(CameraAccessNotice.messageAfterReturn(access: .authorized, sheet: .barcode))
        XCTAssertNil(CameraAccessNotice.messageAfterReturn(access: .authorized, sheet: .label))
    }

    func testReturningWithAccessStillOffKeepsTheMessageForEachSheet() {
        XCTAssertEqual(
            CameraAccessNotice.messageAfterReturn(access: .denied, sheet: .barcode),
            "Camera access is off. Turn it on in Settings to scan, or type the digits instead.")
        XCTAssertEqual(
            CameraAccessNotice.messageAfterReturn(access: .denied, sheet: .label),
            "Camera access is off. Turn it on in Settings to scan.")
        XCTAssertEqual(
            CameraAccessNotice.messageAfterReturn(access: .restricted, sheet: .label),
            "Camera access is restricted on this phone.")
    }

    func testReturningWhileUndeterminedShowsTheStartFailure() {
        XCTAssertEqual(
            CameraAccessNotice.messageAfterReturn(access: .notDetermined, sheet: .barcode),
            "The camera could not be started. Type the digits instead.")
    }
}
