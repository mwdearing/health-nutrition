import XCTest
@testable import NutritionUI

/// The Medication log states, on its own screen and beside its Settings switch, that it keeps what the person
/// enters and gives no medical advice and no dose suggestions.
@MainActor
final class MedicationLogNoticeTests: XCTestCase {
    func testTheNoticeSaysTheLogGivesNoAdviceAndSuggestsNoDose() {
        XCTAssertEqual(
            MedicationLogViewModel.notice,
            "This log keeps what you enter. It does not give medical advice or suggest doses."
        )
    }

    func testTheNoticeNamesNoScoreOrGrade() {
        let notice = MedicationLogViewModel.notice.lowercased()
        for word in ["score", "grade", "on track", "missed", "should"] {
            XCTAssertFalse(notice.contains(word), word)
        }
    }
}
