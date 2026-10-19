import XCTest
@testable import NutritionUI

final class CameraAccessNoticeTests: XCTestCase {
    func testDeniedAccessSaysToTurnItOnInSettings() {
        XCTAssertEqual(
            CameraAccessNotice.failureMessage(for: .denied),
            "Camera access is off. Turn it on in Settings to scan.")
        XCTAssertTrue(CameraAccessNotice.offersOpenSettings(for: .denied))
    }

    func testRestrictedAccessIsTheSameAsDenied() {
        XCTAssertEqual(CameraAccessNotice.failureMessage(for: .restricted), CameraAccessNotice.accessOffMessage)
        XCTAssertTrue(CameraAccessNotice.offersOpenSettings(for: .restricted))
    }

    func testOtherFailuresKeepTheirMessageAndNoSettingsButton() {
        for access in [CameraAccessState.authorized, .notDetermined] {
            XCTAssertEqual(CameraAccessNotice.failureMessage(for: access), CameraAccessNotice.startFailureMessage)
            XCTAssertFalse(CameraAccessNotice.offersOpenSettings(for: access))
        }
    }
}
