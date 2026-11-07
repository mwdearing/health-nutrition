import XCTest
@testable import NutritionUI

/// The save sentence names the sharing toggle as the Account screen shows it. Pinned as a literal (#516).
final class ShareToggleCopyTests: XCTestCase {
    func testTheSaveSentenceNamesTheToggleAsItAppearsOnAccount() {
        XCTAssertEqual(
            AddIntakeViewModel.communityShareSentence,
            "Share products with the community is on, so saving this label also sends its product name, brand, barcode, serving text and nutrient amounts to the community catalog.")
    }
}
