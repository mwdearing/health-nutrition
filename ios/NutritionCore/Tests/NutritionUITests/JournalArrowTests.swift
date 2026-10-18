import Foundation
import XCTest
@testable import NutritionUI

final class JournalArrowTests: XCTestCase {
    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The list is newest first. With the two older days on screen, the arrows start from the newer of them.
    func testArrowsStepFromTheTopVisibleDay() throws {
        let base = JournalViewModel.arrowBaseDay(
            sectionIDs: ["2026-10-14", "2026-10-13", "2026-10-12"],
            visible: ["2026-10-13", "2026-10-12"],
            zone: .current,
            now: Date())
        XCTAssertEqual(dayKey(base), "2026-10-13")
    }

    /// Nothing on screen yet (the list has not appeared), so the arrows start from now.
    func testFallsBackToNowWhenNothingIsVisible() throws {
        let now = Date()
        let base = JournalViewModel.arrowBaseDay(sectionIDs: ["2026-10-14"], visible: [], zone: .current, now: now)
        XCTAssertEqual(base, now)
    }
}
