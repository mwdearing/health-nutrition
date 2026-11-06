import XCTest
@testable import NutritionUI

/// Choosing the separated Add tab opens Add and leaves the tab that was showing selected.
final class AddTabSelectionTests: XCTestCase {
    private enum Screen: Hashable { case today, diary, library, add }

    func testChoosingAContentTabSelectsIt() {
        let outcome = AddTabSelection.resolve(requested: Screen.library, current: Screen.today, add: Screen.add)
        XCTAssertEqual(outcome, AddTabSelection.Outcome(selection: Screen.library, opensAdd: false))
    }

    func testChoosingAddOpensAddAndKeepsTheShownTab() {
        let outcome = AddTabSelection.resolve(requested: Screen.add, current: Screen.diary, add: Screen.add)
        XCTAssertEqual(outcome, AddTabSelection.Outcome(selection: Screen.diary, opensAdd: true))
    }

    func testChoosingTheShownTabAgainChangesNothing() {
        let outcome = AddTabSelection.resolve(requested: Screen.today, current: Screen.today, add: Screen.add)
        XCTAssertEqual(outcome, AddTabSelection.Outcome(selection: Screen.today, opensAdd: false))
    }
}
