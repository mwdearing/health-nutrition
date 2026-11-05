import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeDoubleSaveTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testSavingTwiceOnOneDraftWritesOneEntry() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now)
        model.name = "Example snack"
        model.amountText = "50"
        model.unit = .g
        XCTAssertTrue(model.save(now: now))
        XCTAssertFalse(model.save(now: now))
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertTrue(model.hasSaved)
    }

    func testAFailedSaveDoesNotLockTheDraft() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        XCTAssertFalse(model.save(now: now))
        XCTAssertFalse(model.hasSaved)
        model.name = "Example snack"
        model.amountText = "50"
        model.unit = .g
        XCTAssertTrue(model.save(now: now))
    }
}
