import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Each read of the logged units that feeds a total or a write reports a failed read and shows nothing in its
/// place, rather than an empty index that would count amounts in the wrong unit (#415).
@MainActor
final class UnitReadFailureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> UnitReadFailingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        return UnitReadFailingStore(inner: inner)
    }

    /// Today's totals read the logged units first; a failed read shows no totals and says the journal is unreadable.
    func testTodayShowsNoTotalsWhenTheUnitReadFails() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.errorMessage, "Could not read the journal.")
        XCTAssertTrue(model.progress.isEmpty)
    }

    /// The journal's day reads the logged units with its entries; a failed read shows no day.
    func testJournalShowsNoDayWhenTheUnitReadFails() throws {
        let model = JournalViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.errorMessage, "Could not read the journal.")
        XCTAssertNil(model.todaySection)
    }
}
