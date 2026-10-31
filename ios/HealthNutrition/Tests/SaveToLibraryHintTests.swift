import NutritionUI
import XCTest

/// The Save to Library switch has no accessibility hint: its label says what it does (#527).
final class SaveToLibraryHintTests: XCTestCase {
    func testSaveToLibrarySwitchHasNoHint() {
        XCTAssertNil(SaveToLibraryAccessibility.hint)
        XCTAssertEqual(SaveToLibraryAccessibility.label, "Save to Library")
    }

    /// A nil hint must come back as nil, not as an empty string that would still be applied (#644).
    func testAMissingHintIsNilNotEmpty() {
        XCTAssertNil(SaveToLibraryHint.hint(for: nil))
        XCTAssertNil(SaveToLibraryHint.hint(for: ""))
    }

    func testAPresentHintPassesThroughUnchanged() {
        XCTAssertEqual(SaveToLibraryHint.hint(for: "Adds to Library"), "Adds to Library")
    }
}
