import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// An edit made against a revision the caller read is refused when the entry has moved on since, so a newer
/// revision the person never saw is not overwritten last-writer-wins.
final class StaleRevisionEditTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = "00000000-0000-4000-8000-0000000004a1"

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("stale.store"))
    }

    private func fiber(_ amount: Decimal) -> [IntakeComponent] {
        [IntakeComponent(componentID: "fiber", name: "Fiber", amount: amount, unit: .mL)]
    }

    /// Creates the entry at revision 1, then a second edit moves it to revision 2.
    private func entryAtRevisionTwo(_ store: SwiftDataJournalStore) throws {
        try store.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: fiber(5), product: nil, now: when)
        try store.edit(
            intakeID: id, components: fiber(6), product: nil, changeReason: "Amount changed", now: when,
            occurredAt: nil, timeZoneIdentifier: nil)
        XCTAssertEqual(try store.revisions(of: id).map(\.number), [1, 2])
    }

    func testAnEditAgainstAnOlderRevisionIsRefusedAndWritesNothing() throws {
        let store = try makeStore()
        try entryAtRevisionTwo(store)

        XCTAssertThrowsError(try store.edit(
            intakeID: id, components: fiber(9), product: nil, changeReason: "Amount changed", now: when,
            occurredAt: nil, timeZoneIdentifier: nil, expectedRevision: 1)
        ) { error in
            XCTAssertEqual(error as? JournalError, .staleRevision(self.id))
        }
        XCTAssertEqual(try store.revisions(of: id).map(\.number), [1, 2])
        XCTAssertEqual(try store.revisions(of: id).last?.components.first?.amount, 6)
    }

    func testAnEditAgainstTheCurrentRevisionIsWritten() throws {
        let store = try makeStore()
        try entryAtRevisionTwo(store)

        let revision = try store.edit(
            intakeID: id, components: fiber(9), product: nil, changeReason: "Amount changed", now: when,
            occurredAt: nil, timeZoneIdentifier: nil, expectedRevision: 2)
        XCTAssertEqual(revision.number, 3)
        XCTAssertEqual(try store.revisions(of: id).last?.components.first?.amount, 9)
    }

    /// Called through the protocol, as the entry editor calls it, the store's own check runs: a stale edit is refused
    /// and the entry keeps its revision.
    func testThroughTheProtocolAStaleEditIsRefused() throws {
        let store = try makeStore()
        try entryAtRevisionTwo(store)
        let journal: any JournalStore = store

        XCTAssertThrowsError(try journal.editRemovingUnits(
            intakeID: id, components: fiber(9), product: nil, changeReason: "Amount changed", now: when,
            occurredAt: nil, timeZoneIdentifier: nil, unitRemovals: [], expectedRevision: 1)
        ) { error in
            XCTAssertEqual(error as? JournalError, .staleRevision(self.id))
        }
        XCTAssertEqual(try store.revisions(of: id).map(\.number), [1, 2])
    }

    /// The unit removal goes with the edit, so a refused edit forgets no unit either.
    func testAnEditRemovingUnitsAgainstAnOlderRevisionIsRefusedAndKeepsTheUnits() throws {
        let store = try makeStore()
        try entryAtRevisionTwo(store)
        try store.recordLoggedUnit(JournalLoggedUnit(intakeID: id, componentID: "fiber", unit: .teaspoon))

        XCTAssertThrowsError(try store.editRemovingUnits(
            intakeID: id, components: fiber(9), product: nil, changeReason: "Amount changed", now: when,
            occurredAt: nil, timeZoneIdentifier: nil, unitRemovals: ["fiber"], expectedRevision: 1)
        ) { error in
            XCTAssertEqual(error as? JournalError, .staleRevision(self.id))
        }
        XCTAssertEqual(try store.revisions(of: id).map(\.number), [1, 2])
        XCTAssertEqual(try store.loggedUnits().map(\.unit), [.teaspoon])
    }
}
