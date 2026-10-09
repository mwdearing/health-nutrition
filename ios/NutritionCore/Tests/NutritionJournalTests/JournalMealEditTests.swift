import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Changing the meal of an existing entry at the store: one new revision that keeps the components and the
/// product snapshot, the intake's own meal moved with it, and the queued work superseded like any edit.
/// Synthetic data only.
final class JournalMealEditTests: XCTestCase {
    private let intakeID = "2f6c1e0a-7b3d-4e8f-9a51-6c2d4b8e7f10"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func oats() -> IntakeComponent {
        IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)
    }

    private func product() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "meal-edit-snapshot", productID: "example-product", name: "Example oats",
            labelBasis: "per 100 g", catalogOrigin: "example-catalog", catalogVersion: "1")
    }

    /// One entry logged at breakfast with a product snapshot, so the change has something to keep.
    private func logBreakfast(_ store: SwiftDataJournalStore) throws {
        try store.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [oats()], product: product(), now: when)
    }

    func testChangingTheMealWritesRevisionNPlusOneWithTheMealChangedReason() throws {
        let store = try makeStore()
        try logBreakfast(store)
        let revision = try XCTUnwrap(try store.changeMeal(intakeID: intakeID, meal: "dinner", now: when))
        XCTAssertEqual(revision.number, 2)
        XCTAssertEqual(revision.changeReason, "Meal changed")
        XCTAssertEqual(try store.activeIntakes().first?.currentRevision, 2)
        XCTAssertEqual(try store.activeIntakes().first?.meal, "dinner")
        let revisions = try store.revisions(of: intakeID)
        XCTAssertEqual(revisions.map(\.number), [1, 2])
        XCTAssertEqual(revisions.map(\.changeReason), ["created", "Meal changed"])
    }

    func testChangingTheMealKeepsTheComponentsAndTheProductSnapshot() throws {
        let store = try makeStore()
        try logBreakfast(store)
        try store.changeMeal(intakeID: intakeID, meal: "snack", now: when)
        let revisions = try store.revisions(of: intakeID)
        let first = try XCTUnwrap(revisions.first)
        let second = try XCTUnwrap(revisions.last)
        XCTAssertEqual(second.components, first.components)
        XCTAssertEqual(second.productSnapshotID, "meal-edit-snapshot")
        XCTAssertEqual(try store.product(snapshotID: "meal-edit-snapshot")?.name, "Example oats")
    }

    func testChangingTheMealSupersedesTheOldProjectionsAndQueuesNewWork() throws {
        let store = try makeStore()
        try logBreakfast(store)
        let before = try store.pendingOutbox().count
        try store.changeMeal(intakeID: intakeID, meal: "lunch", now: when)
        let projections = try store.projections(of: intakeID)
        XCTAssertTrue(projections.filter { $0.revision == 1 }.allSatisfy { !$0.isCurrent })
        XCTAssertEqual(projections.filter { $0.revision == 2 && $0.isCurrent }.count, 2)
        let pending = try store.pendingOutbox()
        XCTAssertEqual(pending.count, before + 2)
        XCTAssertEqual(pending.filter { $0.revision == 2 && $0.kind == .upsert }.count, 2)
    }

    func testChangingToTheSameMealReturnsNilAndWritesNothing() throws {
        let store = try makeStore()
        try logBreakfast(store)
        let before = try store.pendingOutbox().count
        let result = try store.changeMeal(intakeID: intakeID, meal: "breakfast", now: when)
        XCTAssertNil(result)
        XCTAssertEqual(try store.activeIntakes().first?.currentRevision, 1)
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
        XCTAssertEqual(try store.pendingOutbox().count, before)
    }

    func testSettingNilClearsTheMeal() throws {
        let store = try makeStore()
        try logBreakfast(store)
        let revision = try XCTUnwrap(try store.changeMeal(intakeID: intakeID, meal: nil, now: when))
        XCTAssertEqual(revision.changeReason, "Meal changed")
        XCTAssertNil(try store.activeIntakes().first?.meal)
        XCTAssertEqual(try store.revisions(of: intakeID).count, 2)
    }

    func testADeletedEntryIsRefusedEvenForTheSameMeal() throws {
        let store = try makeStore()
        try logBreakfast(store)
        try store.delete(intakeID: intakeID, now: when)
        XCTAssertThrowsError(try store.changeMeal(intakeID: intakeID, meal: "dinner", now: when)) { error in
            XCTAssertEqual(error as? JournalError, .intakeDeleted(intakeID))
        }
        XCTAssertThrowsError(try store.changeMeal(intakeID: intakeID, meal: "breakfast", now: when)) { error in
            XCTAssertEqual(error as? JournalError, .intakeDeleted(intakeID))
        }
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
    }

    func testAnUnknownEntryIsRefused() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.changeMeal(intakeID: intakeID, meal: "dinner", now: when)) { error in
            XCTAssertEqual(error as? JournalError, .unknownIntake(intakeID))
        }
    }

    func testTheExportCarriesTheNewMealAndTheExtraRevision() throws {
        let store = try makeStore()
        try logBreakfast(store)
        try store.changeMeal(intakeID: intakeID, meal: "dinner", now: when)
        let document = try JournalExporter.makeExport(store: store, appVersion: "0.1.0", exportedAt: when)
        let intake = try XCTUnwrap(document.intakes.first { $0.id == intakeID })
        XCTAssertEqual(intake.meal, "dinner")
        XCTAssertEqual(intake.currentRevision, 2)
        XCTAssertEqual(intake.revisions.map(\.changeReason), ["created", "Meal changed"])
    }
}
