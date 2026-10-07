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

    /// A corrected time is a **new revision**, not an update to the one that may already have been
    /// delivered: the encoder digests `occurred_at` per (intake, revision), so the earlier revision
    /// keeps describing the instant it was written for and the entry's own row moves to the
    /// corrected one.
    func testEditWithCorrectedOccurredAtWritesANewRevisionAndKeepsTheOld() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
        let corrected = when.addingTimeInterval(-86_400)
        let revision = try store.edit(
            intakeID: intakeID, components: [oats(40)], product: nil, changeReason: "Time corrected",
            now: when, occurredAt: corrected, timeZoneIdentifier: "UTC")
        XCTAssertEqual(revision.number, 2)
        let intake = try XCTUnwrap(try store.activeIntakes().first)
        XCTAssertEqual(intake.occurredAt, corrected)
        XCTAssertEqual(intake.timeZoneIdentifier, "UTC")
        XCTAssertEqual(intake.currentRevision, 2)
        let revisions = try store.revisions(of: intakeID)
        XCTAssertEqual(revisions.map(\.number), [1, 2])
        XCTAssertEqual(revisions[0].createdAt, when)
        XCTAssertEqual(revisions[1].changeReason, "Time corrected")
        let projections = try store.projections(of: intakeID)
        XCTAssertEqual(projections.filter { $0.revision == 1 }.map(\.isCurrent), [false, false])
        XCTAssertEqual(projections.filter { $0.revision == 2 }.map(\.isCurrent), [true, true])
    }

    /// Each revision keeps the instant it was written with, even after a later revision corrects the
    /// entry's time. This is what a queued delivery rebuilds from: `IntakeRecord.occurredAt` is the only
    /// timestamp the entry has, and it moves on a correction, so without a copy per revision a revision 1
    /// still waiting in the queue would be rebuilt with the corrected instant and reach the receiver under
    /// its own `operation_id` with a different payload — a conflict rather than the duplicate it is.
    func testEachRevisionKeepsTheTimeItWasWrittenWithAcrossALaterCorrection() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
        let corrected = when.addingTimeInterval(-86_400)
        try store.edit(
            intakeID: intakeID, components: [oats(40)], product: nil, changeReason: "Time corrected",
            now: when, occurredAt: corrected, timeZoneIdentifier: "UTC")

        let revisions = try store.revisions(of: intakeID)
        XCTAssertEqual(
            revisions.map(\.occurredAt), [when, corrected],
            "revision 1 states the time it was written with, not the corrected one")
        XCTAssertEqual(revisions.map(\.timeZoneIdentifier), ["UTC", "UTC"])
        XCTAssertEqual(try store.activeIntakes().first?.occurredAt, corrected)
    }

    /// An amounts-only edit records the time the entry already had, so the revision is deliverable on its
    /// own terms rather than depending on a later correction having not happened.
    func testAnAmountsOnlyEditRecordsTheTimeTheEntryAlreadyHad() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
        try store.edit(intakeID: intakeID, components: [oats(55)], product: nil, changeReason: "bigger bowl", now: when)

        XCTAssertEqual(try store.revisions(of: intakeID).last?.occurredAt, when)
        XCTAssertEqual(try store.revisions(of: intakeID).last?.timeZoneIdentifier, "UTC")
    }

    /// A store written before the revision carried a time opens at the current schema with nil revision
    /// times, which mean "the entry's current time" — the only instant such a row can offer, since the
    /// entry's row held the sole copy and may since have been corrected.
    func testAStoreWrittenAtV4OpensWithNilRevisionTimes() throws {
        let directory = try makeDirectory()
        try SwiftDataJournalStore.writeV4RevisionForTesting(
            url: storeURL(directory), intake: sampleIntake(), components: [oats(40)], now: when)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL(directory).path),
            "the fixture has to be a real V4 file on disk, or the migration stage never runs")

        let store = try makeStore(directory)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [intakeID])
        let revision = try XCTUnwrap(try store.revisions(of: intakeID).first)
        XCTAssertEqual(revision.number, 1)
        XCTAssertNil(revision.occurredAt, "a row written before the column carried none")
        XCTAssertNil(revision.timeZoneIdentifier)
        XCTAssertEqual(try store.activeIntakes().first?.occurredAt, when, "the entry's own row is untouched")
    }

    /// A revision written after the upgrade carries its time through a reopen, so the row is not lost on
    /// disk the way a migrated one never had it.
    func testARevisionWrittenNowKeepsItsTimeAcrossAReopen() throws {
        let directory = try makeDirectory()
        let first = try makeStore(directory)
        try first.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
        first.close()

        let second = try makeStore(directory)
        XCTAssertEqual(try second.revisions(of: intakeID).first?.occurredAt, when)
        XCTAssertEqual(try second.revisions(of: intakeID).first?.timeZoneIdentifier, "UTC")
    }

    /// An `edit` that was not given a time corrects the amounts only: the instant the entry says it
    /// was eaten is left exactly as it was, so the common case cannot move an entry by accident.
    func testEditWithoutOccurredAtLeavesTheEntryTimeAlone() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
        let revision = try store.edit(
            intakeID: intakeID, components: [oats(55)], product: nil, changeReason: "bigger bowl", now: when)
        XCTAssertEqual(revision.number, 2)
        XCTAssertEqual(try store.activeIntakes().first?.occurredAt, when)
        XCTAssertEqual(try store.activeIntakes().first?.timeZoneIdentifier, "UTC")
    }

    /// The instant is part of what a revision says, so it is hashed with it: two corrections of one
    /// entry to different times are two different payloads even though everything else is identical.
    func testCorrectedOccurredAtChangesTheQueuedPayloadHash() throws {
        func hash(correctingTo corrected: Date) throws -> String {
            let store = try makeStore(try makeDirectory())
            try store.create(sampleIntake(), components: [oats(40)], product: nil, now: when)
            try store.edit(
                intakeID: intakeID, components: [oats(40)], product: nil, changeReason: "Time corrected",
                now: when, occurredAt: corrected, timeZoneIdentifier: "UTC")
            let queued = try store.pendingOutbox().filter { $0.revision == 2 }
            XCTAssertEqual(queued.count, 2)
            let hashes = Set(queued.map(\.payloadHash))
            XCTAssertEqual(hashes.count, 1, "both destinations hash the same payload")
            return try XCTUnwrap(hashes.first)
        }
        XCTAssertNotEqual(
            try hash(correctingTo: when.addingTimeInterval(-86_400)),
            try hash(correctingTo: when.addingTimeInterval(-3_600)))
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

    /// A store written before the nutrient column existed has to open with the current schema, keep its
    /// rows, and read a snapshot back as a product that states nothing.
    func testAStoreWrittenWithTheOldSchemaMigratesAndKeepsItsRows() throws {
        let directory = try makeDirectory()
        try SwiftDataJournalStore.writeLegacyRevisionForTesting(
            url: storeURL(directory), intake: sampleIntake(), components: [oats()],
            product: product("snap-1", name: "Oats"), now: when)

        let store = try makeStore(directory)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [intakeID])
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
        let snapshot = try XCTUnwrap(try store.product(snapshotID: "snap-1"))
        XCTAssertEqual(snapshot.name, "Oats")
        XCTAssertTrue(snapshot.nutrients.isEmpty)
        XCTAssertEqual(snapshot.value(for: "protein"), .unknown)
    }

    /// Saving the same product again after an upgrade must fill in the values rather than be refused as
    /// a conflict: the row is the same product, only less recorded.
    func testALegacySnapshotIsBackfilledInsteadOfConflicting() throws {
        let store = try makeStore(try makeDirectory())
        let legacyProduct = product("snap-1", name: "Oats")
        try store.create(sampleIntake(), components: [oats()], product: legacyProduct, now: when)
        // The row now stands for a product that states nothing, as a migrated one does.
        try store.clearNutrientsOnSnapshotForTesting(snapshotID: "snap-1")
        XCTAssertTrue(try store.product(snapshotID: "snap-1")?.nutrients.isEmpty ?? false)

        let richer = product("snap-1", name: "Oats").withNutrients(
            ["protein": .known(Decimal(13), .g), "sodium": .unknown])
        XCTAssertNoThrow(try store.edit(
            intakeID: intakeID, components: [oats()], product: richer, changeReason: "rescan", now: when))

        let snapshot = try XCTUnwrap(try store.product(snapshotID: "snap-1"))
        XCTAssertEqual(snapshot.value(for: "protein"), .known(Decimal(13), .g))
        XCTAssertEqual(snapshot.value(for: "sodium"), .unknown)
        XCTAssertEqual(try store.revisions(of: intakeID).count, 2)
    }

    /// A different product under the same id is still refused, even when the stored row states nothing.
    func testALegacySnapshotStillRefusesADifferentProduct() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: product("snap-1", name: "A"), now: when)
        try store.clearNutrientsOnSnapshotForTesting(snapshotID: "snap-1")
        XCTAssertThrowsError(try store.edit(
            intakeID: intakeID, components: [oats()],
            product: product("snap-1", name: "B").withNutrients(["protein": .known(1, .g)]),
            changeReason: "x", now: when)) {
            XCTAssertEqual($0 as? JournalError, .snapshotConflict("snap-1"))
        }
        XCTAssertEqual(try store.product(snapshotID: "snap-1")?.name, "A")
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

    func testCreateThenDeleteListsUpsertBeforeDeletePerDestination() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        let operations = try store.pendingOutbox()
        XCTAssertEqual(operations.count, 4)
        for destination in JournalDestination.allCases {
            let kinds = operations.filter { $0.destination == destination }.map(\.kind)
            XCTAssertEqual(kinds, [.upsert, .delete])
        }
        let firstDelete = operations.firstIndex { $0.kind == .delete }
        let lastUpsert = operations.lastIndex { $0.kind == .upsert }
        XCTAssertNotNil(firstDelete)
        XCTAssertNotNil(lastUpsert)
        XCTAssertLessThan(try XCTUnwrap(lastUpsert), try XCTUnwrap(firstDelete))
    }

    func testConcurrentEditsGetDistinctConsecutiveRevisions() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        let failures = NSLock()
        var errors: [Error] = []
        let id = intakeID
        let at = when
        let amount = oats(5)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                try store.edit(intakeID: id, components: [amount], product: nil, changeReason: "e", now: at)
            } catch {
                failures.withLock { errors.append(error) }
            }
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try store.revisions(of: intakeID).map(\.number), Array(1...9))
        let current = try store.projections(of: intakeID).filter(\.isCurrent)
        XCTAssertEqual(current.count, JournalDestination.allCases.count)
        XCTAssertEqual(Set(current.map(\.destination)).count, JournalDestination.allCases.count)
        XCTAssertTrue(current.allSatisfy { $0.revision == 9 })
    }

    func testSnapshotReadReturnsActiveIntakesWithRevisionsAndDeletedTombstones() throws {
        let store = try makeStore(try makeDirectory())
        try store.create(
            sampleIntake(), components: [oats(40)], product: product("snap-1", name: "Sample oats"), now: when)
        try store.edit(intakeID: intakeID, components: [oats(55)], product: nil, changeReason: "bigger bowl", now: when)
        try store.delete(intakeID: intakeID, now: when)
        let snapshot = try store.readJournalSnapshot()
        XCTAssertTrue(snapshot.activeIntakes.isEmpty)
        XCTAssertEqual(snapshot.deletedIntakes.map(\.id), [intakeID])
        XCTAssertEqual(snapshot.deletedIntakes.first?.currentRevision, 2)
    }

    func testUnknownLifecycleValueIsRejectedRatherThanReadAsActive() throws {
        // A snapshot read must not resurrect a deleted entry just because its stored lifecycle is corrupt.
        XCTAssertEqual(try SwiftDataJournalStore.lifecycle(rawValue: "active"), .active)
        XCTAssertEqual(try SwiftDataJournalStore.lifecycle(rawValue: "deleted"), .deleted)
        XCTAssertThrowsError(try SwiftDataJournalStore.lifecycle(rawValue: "archived")) { error in
            XCTAssertEqual(error as? JournalError, .corruptRecord("lifecycle:archived"))
        }
    }
}
