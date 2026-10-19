import Foundation
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeDirtyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeModel() throws -> AddIntakeViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        return AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC", lookup: nil,
            preferences: InMemoryDisplayPreferences(unitSystem: .usCustomary),
            countDecimalSeparator: ".")
    }

    func testFreshFormHasNoTypedInput() throws {
        XCTAssertFalse(try makeModel().hasTypedInput)
    }

    func testTypingAFoodNameCountsAsTypedInput() throws {
        let model = try makeModel()
        model.name = "Oat milk"
        XCTAssertTrue(model.hasTypedInput)
    }

    func testWhitespaceOnlyNameIsNotTypedInput() throws {
        let model = try makeModel()
        model.name = "   "
        XCTAssertFalse(model.hasTypedInput)
    }
}
