import XCTest
@testable import NutritionUI

final class SaveConfirmationTests: XCTestCase {
    /// Each save makes a new notice, so a second save in a row confirms again even with the same wording.
    func testEachSaveIsANewNotice() {
        let first = SaveNotice(SaveLabels.productSaved)
        let second = SaveNotice(SaveLabels.productSaved)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, first)
    }

    func testEveryConfirmationHasWording() {
        let labels = [
            SaveLabels.productSaved, SaveLabels.entrySaved, SaveLabels.loggedToDiary, SaveLabels.recipeSaved,
            SaveLabels.mealSaved, SaveLabels.goalsSaved, SaveLabels.scheduleSaved, SaveLabels.nutrientSaved,
        ]
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }
}
