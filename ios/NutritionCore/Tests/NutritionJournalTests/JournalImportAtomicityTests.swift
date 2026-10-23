import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// That an import validates before writing, compensates for a failed second-store write when it safely can,
/// and reports when concurrent work prevents that compensation.
final class JournalImportAtomicityTests: JournalImportTestCase {
    private final class FavoritesThatEditsJournalThenFails: FavoritesStore, FavoritesRestoreTarget,
        @unchecked Sendable
    {
        private let editJournal: () throws -> Void

        init(editJournal: @escaping () throws -> Void) {
            self.editJournal = editJournal
        }

        func add(_ favorite: FavoriteTemplate) throws {}
        func remove(id: String) throws {}
        func list() throws -> [FavoriteTemplate] { [] }
        func contains(id: String) throws -> Bool { false }
        func close() {}

        func restore(_ favorites: [FavoriteTemplate]) throws {
            try editJournal()
            throw FavoritesError.injectedSaveFailure
        }
    }

    func testTheStoreItselfRefusesToRestoreIntoAJournalThatIsNoLongerEmpty() throws {
        // The emptiness check lives inside the store's restore transaction, under the same write lock as
        // the inserts, so a write that lands between the importer's check and the inserts cannot turn an
        // empty-only restore into a merge. Calling the store directly is what pins that: the importer's
        // check alone would not notice a journal that filled up in the meantime.
        let target = try directory()
        let journal = try store(target)
        try journal.create(
            Intake(
                id: otherID, category: "food", occurredAt: base, timeZoneIdentifier: "UTC"),
            components: [water("100")], product: nil, now: base)

        XCTAssertThrowsError(
            try journal.restore(
                JournalRestorePlan(entries: [], tombstones: [], products: [], favorites: []))
        ) { error in
            XCTAssertEqual(error as? JournalImportError, .notEmpty)
        }
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [otherID])
    }

    func testAnExportWithFavoritesIsRefusedWhenThereIsNoFavoritesStoreToPutThemIn() throws {
        // The favorites argument is optional, and the screen can be built without a favorites store. A
        // document that carries favorites is then refused outright: importing the entries and reporting
        // success while the favorites were dropped is the one answer this may not give.
        let target = try directory()
        let journal = try store(target)
        XCTAssertThrowsError(
            try JournalImporter.importExport(try exportData(), into: journal, favorites: nil)
        ) { error in
            guard case .corrupt = error as? JournalImportError else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        // Refused before anything was written, so the journal is still empty.
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertNil(try journal.product(snapshotID: "snap-oats-1"))
    }

    func testAnExportWithoutFavoritesNeedsNoFavoritesStore() throws {
        let target = try directory()
        let journal = try store(target)
        let summary = try JournalImporter.importExport(
            try exportData(favorites: false), into: journal, favorites: nil)
        XCTAssertEqual(summary.favorites, 0)
        XCTAssertEqual(summary.intakes, 2)
    }

    func testAFailedFavoritesWriteEmptiesTheJournalAgain() throws {
        // The journal is written first, so the one thing that can still fail after it is the favorites.
        // The journal was empty before, so putting it back means emptying it again: a failed import must
        // not leave a restored journal behind with the favorites missing, and must not need the person to
        // retry to get back to where they started.
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        favoritesStore.failNextSaveForTesting = true

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? FavoritesError, .injectedSaveFailure)
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try journal.revisions(of: oatsID).isEmpty)
        XCTAssertTrue(try journal.revisions(of: waterID).isEmpty)
        // The product snapshot the file carried is gone too, or a second import would meet a store that
        // remembers a product no entry uses.
        XCTAssertNil(try journal.product(snapshotID: "snap-oats-1"))
        XCTAssertTrue(try journal.pendingOutbox().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)

        // Which means the import can simply be run again, with nothing to clean up first.
        let summary = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        XCTAssertEqual(summary.intakes, 2)
        XCTAssertEqual(summary.favorites, 2)
    }

    /// The app can be stopped between the journal's save and the favorites' save, where the in-process undo never
    /// runs. The flag beside the store names the file, so importing that same file again writes the favorites
    /// and clears the flag instead of refusing a journal that is no longer empty (#118).
    func testAnImportStoppedBetweenItsSavesIsFinishedByImportingTheSameFileAgain() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        // What a stop after the journal's save leaves: the flag, the journal, and no favorites.
        try journal.markRestoreInProgress(fileDigest: JournalImporter.fileDigest(data))
        _ = try journal.restore(try JournalImporter.makePlan(try JournalImporter.readDocument(data)))

        let summary = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)

        XCTAssertEqual(summary.favorites, 2)
        XCTAssertEqual(try favoritesStore.list().count, 2)
        XCTAssertEqual(try journal.revisions(of: oatsID).map(\.number), [1, 2], "nothing was written twice")
        XCTAssertNil(try journal.restoreInProgressDigest(), "the finished restore clears its flag")
    }

    /// Without the flag, or with the flag of another file, a journal that is not empty is refused as before.
    func testOnlyTheFileTheFlagNamesIsFinished() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        try journal.markRestoreInProgress(fileDigest: JournalImporter.fileDigest(Data("another file".utf8)))
        _ = try journal.restore(try JournalImporter.makePlan(try JournalImporter.readDocument(data)))

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }

    /// A flag left by a stop before the journal's save, with an entry logged since, is not taken for an unfinished
    /// restore of that file: the journal does not hold the file's journal, so the import is refused.
    func testAStaleFlagWithOtherEntriesIsRefused() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        try journal.markRestoreInProgress(fileDigest: JournalImporter.fileDigest(data))
        try journal.create(
            Intake(id: otherID, category: "food", occurredAt: base, timeZoneIdentifier: "UTC"),
            components: [water("100")], product: nil, now: base)

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertTrue(try favoritesStore.list().isEmpty)
        XCTAssertNotNil(try journal.restoreInProgressDigest(), "a refused import leaves a flag it did not write")
    }

    /// Importing another file while a restore is unfinished is refused and leaves that restore's flag, so the
    /// right file can still finish it.
    func testAnotherFileLeavesTheUnfinishedRestoresFlag() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let digest = JournalImporter.fileDigest(data)
        try journal.markRestoreInProgress(fileDigest: digest)
        _ = try journal.restore(try JournalImporter.makePlan(try JournalImporter.readDocument(data)))
        var other = try object(of: data)
        other["app_version"] = "9.9.9"
        let otherData = try JSONSerialization.data(withJSONObject: other)

        XCTAssertThrowsError(try JournalImporter.importExport(otherData, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertEqual(try journal.restoreInProgressDigest(), digest)

        _ = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        XCTAssertEqual(try favoritesStore.list().count, 2)
    }

    /// A flag that outlived a finished restore (its removal failed) does not start a resume while any of the file's
    /// favorites are on the phone, so a favorite deleted since is not put back.
    func testALeftoverFlagDoesNotResumeOverTheFilesFavorites() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        _ = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        try journal.markRestoreInProgress(fileDigest: JournalImporter.fileDigest(data))
        let deleted = try XCTUnwrap(try favoritesStore.list().first)
        try favoritesStore.remove(id: deleted.id)

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertFalse(try favoritesStore.contains(id: deleted.id), "the deleted favorite stays deleted")
    }

    /// A stop after the favorites' save but before the flag was cleared leaves the flag, and then every one of
    /// that file's favorites is deleted. The receipt saved with the favorites says they were written, so the
    /// same file imported again is refused and they stay deleted.
    func testAFlagOutlivingTheFavoritesSaveDoesNotBringDeletedFavoritesBack() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let digest = JournalImporter.fileDigest(data)
        let plan = try JournalImporter.makePlan(try JournalImporter.readDocument(data))
        try journal.markRestoreInProgress(fileDigest: digest)
        _ = try journal.restore(plan)
        try favoritesStore.restore(plan.favorites, receipt: digest)
        XCTAssertEqual(try favoritesStore.list().count, 2, "the receipt is not listed as a favorite")
        for favorite in try favoritesStore.list() { try favoritesStore.remove(id: favorite.id) }

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertTrue(try favoritesStore.list().isEmpty, "deleted favorites are not put back")
    }

    /// A restore that finished clears its flag, so running it again after the favorites were deleted is refused
    /// and does not put them back.
    func testAFinishedImportLeavesNoFlagAndIsRefusedWhenRunAgain() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        _ = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        XCTAssertNil(try journal.restoreInProgressDigest())
        for favorite in try favoritesStore.list() { try favoritesStore.remove(id: favorite.id) }

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertTrue(try favoritesStore.list().isEmpty, "deleted favorites are not put back")
    }

    /// A failed favorites write that the undo cleans up leaves no flag behind either, and erasing removes one.
    func testAFailedImportAndAnEraseLeaveNoFlag() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        favoritesStore.failNextSaveForTesting = true
        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore))
        XCTAssertNil(try journal.restoreInProgressDigest())

        try journal.markRestoreInProgress(fileDigest: "left behind")
        try journal.eraseAll()
        XCTAssertNil(try journal.restoreInProgressDigest())
    }

    /// A complete restore whose flag clear failed leaves its rows and receipts. A retry of the same file is refused,
    /// as a finished restore is, and writes nothing.
    func testARetryAfterAFailedFlagClearIsRefusedAndWritesNothing() throws {
        let data = try exportData()
        let target = try directory()
        let inner = try store(target)
        let journal = FlagClearFailsOnceJournal(inner)
        let favoritesStore = try favorites(target)
        journal.failNextClear = true

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .cleanupIncomplete)
        }
        XCTAssertNotNil(try inner.restoreInProgressDigest())
        let rowsAfterFirst = try inner.activeIntakes().map(\.id)
        XCTAssertFalse(rowsAfterFirst.isEmpty)

        // A retry finds every receipt and the flag, and is refused as before: nothing is written again, and the flag stays.
        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertNotNil(try inner.restoreInProgressDigest())
        XCTAssertEqual(try inner.activeIntakes().map(\.id), rowsAfterFirst)
    }

    /// A flag that cannot be removed fails the erase before any journal row is deleted, so the screen can
    /// report it and nothing a re-import could bring back is half-erased.
    func testAnEraseStopsBeforeDeletingWhenTheRestoreFlagCannotBeRemoved() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        _ = try JournalImporter.importExport(data, into: journal, favorites: try favorites(target))
        XCTAssertFalse(try journal.activeIntakes().isEmpty)

        try journal.markRestoreInProgress(fileDigest: "left behind")
        // Removing a file needs write permission on its directory, so a read-only directory keeps the flag in place.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }

        XCTAssertThrowsError(try journal.eraseAll())
        XCTAssertFalse(try journal.activeIntakes().isEmpty)
    }

    func testFavoritesFailureAndConcurrentEditRefusalReportsRetainedJournal() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favorites = FavoritesThatEditsJournalThenFails { [self] in
            try journal.edit(
                intakeID: oatsID, components: [oats("99")], product: nil, changeReason: "concurrent edit",
                now: base.addingTimeInterval(9_000), occurredAt: nil, timeZoneIdentifier: nil)
        }

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favorites)) {
            guard case .partialRestore(retainedIntakes: 2, retainedTombstones: 1) = $0 as? JournalImportError else {
                return XCTFail("expected a partial restore outcome, got \($0)")
            }
            XCTAssertFalse(String(describing: $0).contains("injectedSaveFailure"))
        }
        XCTAssertEqual(Set(try journal.activeIntakes().map(\.id)), Set([oatsID, waterID]))
        XCTAssertEqual(try journal.revisions(of: oatsID).map(\.number), [1, 2, 3])
        XCTAssertEqual(try journal.revisions(of: oatsID).last?.changeReason, "concurrent edit")
        XCTAssertEqual(try journal.deletedIntakes().map(\.id), [goneID])
    }

    func testAFailedJournalWriteLeavesTheFavoritesAlone() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        journal.failNextSaveForTesting = true

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)) {
            XCTAssertEqual($0 as? JournalError, .injectedSaveFailure)
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }

    func testAFailedFavoritesWriteCanBeRetriedWithoutDeletingAnythingFirst() throws {
        // The same file, twice: the second run has to be accepted, which it only can be if the first run
        // really did leave both stores as it found them.
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        favoritesStore.failNextSaveForTesting = true
        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore))
        favoritesStore.failNextSaveForTesting = false

        let summary = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        XCTAssertEqual(summary.tombstones, 1)
        XCTAssertEqual(try favoritesStore.list().count, 2)
        let changedField = try firstDifference(
            between: data,
            and: try JournalExporter.encode(
                try JournalExporter.makeExport(
                    store: journal, favorites: favoritesStore, appVersion: appVersion,
                    exportedAt: exportedAt)))
        XCTAssertNil(changedField)
    }

    func testUndoingARestoreRemovesTheRevisionsItWroteAndNoOthers() throws {
        // The undo is compensation, not a clean-up: between the journal write and the favorites failing,
        // somebody may have written to the same journal. It removes the rows the restore inserted, by
        // intake id and revision number, and refuses when an entry no longer looks the way it left it.
        let target = try directory()
        let journal = try store(target)
        let receipt = try journal.restore(
            JournalRestorePlan(
                entries: [entry(oatsID, revisions: 2)], tombstones: [], products: [], favorites: []))
        XCTAssertEqual(receipt.intakes.map(\.intakeID), [oatsID])
        XCTAssertEqual(receipt.intakes.first?.revisionNumbers, [1, 2])

        // An edit lands on the restored entry, so the undo can no longer tell its own rows from that one.
        try journal.edit(
            intakeID: oatsID, components: [water("300")], product: nil, changeReason: "more",
            now: base.addingTimeInterval(9000))
        XCTAssertThrowsError(try journal.undoRestore(receipt)) { error in
            guard case .corrupt = error as? JournalImportError else {
                return XCTFail("expected the undo to refuse, got \(error)")
            }
        }
        // Nothing of the person's was thrown away to achieve that.
        XCTAssertEqual(try journal.revisions(of: oatsID).map(\.number), [1, 2, 3])
        XCTAssertEqual(try journal.revisions(of: oatsID).last?.changeReason, "more")
    }

    func testUndoingARestoreLeavesAnEntryThatNobodyTouched() throws {
        let target = try directory()
        let journal = try store(target)
        let receipt = try journal.restore(
            JournalRestorePlan(entries: [entry(oatsID, revisions: 2)], tombstones: [], products: [], favorites: []))
        try journal.undoRestore(receipt)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.revisions(of: oatsID).isEmpty)
    }

    func testUndoingARestoreRefusesWhenAnEntryWasDeletedAfterwards() throws {
        let target = try directory()
        let journal = try store(target)
        let receipt = try journal.restore(
            JournalRestorePlan(entries: [entry(oatsID, revisions: 1)], tombstones: [], products: [], favorites: []))
        try journal.delete(intakeID: oatsID, now: base.addingTimeInterval(600))
        XCTAssertThrowsError(try journal.undoRestore(receipt))
        // The deletion is the person's, so it stands: the undo removed nothing rather than revive an entry
        // or throw away the revision it still holds.
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertEqual(try journal.deletedIntakes().count, 1)
        XCTAssertEqual(try journal.revisions(of: oatsID).count, 1)
    }
}

