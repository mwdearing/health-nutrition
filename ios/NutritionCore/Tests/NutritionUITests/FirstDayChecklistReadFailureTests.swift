import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A failed read on the first-day checklist hides the card until a read succeeds: no empty state, no 0 and no
/// guessed done state (#775).
@MainActor
final class FirstDayChecklistReadFailureTests: XCTestCase {
    private func makeJournal() throws -> UnitReadFailingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        return UnitReadFailingStore(inner: inner)
    }

    /// The journal read throws: the card must not show the log step as not done.
    func testChecklistHidesWhenTheJournalReadFails() throws {
        let journal = try makeJournal()
        journal.failsActiveIntakes = true
        let model = FirstDayChecklistModel(
            store: journal, goals: InMemoryGoalStore(), preferences: InMemoryDisplayPreferences())

        model.load()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isVisible)
    }

    /// The goal read throws: the card must not show the goal step as not done.
    func testChecklistHidesWhenTheGoalReadFails() throws {
        let goals = InMemoryGoalStore(failNextRead: true)
        let model = FirstDayChecklistModel(
            store: try makeJournal(), goals: goals, preferences: InMemoryDisplayPreferences())

        model.load()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isVisible)
    }

    /// A failed read does not stick: once the journal reads again, the next load shows the card with its rows.
    func testChecklistShowsAgainWhenTheJournalReadRecovers() throws {
        let journal = try makeJournal()
        journal.failsActiveIntakes = true
        let model = FirstDayChecklistModel(
            store: journal, goals: InMemoryGoalStore(), preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertFalse(model.isVisible)

        journal.failsActiveIntakes = false
        model.load()

        XCTAssertEqual(model.items.map(\.kind), [.logFirst, .setGoal, .chooseUnits])
        XCTAssertTrue(model.isVisible)
    }

    /// A failed reload after a good load clears the rows already on screen, not just the first load's empty state.
    func testChecklistClearsItsRowsWhenAReloadFailsAfterAGoodLoad() throws {
        let journal = try makeJournal()
        let model = FirstDayChecklistModel(
            store: journal, goals: InMemoryGoalStore(), preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.items.count, 3)
        XCTAssertTrue(model.isVisible)

        journal.failsActiveIntakes = true
        model.load()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isVisible)
    }
}
