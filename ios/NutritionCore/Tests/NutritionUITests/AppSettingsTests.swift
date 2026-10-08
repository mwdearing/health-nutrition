import XCTest
@testable import NutritionUI

/// The interim Settings list: the placeholder rows are present, named, and never available.
final class AppSettingsTests: XCTestCase {
    func testSettingsPlaceholderRowsAreNamedAsTheDesignListsThem() {
        XCTAssertEqual(
            SettingsPlaceholder.allCases.map(\.title),
            ["Daily prompts", "Apple Health", "HealthRelay", "Community sharing", "Keep history for"])
    }

    func testSettingsPlaceholderRowsAreNeverAvailable() {
        for placeholder in SettingsPlaceholder.allCases {
            XCTAssertFalse(placeholder.isAvailable, placeholder.title)
            XCTAssertFalse(placeholder.detail.isEmpty, placeholder.title)
        }
    }
}
