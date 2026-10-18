import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The unit forgotten for a changed amount goes in the same commit as the edit, so a failed edit leaves it.
final class EditRemovingUnitsTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("edit.store"))
    }

    /// An edit refused before any change (here, a deleted entry) leaves its unit rows where they were.
    /// The removals run last, after every step that can throw, so a failure anywhere earlier keeps them.
    func testAnEditRefusedBeforeAnyChangeLeavesTheUnitRows() throws {
        let store = try makeStore()
        let id = "00000000-0000-4000-8000-0000000000c1"
        try store.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "fiber", name: "Fiber", amount: 5, unit: .mL)],
            product: nil, now: when)
        try store.recordLoggedUnit(JournalLoggedUnit(intakeID: id, componentID: "fiber", unit: .teaspoon))
        try store.delete(intakeID: id, now: when)

        // The entry is deleted, so the edit fails inside its commit; the unit it asked to forget must survive.
        XCTAssertThrowsError(try store.editRemovingUnits(
            intakeID: id,
            components: [IntakeComponent(componentID: "fiber", name: "Fiber", amount: 7, unit: .mL)],
            product: nil, changeReason: "Amount changed", now: when, occurredAt: nil, timeZoneIdentifier: nil,
            unitRemovals: ["fiber"]))
        XCTAssertEqual(try store.loggedUnits().map(\.unit), [.teaspoon])
    }

    func testASuccessfulEditForgetsTheUnitOfTheChangedComponentOnly() throws {
        let store = try makeStore()
        let id = "00000000-0000-4000-8000-0000000000c2"
        try store.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [
                IntakeComponent(componentID: "fiber", name: "Fiber", amount: 5, unit: .mL),
                IntakeComponent(componentID: "protein", name: "Protein", amount: 3, unit: .mL),
            ],
            product: nil, now: when)
        try store.recordLoggedUnit(JournalLoggedUnit(intakeID: id, componentID: "fiber", unit: .teaspoon))
        try store.recordLoggedUnit(JournalLoggedUnit(intakeID: id, componentID: "protein", unit: .teaspoon))

        try store.editRemovingUnits(
            intakeID: id,
            components: [
                IntakeComponent(componentID: "fiber", name: "Fiber", amount: 7, unit: .mL),
                IntakeComponent(componentID: "protein", name: "Protein", amount: 3, unit: .mL),
            ],
            product: nil, changeReason: "Amount changed", now: when, occurredAt: nil, timeZoneIdentifier: nil,
            unitRemovals: ["fiber"])
        XCTAssertEqual(try store.loggedUnits().map(\.componentID), ["protein"])
    }
}
