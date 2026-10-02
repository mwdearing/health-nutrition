import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

final class JournalStoreTests: XCTestCase {
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func storeURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("journal.store")
    }

    private func makeStore(
        _ directory: URL, enabled: Set<JournalDestination> = [.healthKit, .relay]
    ) throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: storeURL(directory), enabledDestinations: enabled)
    }

    private func sampleIntake(id: String? = nil) -> Intake {
        Intake(id: id ?? intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast")
    }

    private func oats(_ grams: Decimal = 40) -> IntakeComponent {
        IntakeComponent(componentID: "oats", name: "Rolled oats", amount: grams, unit: .g)
    }

    private func product(_ snapshotID: String, name: String) -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshotID, productID: "product-1", name: name, brand: "Sample Brand",
            barcode: "00000000", labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1")
    }

    func testReopenAfterCommitKeepsIntakeRevisionAndOutbox() throws {
        let directory = try makeDirectory()
        let first = try makeStore(directory)
        try first.create(sampleIntake(), components: [oats()], product: nil, now: when)
        first.close()
        let second = try makeStore(directory)
        XCTAssertEqual(try second.activeIntakes().map(\.id), [intakeID])
        XCTAssertEqual(try second.revisions(of: intakeID).count, 1)
        XCTAssertEqual(try second.pendingOutbox().count, 2)
        XCTAssertEqual(try second.projections(of: intakeID).count, 2)
    }

    func testEditCreatesNewRevisionThatSupersedesTheOld() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
        let second = try store.edit(
            intakeID: intakeID, components: [oats(55)], product: nil, changeReason: "bigger bowl", now: when)
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(try store.activeIntakes().first?.currentRevision, 2)
        let revisions = try store.revisions(of: intakeID)
        XCTAssertEqual(revisions.map(\.number), [1, 2])
        XCTAssertEqual(revisions[0].components[0].amount, 40)
        XCTAssertEqual(revisions[1].components[0].amount, 55)
        let projections = try store.projections(of: intakeID)
        XCTAssertEqual(projections.filter { $0.revision == 1 }.map(\.isCurrent), [false, false])
        XCTAssertEqual(projections.filter { $0.revision == 2 }.map(\.isCurrent), [true, true])
        XCTAssertEqual(try store.pendingOutbox().count, 4)
    }

    func testDeleteHidesIntakeQueuesDeleteOperationsAndKeepsHistory() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
        let deletes = try store.pendingOutbox().filter { $0.kind == .delete }
        XCTAssertEqual(Set(deletes.map(\.destination)), [.healthKit, .relay])
        XCTAssertTrue(deletes.allSatisfy { $0.revision == 1 })
        let current = try store.projections(of: intakeID).filter(\.isCurrent)
        XCTAssertTrue(current.allSatisfy { $0.desiredAction == .delete && $0.state == .pending })
        XCTAssertThrowsError(try store.edit(
            intakeID: intakeID, components: [oats()], product: nil, changeReason: "late", now: when))
    }

    func testFailedSaveRollsBackRevisionAndOutboxOnCreate() throws {
        let store = try makeStore(try makeDirectory())
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.create(sampleIntake(), components: [oats()], product: nil, now: when)) {
            XCTAssertEqual($0 as? JournalError, .injectedSaveFailure)
        }
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.revisions(of: intakeID).isEmpty)
        XCTAssertTrue(try store.projections(of: intakeID).isEmpty)
        XCTAssertTrue(try store.pendingOutbox().isEmpty)
        XCTAssertNil(try store.product(snapshotID: "snap-1"))
    }

    func testFailedSaveRollsBackEditAndLeavesEarlierStateIntact() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.edit(
            intakeID: intakeID, components: [oats(99)], product: nil, changeReason: "x", now: when))
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
        XCTAssertEqual(try store.activeIntakes().first?.currentRevision, 1)
        XCTAssertEqual(try store.pendingOutbox().count, 2)
        XCTAssertTrue(try store.projections(of: intakeID).allSatisfy(\.isCurrent))
        // The flag applies once; the next write succeeds.
        let retry = try store.edit(
            intakeID: intakeID, components: [oats(99)], product: nil, changeReason: "x", now: when)
        XCTAssertEqual(retry.number, 2)
    }

    func testFailedSaveRollsBackDelete() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.delete(intakeID: intakeID, now: when))
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertTrue(try store.pendingOutbox().allSatisfy { $0.kind == .upsert })
    }

    func testProductSnapshotStaysImmutableAcrossEdit() throws {
        let store = try makeStore(try makeDirectory())
        let old = product("snap-1", name: "Oats original")
        let renamed = product("snap-2", name: "Oats new recipe")
        try store.create(sampleIntake(), components: [oats()], product: old, now: when)
        try store.edit(intakeID: intakeID, components: [oats()], product: renamed, changeReason: "new product", now: when)
        let revisions = try store.revisions(of: intakeID)
        XCTAssertEqual(revisions[0].productSnapshotID, "snap-1")
        XCTAssertEqual(revisions[1].productSnapshotID, "snap-2")
        XCTAssertEqual(try store.product(snapshotID: "snap-1"), old)
        XCTAssertEqual(try store.product(snapshotID: "snap-2"), renamed)
    }

    func testProductSnapshotIDCannotBeReusedWithDifferentContent() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: product("snap-1", name: "A"), now: when)
        XCTAssertThrowsError(try store.edit(
            intakeID: intakeID, components: [oats()], product: product("snap-1", name: "B"),
            changeReason: "x", now: when)) {
            XCTAssertEqual($0 as? JournalError, .snapshotConflict("snap-1"))
        }
        XCTAssertEqual(try store.product(snapshotID: "snap-1")?.name, "A")
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
    }

    func testRevisionNumbersStartAtOneAndGrowByOne() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats(1)], product: nil, now: when)
        for grams in 2...4 {
            let revision = try store.edit(
                intakeID: intakeID, components: [oats(Decimal(grams))], product: nil, changeReason: "e", now: when)
            XCTAssertEqual(revision.number, grams)
        }
        XCTAssertEqual(try store.revisions(of: intakeID).map(\.number), [1, 2, 3, 4])
    }

    func testComponentIDValidationFollowsTheSlugPattern() {
        for good in ["a", "0", "vitamin-d3", "omega.3_mix", String(repeating: "a", count: 64)] {
            XCTAssertTrue(JournalValidation.isValidComponentID(good), good)
        }
        for bad in ["", "-a", ".a", "_a", "A", "a b", "a\n", "a/b", "é", String(repeating: "a", count: 65)] {
            XCTAssertFalse(JournalValidation.isValidComponentID(bad), bad)
        }
    }

    func testStoreRejectsInvalidAndDuplicateComponentIDsWithoutWriting() throws {
        let store = try makeStore(try makeDirectory())
        let bad = IntakeComponent(componentID: "Bad Id", name: "x", amount: 1, unit: .g)
        XCTAssertThrowsError(try store.create(sampleIntake(), components: [bad], product: nil, now: when))
        XCTAssertThrowsError(try store.create(sampleIntake(), components: [oats(), oats()], product: nil, now: when))
        XCTAssertThrowsError(try store.create(
            sampleIntake(id: "NOT-A-UUID"), components: [oats()], product: nil, now: when))
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().isEmpty)
    }

    func testDecimalAmountsRoundTripExactlyThroughReopen() throws {
        let directory = try makeDirectory()
        let amounts: [Decimal] = [
            Decimal(string: "0.1")!, Decimal(string: "125.50")!, Decimal(string: "0.1234567890123456789")!,
            Decimal(string: "1000000.000001")!, 0,
        ]
        let components = amounts.enumerated().map {
            IntakeComponent(componentID: "c\($0.offset)", name: "n", amount: $0.element, unit: .mg)
        }
        let first = try makeStore(directory)
        try first.create(sampleIntake(), components: components, product: nil, now: when)
        first.close()
        let reopened = try makeStore(directory)
        let loaded = try reopened.revisions(of: intakeID)[0].components
        XCTAssertEqual(loaded.map(\.amount), amounts)
        XCTAssertTrue(loaded.allSatisfy { $0.unit == .mg })
    }

    func testOutboxOperationIDsAreUniqueLowercaseUUIDs() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        try store.edit(intakeID: intakeID, components: [oats(2)], product: nil, changeReason: "e", now: when)
        try store.delete(intakeID: intakeID, now: when)
        let operations = try store.pendingOutbox()
        XCTAssertEqual(operations.count, 6)
        XCTAssertEqual(Set(operations.map(\.operationID)).count, operations.count)
        XCTAssertTrue(operations.allSatisfy { JournalValidation.isValidIntakeID($0.operationID) })
    }

    func testDisabledDestinationGetsNoOperationsOnlyADisabledProjection() throws {
        let store = try makeStore(try makeDirectory(), enabled: [.relay])
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        let operations = try store.pendingOutbox()
        XCTAssertEqual(operations.map(\.destination), [.relay])
        let projections = try store.projections(of: intakeID)
        XCTAssertEqual(projections.first { $0.destination == .healthKit }?.state, .disabled)
        XCTAssertEqual(projections.first { $0.destination == .relay }?.state, .pending)
    }

    func testBackgroundReadSeesCommittedData() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        let intakes = try await store.activeIntakesFromBackground()
        XCTAssertEqual(intakes.map(\.id), [intakeID])
    }

    func testFreshV1StoreOpensEmptyAndIsUsable() throws {
        let directory = try makeDirectory()
        let store = try makeStore(directory)
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL(directory).path))
        XCTAssertEqual(JournalSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }

    func testClosedStoreThrowsClosed() throws {
        let store = try makeStore(try makeDirectory())
        store.close()
        XCTAssertThrowsError(try store.activeIntakes()) { XCTAssertEqual($0 as? JournalError, .closed) }
    }
}
