import NutritionUI
import XCTest

/// The Save to Library switch has no accessibility hint: its label says what it does (#527).
final class SaveToLibraryHintTests: XCTestCase {
    func testSaveToLibrarySwitchHasNoHint() {
        XCTAssertNil(SaveToLibraryAccessibility.hint)
        XCTAssertEqual(SaveToLibraryAccessibility.label, "Save to Library")
    }
}
