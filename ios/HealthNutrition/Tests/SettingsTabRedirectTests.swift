import XCTest

@testable import HealthNutrition

final class SettingsTabRedirectTests: XCTestCase {
    private enum Tab { case today, diary, library, settings }

    private func resolve(_ previous: Tab, _ current: Tab) -> SettingsTabRedirect<Tab>.Outcome {
        SettingsTabRedirect.resolve(previous: previous, current: current, settings: .settings, fallback: .today)
    }

    func testChoosingSettingsOpensTheSheetAndReturnsToThePreviousTab() {
        XCTAssertEqual(resolve(.diary, .settings), .init(selection: .diary, opensSettings: true))
        XCTAssertEqual(resolve(.library, .settings), .init(selection: .library, opensSettings: true))
    }

    func testChoosingAnotherTabIsLeftAlone() {
        XCTAssertEqual(resolve(.today, .diary), .init(selection: .diary, opensSettings: false))
    }

    func testSettingsIsNeverLeftSelected() {
        XCTAssertEqual(resolve(.settings, .settings), .init(selection: .today, opensSettings: true))
    }
}
