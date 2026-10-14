import XCTest

@testable import HealthNutrition

final class LogWaterShortcutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testASuccessfulWriteIsReportedAsLogged() {
        var writtenAt: Date?
        let outcome = WaterShortcut.log(now: now) { date in
            writtenAt = date
            return true
        }
        XCTAssertEqual(writtenAt, now)
        XCTAssertEqual(outcome, .init(logged: true, message: WaterShortcut.loggedMessage))
    }

    func testAFailedWriteIsNotReportedAsLogged() {
        let outcome = WaterShortcut.log(now: now) { _ in false }
        XCTAssertEqual(outcome, .init(logged: false, message: WaterShortcut.failedMessage))
    }

    func testMissingServicesSaysToOpenTheAppAndWritesNothing() {
        var wrote = false
        let outcome = WaterShortcut.log(now: now) { _ in nil }
        XCTAssertFalse(wrote)
        wrote = outcome.logged
        XCTAssertFalse(wrote)
        XCTAssertEqual(outcome.message, WaterShortcut.notReadyMessage)
    }
}
