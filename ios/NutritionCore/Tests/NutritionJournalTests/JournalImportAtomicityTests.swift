import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// That an import is all or nothing: nothing is written unless everything can be, and a journal that is
/// no longer empty is refused from inside the same transaction that would have done the writing.
final class JournalImportAtomicityTests: JournalImportTestCase {
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

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore))
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