/// The real journal store with one failure: the first restore-in-progress clear throws, as a disk error would.
/// Every other call is forwarded unchanged, so the importer runs its real second phase.
private final class FlagClearFailsOnceJournal: JournalStore, JournalRestoreTarget, JournalRestoreProgress,
    JournalTombstoneSource, @unchecked Sendable
{
    struct ClearFailure: Error {}
    let inner: SwiftDataJournalStore
    var failNextClear = false

    init(_ inner: SwiftDataJournalStore) { self.inner = inner }

    var failNextSaveForTesting: Bool {
        get { inner.failNextSaveForTesting }
        set { inner.failNextSaveForTesting = newValue }
    }
    func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision {
        try inner.create(intake, components: components, product: product, now: now)
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?
    ) throws -> IntakeRevision {
        try inner.edit(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }
    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?, unitRemovals: [String]
    ) throws -> IntakeRevision {
        try inner.editRemovingUnits(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier, unitRemovals: unitRemovals)
    }
    func delete(intakeID: String, now: Date) throws { try inner.delete(intakeID: intakeID, now: now) }
    func deleteSequenced(intakeID: String, now: Date) throws -> UInt64 {
        try inner.deleteSequenced(intakeID: intakeID, now: now)
    }
    func createSequenced(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> (IntakeRevision, UInt64) {
        try inner.createSequenced(intake, components: components, product: product, now: now)
    }
    var deleteSequence: UInt64 { inner.deleteSequence }
    func undoDelete(intakeID: String) throws { try inner.undoDelete(intakeID: intakeID) }
    func activeIntakes() throws -> [Intake] { try inner.activeIntakes() }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { try inner.revisions(of: intakeID) }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? { try inner.product(snapshotID: snapshotID) }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }

    func restore(_ plan: JournalRestorePlan) throws -> JournalRestoreReceipt { try inner.restore(plan) }
    func undoRestore(_ receipt: JournalRestoreReceipt) throws { try inner.undoRestore(receipt) }
    func markRestoreInProgress(fileDigest: String) throws { try inner.markRestoreInProgress(fileDigest: fileDigest) }
    func restoreInProgressDigest() throws -> String? { try inner.restoreInProgressDigest() }
    func clearRestoreInProgress() throws {
        if failNextClear {
            failNextClear = false
            throw ClearFailure()
        }
        try inner.clearRestoreInProgress()
    }
    func deletedIntakes() throws -> [Intake] { try inner.deletedIntakes() }
}
