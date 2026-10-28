import Combine
import Foundation
import Dispatch
import NutritionDomain
@testable import NutritionJournal
import XCTest
@testable import NutritionUI

/// The import side of the Connections and privacy screen: a restore that works, a file the importer
/// refuses, a stale export a successful import must remove, and a chosen file that cannot be read.
///
/// `importJournal` restores off the main actor and publishes its outcome back on it, so these call it and
/// then wait for that hop rather than asserting straight after the call.

/// A journal store held in memory, standing in for the real one. It reproduces the two things the screen
/// can be shown: a restore that lands, and a refusal with the reason the importer would give.
private final class ImportStubStore: JournalStore, JournalTombstoneSource, JournalRestoreTarget,
    JournalErasing, JournalRestoreProgress, @unchecked Sendable
{
    struct Unsupported: Error {}
    var failClearRestoreForTesting = false
    var clearRestoreCallsForTesting = 0
    /// Off by default, so the other tests see no flag at all. On, the flag is recorded like a real journal keeps it.
    var recordsRestoreFlag = false
    private var restoreFlag: String?
    func markRestoreInProgress(fileDigest: String) throws {
        if recordsRestoreFlag { restoreFlag = fileDigest }
    }
    func restoreInProgressDigest() throws -> String? { recordsRestoreFlag ? restoreFlag : nil }
    func clearRestoreInProgress() throws {
        clearRestoreCallsForTesting += 1
        if failClearRestoreForTesting { throw Unsupported() }
        if recordsRestoreFlag { restoreFlag = nil }
    }
    let erasureName = "journal"

    var failNextSaveForTesting = false
    var failUndoForTesting = false
    /// Makes the journal unreadable once an undo has failed, as a store that cannot be read at that moment would be.
    var failReadsAfterUndoForTesting = false
    private var failReadsForTesting = false
    var failEraseForTesting = false
    var pauseBeforeRestoreForTesting = false
    var pauseAfterRestoreForTesting = false
    let restorePausedBeforeWriteForTesting = DispatchSemaphore(value: 0)
    let resumeRestoreBeforeWriteForTesting = DispatchSemaphore(value: 0)
    let restorePausedForTesting = DispatchSemaphore(value: 0)
    let resumeRestoreForTesting = DispatchSemaphore(value: 0)
    var intakes: [Intake] = []
    var deleted: [Intake] = []
    var revisionsByIntake: [String: [IntakeRevision]] = [:]
    var products: [String: ProductDefinition] = [:]
    /// Every plan the importer handed over, so a test can see that the restore really reached the store.
    var restoredPlans: [JournalRestorePlan] = []

    func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision { throw Unsupported() }

    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision { throw Unsupported() }

    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil, unitRemovals: [String])throws -> IntakeRevision { throw Unsupported() }

    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] {
        if failReadsForTesting { throw JournalImportError.corrupt("injected read refusal") }
        return intakes
    }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { revisionsByIntake[intakeID] ?? [] }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { products[snapshotID] }
    func activeIntakesFromBackground() async throws -> [Intake] { try activeIntakes() }
    func close() {}
    func deletedIntakes() throws -> [Intake] {
        if failReadsForTesting { throw JournalImportError.corrupt("injected read refusal") }
        return deleted
    }
    func eraseAll() throws {
        if failEraseForTesting { throw Unsupported() }
        intakes = []
        deleted = []
        revisionsByIntake = [:]
        products = [:]
    }

    /// The real store refuses a journal that already holds an intake row, from inside its own transaction,
    /// and the importer reports whatever the store throws. The screen is what these tests are about, so the
    /// stub refuses exactly as the store does and lets the refusal travel the same path.
    func restore(_ plan: JournalRestorePlan) throws -> JournalRestoreReceipt {
        if pauseBeforeRestoreForTesting {
            pauseBeforeRestoreForTesting = false
            restorePausedBeforeWriteForTesting.signal()
            _ = resumeRestoreBeforeWriteForTesting.wait(timeout: .now() + 5)
        }
        guard intakes.isEmpty, deleted.isEmpty else { throw JournalImportError.notEmpty }
        restoredPlans.append(plan)
        intakes.append(contentsOf: plan.entries.map(\.intake))
        for entry in plan.entries {
            revisionsByIntake[entry.intake.id] = entry.revisions
        }
        deleted.append(contentsOf: plan.tombstones)
        if pauseAfterRestoreForTesting {
            pauseAfterRestoreForTesting = false
            restorePausedForTesting.signal()
            _ = resumeRestoreForTesting.wait(timeout: .now() + 5)
        }
        let restored = plan.entries.map { entry in
            JournalRestoredIntake(
                intakeID: entry.intake.id, lifecycle: .active,
                currentRevision: entry.intake.currentRevision,
                revisionNumbers: entry.revisions.map(\.number))
        } + plan.tombstones.map { tombstone in
            JournalRestoredIntake(
                intakeID: tombstone.id, lifecycle: .deleted,
                currentRevision: tombstone.currentRevision, revisionNumbers: [])
        }
        return JournalRestoreReceipt(intakes: restored, insertedProductSnapshotIDs: [])
    }

    func undoRestore(_ receipt: JournalRestoreReceipt) throws {
        if failUndoForTesting {
            failReadsForTesting = failReadsAfterUndoForTesting
            throw JournalImportError.corrupt("injected undo refusal")
        }
        intakes.removeAll()
        deleted.removeAll()
        revisionsByIntake = [:]
    }
}

private final class ImportStubFavorites: FavoritesStore, FavoritesRestoreTarget, JournalErasing, @unchecked Sendable {
    let erasureName = "favorites"
    var items: [FavoriteTemplate] = []
    var failRestoreForTesting = false

    func add(_ favorite: FavoriteTemplate) throws { items.append(favorite) }
    func remove(id: String) throws { items.removeAll { $0.id == id } }
    func list() throws -> [FavoriteTemplate] { items }
    func contains(id: String) throws -> Bool { items.contains { $0.id == id } }
    func restore(_ favorites: [FavoriteTemplate]) throws {
        if failRestoreForTesting { throw FavoritesError.injectedSaveFailure }
        items = favorites
    }
    func eraseAll() throws { items = [] }
    func close() {}
}

private final class FailingAncillaryEraser: JournalErasing, @unchecked Sendable {
    struct Failure: Error {}
    let erasureName = "test store"
    func eraseAll() throws { throw Failure() }
}

@MainActor
final class ConnectionsPrivacyImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_705_313_700)
    private let entryID = "1f0c9d2a-6b3e-4a7f-9c5d-0e2b6f8a1d33"

    /// A version 1 export with one entry, as the screen would have been handed by a file picker.
    private func export(includeFavorite: Bool = false) throws -> Data {
        let journal = ImportStubStore()
        journal.intakes = [
            Intake(
                id: entryID, category: "food", occurredAt: now, timeZoneIdentifier: "Europe/Berlin",
                meal: "breakfast")
        ]
        journal.revisionsByIntake[entryID] = [
            IntakeRevision(
                intakeID: entryID, number: 1,
                components: [IntakeComponent(
                    componentID: "oats", name: "Oats", amount: Decimal(string: "37.5")!, unit: .g)],
                productSnapshotID: nil, changeReason: "created", createdAt: now)
        ]
        let favorites: ImportStubFavorites?
        if includeFavorite {
            let source = ImportStubFavorites()
            source.items = [FavoriteTemplate(
                id: "favorite-tea", displayName: "Tea", category: "drink",
                components: [FavoriteComponent(componentID: "tea", name: "Tea", amountText: "250", unitSymbol: "mL")])]
            favorites = source
        } else {
            favorites = nil
        }
        return try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: journal, favorites: favorites, goals: InMemoryGoalStore(), appVersion: "0.1.0", exportedAt: now))
    }

    func testASuccessfulImportPublishesTheSummaryAndRestoresTheJournal() async throws {
        let journal = ImportStubStore()
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: journal, favorites: ImportStubFavorites())
        await importAndSettle(model, data: try export())

        XCTAssertEqual(model.importState, .imported)
        XCTAssertEqual(model.journalRestoreGeneration, 1)
        XCTAssertEqual(model.importSummary?.intakes, 1)
        XCTAssertEqual(model.importMessage, "Imported 1 entry.")
        XCTAssertNil(model.errorMessage)
        // The restore reached the store, not just the screen: the entry and its revision are there.
        XCTAssertEqual(journal.restoredPlans.count, 1)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])
        XCTAssertEqual(try journal.revisions(of: entryID).map(\.number), [1])
    }

    func testARefusedFileIsPublishedAsAFailureWithNoSummary() async throws {
        let journal = ImportStubStore()
        // An entry that is not from the file, so the store refuses the restore and the importer says why.
        journal.intakes = [Intake(id: entryID, category: "food", occurredAt: now, timeZoneIdentifier: "UTC")]
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: journal, favorites: ImportStubFavorites())
        await importAndSettle(model, data: try export())

        XCTAssertEqual(model.importState, .failed)
        XCTAssertNil(model.importSummary)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importNotEmptyMessage)
        XCTAssertEqual(model.journalRestoreGeneration, 0)
        XCTAssertTrue(journal.restoredPlans.isEmpty, "a refused import writes nothing")
    }

    /// A failed undo whose journal then cannot be read reports the count as unknown, not as the receipt's count or as zero.
    /// Fails when the count is taken from the receipt, which reads as a number the journal may no longer hold.
    func testAPartialRestoreWhoseJournalCannotBeReadReportsTheCountAsUnknown() throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        journal.failReadsAfterUndoForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true

        XCTAssertThrowsError(try JournalImporter.importExport(
            try export(includeFavorite: true), into: journal, favorites: favorites)) {
            guard case .partialRestore(let intakes, let tombstones) = $0 as? JournalImportError else {
                return XCTFail("expected a partial restore, got \($0)")
            }
            XCTAssertNil(intakes, "an unreadable journal leaves the count unknown")
            XCTAssertNil(tombstones)
        }
    }

    func testPartialRestoreWarnsEntriesMayRemainAndClearsTheStaleExport() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        var removed: [URL] = []
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, writer: { _, _, _ in },
            remover: { removed.append($0) })
        XCTAssertTrue(model.export(now: now))
        let staleExport = try XCTUnwrap(model.exportFileURL)

        await importAndSettle(model, data: try export(includeFavorite: true))

        XCTAssertEqual(model.importState, .failed)
        XCTAssertNil(model.importSummary)
        XCTAssertTrue(model.importMessage?.contains("may already be present") == true)
        XCTAssertFalse(model.importMessage?.localizedCaseInsensitiveContains("retry") == true)
        XCTAssertEqual(model.incompleteRestoreWarning, model.importMessage)
        XCTAssertEqual(model.journalRestoreGeneration, 1)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])
        XCTAssertNil(model.exportFileURL)
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertEqual(removed.map(\.path), [staleExport.path])
    }

    func testSupersededPartialRestoreStillRefreshesJournalAndRemovesStaleExport() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        journal.pauseAfterRestoreForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        var removed: [URL] = []
        let removalObserved = DispatchSemaphore(value: 0)
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, writer: { _, _, _ in },
            remover: { url in
                removed.append(url)
                removalObserved.signal()
            })
        XCTAssertTrue(model.export(now: now))
        let staleExport = try XCTUnwrap(model.exportFileURL)

        model.importJournal(data: try export(includeFavorite: true))
        let olderRestoreReachedStore = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(olderRestoreReachedStore)

        // The older import has committed journal rows but is paused before its favorites write. The newer
        // import becomes current and is refused by the store's same-transaction not-empty check.
        model.importJournal(data: try export())
        await waitForCurrentFailure(model)
        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importNotEmptyMessage)
        XCTAssertEqual(model.journalRestoreGeneration, 0)
        XCTAssertNil(model.incompleteRestoreWarning)

        journal.resumeRestoreForTesting.signal()
        let olderMutationWasPublished = await waitForSignal(removalObserved)
        XCTAssertTrue(olderMutationWasPublished)
        XCTAssertEqual(model.journalRestoreGeneration, 1)
        XCTAssertEqual(removed.map(\.path), [staleExport.path])
        XCTAssertEqual(
            model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)
        XCTAssertNil(model.exportFileURL)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])

        // The older partial result must not replace the newer import's presentation.
        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importNotEmptyMessage)
    }

    func testSupersededSuccessfulRestoreStillRefreshesJournalAndRemovesStaleExport() async throws {
        let journal = ImportStubStore()
        journal.pauseAfterRestoreForTesting = true
        var removed: [URL] = []
        let removalObserved = DispatchSemaphore(value: 0)
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: ImportStubFavorites(), writer: { _, _, _ in },
            remover: { url in
                removed.append(url)
                removalObserved.signal()
            })
        XCTAssertTrue(model.export(now: now))
        let staleExport = try XCTUnwrap(model.exportFileURL)

        model.importJournal(data: try export())
        let olderRestoreReachedStore = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(olderRestoreReachedStore)

        model.importJournal(data: try export())
        await waitForCurrentFailure(model)
        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importNotEmptyMessage)

        journal.resumeRestoreForTesting.signal()
        let olderMutationWasPublished = await waitForSignal(removalObserved)
        XCTAssertTrue(olderMutationWasPublished)
        XCTAssertEqual(model.journalRestoreGeneration, 1)
        XCTAssertEqual(removed.map(\.path), [staleExport.path])
        XCTAssertNil(model.exportFileURL)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])
        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importNotEmptyMessage)
        XCTAssertNil(model.incompleteRestoreWarning)
    }

    func testPartialRestoreWarningSurvivesClearImportAndALaterNotEmptyFailure() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: journal, favorites: favorites)

        await importAndSettle(model, data: try export(includeFavorite: true))
        XCTAssertEqual(model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)

        model.clearImport()
        XCTAssertEqual(model.importState, .idle)
        XCTAssertEqual(model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)

        await importAndSettle(model, data: try export())
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importNotEmptyMessage)
        XCTAssertEqual(model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)

        try journal.eraseAll()
        journal.failUndoForTesting = false
        favorites.failRestoreForTesting = false
        model.clearImport()
        await importAndSettle(model, data: try export())
        XCTAssertEqual(model.importState, .imported)
        XCTAssertNil(model.incompleteRestoreWarning)
    }

    func testFavoritesFailureWithSuccessfulUndoShowsTheRolledBackMessage() async throws {
        let journal = ImportStubStore()
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        var removed: [URL] = []
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, writer: { _, _, _ in },
            remover: { removed.append($0) })
        XCTAssertTrue(model.export(now: now))
        let originalExport = try XCTUnwrap(model.exportFileURL)

        await importAndSettle(model, data: try export(includeFavorite: true))

        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importRolledBackMessage)
        XCTAssertEqual(model.journalRestoreGeneration, 0)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertEqual(model.exportFileURL, originalExport)
        XCTAssertTrue(removed.isEmpty)
    }

    func testASuccessfulImportRemovesTheStaleExportThisScreenWasHolding() async throws {
        var written: [URL] = []
        var removed: [URL] = []
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: ImportStubStore(), favorites: ImportStubFavorites(),
            writer: { _, url, _ in written.append(url) },
            erasers: [],
            remover: { url in removed.append(url) })
        XCTAssertTrue(model.export(now: now))
        let exportedURL = try XCTUnwrap(model.exportFileURL)
        XCTAssertEqual(written, [exportedURL])
        // The journal is empty (an import only restores into an empty one), so the export holds no entries.
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertTrue(removed.isEmpty, "the export is there to be shared, not removed, before the import")

        await importAndSettle(model, data: try export())

        // The copy on screen was made from the journal as it was before the restore, so sharing it would hand
        // over the wrong journal: it is deleted and the screen stops offering it.
        XCTAssertEqual(removed.map(\.path), [exportedURL.path])
        XCTAssertNil(model.exportFileURL)
        XCTAssertNil(model.exportFileName)
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertEqual(model.exportState, .idle)
    }

    func testExportIsUnavailableUntilRestorePublishesAfterItsStoreMutation() async throws {
        let journal = ImportStubStore()
        journal.pauseAfterRestoreForTesting = true
        var written: [URL] = []
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: ImportStubFavorites(),
            writer: { _, url, _ in written.append(url) },
            remover: { _ in })

        model.importJournal(data: try export())
        let restorePaused = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(restorePaused)
        // The import has changed the store but has not published its result. Keep export unavailable until
        // that restore finishes, then allow a fresh copy that includes its entry.
        XCTAssertFalse(model.canExport)
        XCTAssertFalse(model.export(now: now))
        XCTAssertNil(model.exportFileURL)
        XCTAssertTrue(written.isEmpty)

        journal.resumeRestoreForTesting.signal()
        await waitForImportToSettle(model)

        XCTAssertEqual(model.journalRestoreGeneration, 1)
        XCTAssertTrue(model.canExport)
        XCTAssertTrue(model.export(now: now))
        let freshExport = try XCTUnwrap(model.exportFileURL)
        XCTAssertEqual(model.exportState, .ready)
        XCTAssertEqual(model.entryCount, 1)
        XCTAssertEqual(written, [freshExport])
    }

    func testExportIsRefusedBeforeAnImportMutatesTheStore() async throws {
        let journal = ImportStubStore()
        journal.pauseBeforeRestoreForTesting = true
        var written: [URL] = []
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: ImportStubFavorites(),
            writer: { _, url, _ in written.append(url) }, remover: { _ in })

        model.importJournal(data: try export())
        let restorePaused = await waitForSignal(journal.restorePausedBeforeWriteForTesting)
        XCTAssertTrue(restorePaused)

        XCTAssertFalse(model.canExport)
        XCTAssertFalse(model.export(now: now))
        XCTAssertNil(model.exportFileURL)
        XCTAssertTrue(written.isEmpty)

        journal.resumeRestoreBeforeWriteForTesting.signal()
        await waitForImportToSettle(model)
        XCTAssertTrue(model.canExport)
        XCTAssertTrue(model.export(now: now))
        XCTAssertEqual(model.entryCount, 1)
        XCTAssertEqual(written.count, 1)
    }

    func testLatestFailureDoesNotEnableExportWhileOlderRestoreStillWrites() async throws {
        let journal = ImportStubStore()
        journal.pauseAfterRestoreForTesting = true
        var written: [URL] = []
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: ImportStubFavorites(),
            writer: { _, url, _ in written.append(url) }, remover: { _ in })

        model.importJournal(data: try export())
        let olderRestorePaused = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(olderRestorePaused)
        model.importJournal(data: try export())
        await waitForCurrentFailure(model)

        XCTAssertFalse(model.isImporting, "the newer refusal owns the import message")
        XCTAssertFalse(model.canExport, "the older restore still owns the store write")
        XCTAssertFalse(model.export(now: now))
        XCTAssertTrue(written.isEmpty)

        journal.resumeRestoreForTesting.signal()
        let deadline = Date(timeIntervalSinceNow: 10)
        while !model.canExport, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(model.canExport, "export should return after every restore completion")
        XCTAssertTrue(model.export(now: now))
        XCTAssertEqual(model.entryCount, 1)
        XCTAssertEqual(written.count, 1)
    }

    func testAFileThatCannotBeReadIsAFailureRatherThanACancellation() {
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: ImportStubStore(), favorites: ImportStubFavorites())
        model.importCouldNotReadFile()

        XCTAssertEqual(model.importState, .failed)
        XCTAssertNil(model.importSummary)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importFailedMessage)
    }

    func testAnOversizedImportExplainsThatTheFileExceedsTheLimit() {
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importFailureText(for: .tooLarge),
            "This journal export is too large to import.")
    }

    func testAnOversizedSelectedFileIsRefusedWithoutChangingEitherStore() throws {
        let journal = ImportStubStore()
        let favorites = ImportStubFavorites()
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: journal, favorites: favorites)

        model.importFileTooLarge()

        XCTAssertEqual(model.importState, .failed)
        XCTAssertNil(model.importSummary)
        XCTAssertEqual(model.importMessage, "This journal export is too large to import.")
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try favorites.list().isEmpty)
    }

    /// Stores on disk, so an erase that runs beside a restore is testing the real files.
    private func diskStores() throws -> (SwiftDataJournalStore, SwiftDataFavoritesStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        )
    }

    /// An eraser that asks for an import in the middle of an erase, which is the window the refusal is for.
    private final class EraserThatStartsAnImport: JournalErasing, @unchecked Sendable {
        var model: ConnectionsPrivacyViewModel?
        var data: Data?

        let erasureName = "journal"

        func eraseAll() throws {
            // The erase runs on the main actor, so this is the main actor: exactly the moment an import must
            // not be allowed to start.
            MainActor.assumeIsolated {
                guard let model, let data else { return }
                model.importJournal(data: data)
            }
        }
    }

    func testAnEraseAfterAStartedImportLeavesTheStoresEmpty() async throws {
        // The two write the same journal. Run together they could land in either order, and "erase
        // everything" that a restore then undoes is the failure this guards: the erase waits for the restore
        // it found in flight, so the journal it empties is the one the import wrote.
        let (journal, favoritesStore) = try diskStores()
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favoritesStore, erasers: [journal, favoritesStore], remover: { _ in })
        model.importJournal(data: try export())

        let eraseResult1 = await model.eraseAllData()
        XCTAssertTrue(eraseResult1)

        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try journal.pendingOutbox().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
        // And the import's own outcome is dropped rather than shown: it would describe a journal that is gone.
        XCTAssertNotEqual(model.importState, .imported)
        XCTAssertNil(model.importSummary)
        XCTAssertEqual(model.journalRestoreGeneration, 0)
    }

    func testEraseFenceSuppressesAnInFlightPartialWarning() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        journal.pauseAfterRestoreForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, erasers: [journal, favorites])

        model.importJournal(data: try export(includeFavorite: true))
        let restorePaused = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(restorePaused)

        let resumeRestore = journal.resumeRestoreForTesting
        let release = Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            resumeRestore.signal()
        }
        let erased = await model.eraseAllData()
        await release.value
        XCTAssertTrue(erased)
        await Task.yield()

        XCTAssertNil(model.incompleteRestoreWarning)
        XCTAssertEqual(model.journalRestoreGeneration, 0)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertEqual(model.eraseGeneration, 1)
    }

    /// Waits, off the main actor, until the gate reports every import it knows about has finished, or the time runs out.
    private func awaitImport(_ gate: ImportGate, within seconds: TimeInterval = 5) async -> Bool {
        await Task.detached { gate.wait(upTo: seconds) }.value
    }

    /// An import that is still running when the wait ends leaves the erase with nothing erased, and offers Retry.
    func testAnErasePastItsWaitErasesNothingAndOffersRetry() async throws {
        let journal = ImportStubStore()
        journal.pauseBeforeRestoreForTesting = true
        let gate = ImportGate()
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, erasers: [journal], importWaitSeconds: 0.05, importGate: gate)

        model.importJournal(data: try export(includeFavorite: false))
        let restorePaused = await waitForSignal(journal.restorePausedBeforeWriteForTesting)
        XCTAssertTrue(restorePaused)

        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseNothingErasedMessage)
        XCTAssertTrue(model.eraseRetryAvailable)
        // The import is paused, so the gate still reports it busy: the timed-out erase did not stop it.
        let finishedEarly = await awaitImport(gate, within: 0.01)
        XCTAssertFalse(finishedEarly)
        XCTAssertEqual(journal.clearRestoreCallsForTesting, 0, "a timed-out erase must not touch the restore flag")

        journal.resumeRestoreBeforeWriteForTesting.signal()
        let finished = await awaitImport(gate)
        XCTAssertTrue(finished)
        // The gate clears on the import thread; the outcome reaches the model on the main actor afterwards.
        await waitForImportToSettle(model)
        // The import finishes after the timed-out erase and its effects are applied, not dropped.
        XCTAssertEqual(model.journalRestoreGeneration, 1)
        // Each effect of the import ran exactly once: one restore, one generation bump.
        XCTAssertEqual(journal.restoredPlans.count, 1)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])
    }

    /// The restore flag is cleared once the import has finished. A failed clear then cancels nothing, erases
    /// nothing, and offers Retry; the import completes and its rows stay.
    func testAFailedFlagClearAfterTheImportFinishesCancelsNothing() async throws {
        let journal = ImportStubStore()
        journal.pauseBeforeRestoreForTesting = true
        let gate = ImportGate()
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: journal, erasers: [journal], importGate: gate)

        model.importJournal(data: try export(includeFavorite: false))
        let restorePaused = await waitForSignal(journal.restorePausedBeforeWriteForTesting)
        XCTAssertTrue(restorePaused)

        // The import finishes first, so its own flag clears have run; only the erase's clear fails from here on.
        journal.resumeRestoreBeforeWriteForTesting.signal()
        let finished = await awaitImport(gate)
        XCTAssertTrue(finished)
        // The gate clears on the import thread; the outcome reaches the model on the main actor afterwards.
        await waitForImportToSettle(model)
        journal.failClearRestoreForTesting = true
        let erased = await model.eraseAllData()

        XCTAssertFalse(erased)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseNothingErasedMessage)
        XCTAssertTrue(model.eraseRetryAvailable)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])
    }

    func testFailedErasePublishesPartialRestoreThatCompletesDuringOrAfterErase() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        journal.failEraseForTesting = true
        journal.pauseAfterRestoreForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, erasers: [journal, favorites],
            eraseLocalAccount: {
                // Keep the erase suspended long enough for the import's main-actor completion to arrive.
                try await Task.sleep(nanoseconds: 500_000_000)
                throw ImportStubStore.Unsupported()
            })

        model.importJournal(data: try export(includeFavorite: true))
        let restorePaused = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(restorePaused)
        let resumeRestore = journal.resumeRestoreForTesting
        Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            resumeRestore.signal()
        }

        let erased = await model.eraseAllData()

        XCTAssertFalse(erased)
        XCTAssertEqual(
            model.errorMessage,
            ConnectionsPrivacyViewModel.eraseLeftBehindMessage(["community sign-in", "journal"]))
        XCTAssertEqual(model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)
        XCTAssertEqual(model.journalRestoreGeneration, 1)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])
    }

    /// The success side of the deferred-effect path: an import that completes while a successful erase is suspended
    /// is dropped, so its partial-restore warning never reaches the screen after the journal is gone.
    ///
    /// Signals hold the timing, not sleeps: the account step keeps the erase suspended until the import's outcome has
    /// been applied, which writes `isImporting`. An outcome that arrives before the erase starts or after it ends never
    /// satisfies that wait, so the test fails instead of passing without the deferred path.
    func testImportCompletingDuringASuccessfulEraseIsDiscarded() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        journal.pauseAfterRestoreForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        var eraseUnderway = false
        var importWritesDuringErase = 0
        var outcomeArrivedDuringErase = false
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, erasers: [journal, favorites],
            beforeErase: { eraseUnderway = true },
            eraseLocalAccount: {
                // Hold the erase here until the import's outcome has been applied on the main actor.
                let deadline = Date(timeIntervalSinceNow: 10)
                while importWritesDuringErase == 0, Date() < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                outcomeArrivedDuringErase = importWritesDuringErase > 0
            })
        let importWrites = model.$isImporting.sink { _ in
            if eraseUnderway { importWritesDuringErase += 1 }
        }
        defer { importWrites.cancel() }

        model.importJournal(data: try export(includeFavorite: true))
        let restorePaused = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(restorePaused)
        // The outcome needs the main actor, which the erase holds until it suspends in the account step.
        journal.resumeRestoreForTesting.signal()

        let erased = await model.eraseAllData()

        XCTAssertTrue(outcomeArrivedDuringErase, "the import's outcome did not arrive while the erase was suspended")
        XCTAssertTrue(erased)
        XCTAssertNil(model.incompleteRestoreWarning)
        XCTAssertEqual(model.journalRestoreGeneration, 0)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    func testSuccessfulJournalEraseDiscardsDeferredWarningDespiteLaterEraserFailure() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        journal.pauseAfterRestoreForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites,
            erasers: [journal, favorites, FailingAncillaryEraser()],
            eraseLocalAccount: {
                // Let the partial import outcome arrive during the erase, before the journal is erased.
                try await Task.sleep(nanoseconds: 500_000_000)
            })

        model.importJournal(data: try export(includeFavorite: true))
        let restorePaused = await waitForSignal(journal.restorePausedForTesting)
        XCTAssertTrue(restorePaused)
        let resumeRestore = journal.resumeRestoreForTesting
        let release = Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            resumeRestore.signal()
        }

        let erased = await model.eraseAllData()
        await release.value

        XCTAssertFalse(erased, "the unrelated ancillary eraser still fails the overall operation")
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseLeftBehindMessage(["test store"]))
        XCTAssertNil(model.incompleteRestoreWarning)
        XCTAssertEqual(model.journalRestoreGeneration, 0)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    func testSuccessfulEraseClearsAnExistingIncompleteRestoreWarning() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, erasers: [journal, favorites])

        await importAndSettle(model, data: try export(includeFavorite: true))
        XCTAssertEqual(model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)

        let erased = await model.eraseAllData()
        XCTAssertTrue(erased)
        XCTAssertNil(model.incompleteRestoreWarning)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try favorites.list().isEmpty)
    }

    func testFailedEraseKeepsAnExistingIncompleteRestoreWarning() async throws {
        let journal = ImportStubStore()
        journal.failUndoForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favorites, erasers: [journal, favorites])

        await importAndSettle(model, data: try export(includeFavorite: true))
        XCTAssertEqual(model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)

        journal.failEraseForTesting = true
        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)
        XCTAssertEqual(model.incompleteRestoreWarning, ConnectionsPrivacyViewModel.partialRestoreWarningMessage)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [entryID])
    }

    func testAnImportStartedWhileAnEraseRunsIsRefused() async throws {
        let (journal, favoritesStore) = try diskStores()
        let eraser = EraserThatStartsAnImport()
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: journal, favorites: favoritesStore, erasers: [eraser, journal, favoritesStore],
            remover: { _ in })
        eraser.model = model
        eraser.data = try export()

        let eraseResult2 = await model.eraseAllData()
        XCTAssertTrue(eraseResult2)

        // Queuing it instead would have restored a journal the person had just erased.
        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importDuringEraseMessage)
        XCTAssertFalse(model.isImporting)
        XCTAssertNil(model.importSummary)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    /// Starts an import and waits for it to publish. The restore runs off the main actor and publishes its
    /// outcome back on it, so the assertions have to run after that hop rather than straight after the call.
    /// The wait is on time, not on a number of yields: a yield is a scheduling hint, not a bound, and how
    /// many of them fit into a millisecond depends on the machine. The deadline is generous so a slow store
    /// does not fail the test, and bounded so a publish that never arrives fails it instead of hanging.
    private func importAndSettle(_ model: ConnectionsPrivacyViewModel, data: Data) async {
        model.importJournal(data: data)
        XCTAssertTrue(model.isImporting, "the screen can show restore progress while stores are being written")
        let deadline = Date(timeIntervalSinceNow: 10)
        while model.importState == .idle, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotEqual(model.importState, .idle, "the import never published an outcome")
        XCTAssertFalse(model.isImporting)
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await Task.detached {
            semaphore.wait(timeout: .now() + 2) == .success
        }.value
    }

    private func waitForCurrentFailure(_ model: ConnectionsPrivacyViewModel) async {
        let deadline = Date(timeIntervalSinceNow: 10)
        while (model.importState != .failed || model.isImporting), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitForImportToSettle(_ model: ConnectionsPrivacyViewModel) async {
        let deadline = Date(timeIntervalSinceNow: 10)
        while model.isImporting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.isImporting, "the import never published an outcome")
    }

    /// The picker path: a version 8 file that carries a goal is restored into the injected goal store. Fails when the
    /// view model's import call drops the goals argument, since the file is then refused and no goal is written.
    func testThePickerRestoresAGoalFromAVersionEightFile() async throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: try export()) as? [String: Any])
        root["goals"] = [["nutrient": "energy", "target": "2000", "unit": "kcal"]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let goals = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        addTeardownBlock { goals.close() }
        let model = ConnectionsPrivacyViewModel(goals: goals, store: ImportStubStore())

        await importAndSettle(model, data: data)

        XCTAssertEqual(model.importState, .imported)
        XCTAssertEqual(try goals.goal(for: "energy")?.target, Decimal(2000))
    }

    /// A write that failed and was rolled back says nothing was imported. The generic wording would tell the person the
    /// file was bad. Fails when the rolledBack case is mapped back to the generic message.
    func testARolledBackFailureSaysNothingWasImported() {
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importFailureText(for: .rolledBack), "Nothing was imported. Try again.")
    }

    /// A file that cannot be read is still reported as a bad file.
    func testAMalformedFileStillSaysItCouldNotBeImported() {
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importFailureText(for: .malformed("x")), "Could not import that file.")
    }

    /// The success line counts goals, with the singular and plural forms, and leaves them out at zero.
    func testTheSuccessLineCountsGoals() {
        let one = JournalImportSummary(
            intakes: 1, revisions: 1, tombstones: 0, favorites: 0, products: 0, goals: 2)
        XCTAssertEqual(ConnectionsPrivacyViewModel.importSummaryText(one, locale: Locale(identifier: "en_US")), "Imported 1 entry, 2 goals.")
        let none = JournalImportSummary(intakes: 1, revisions: 1, tombstones: 0, favorites: 0, products: 0)
        XCTAssertEqual(ConnectionsPrivacyViewModel.importSummaryText(none, locale: Locale(identifier: "en_US")), "Imported 1 entry.")
    }

    /// Every count in the success line is grouped in the locale the screen uses, pinned to en_US here so the result is
    /// the same on any runner. Fails when the count drops its grouping and prints the bare number.
    func testTheSuccessLineGroupsEveryCount() {
        let summary = JournalImportSummary(
            intakes: 1234, revisions: 1234, tombstones: 0, favorites: 0, products: 0, goals: 1000)
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importSummaryText(summary, locale: Locale(identifier: "en_US")),
            "Imported 1,234 entries, 1,000 goals.")
    }

    /// A saved meal the phone keeps shows its own message, the one that says why, not the generic one. The engine test
    /// pins the exact error case, and this pins the text that case shows.
    func testASavedMealsRefusalShowsItsOwnMessage() {
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importFailureText(for: .savedMealsNotEmpty),
            "This device already has saved meals. An import that includes saved meals only works when there are none.")
        XCTAssertNotEqual(
            ConnectionsPrivacyViewModel.importFailureText(for: .savedMealsNotEmpty),
            ConnectionsPrivacyViewModel.importRolledBackMessage)
    }

    /// A rollback whose undo fails keeps the restore flag, so a re-import of the same file resumes instead of refusing as
    /// not empty. Fails when the flag is cleared on a failed undo, since the re-import is then refused.
    func testAFailedUndoKeepsTheFlagSoAReimportResumes() throws {
        let journal = ImportStubStore()
        journal.recordsRestoreFlag = true
        journal.failUndoForTesting = true
        let favorites = ImportStubFavorites()
        favorites.failRestoreForTesting = true
        let data = try export(includeFavorite: true)

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favorites)) {
            guard case JournalImportError.partialRestore = $0 else {
                return XCTFail("expected partialRestore, got \($0)")
            }
        }
        XCTAssertNotNil(try journal.restoreInProgressDigest(), "a failed undo keeps the flag for a resume")

        favorites.failRestoreForTesting = false
        var summary: JournalImportSummary?
        XCTAssertNoThrow(summary = try JournalImporter.importExport(data, into: journal, favorites: favorites))
        XCTAssertEqual(summary?.favorites, 1, "the resume restores the favorite")
        XCTAssertNil(try journal.restoreInProgressDigest(), "the finished resume clears its flag")
    }

    // MARK: - The Health delivery gate (#982)

    private func gatedModel(
        _ journal: ImportStubStore, gate: DeliveryRunGate, waitSeconds: TimeInterval = 5
    ) -> ConnectionsPrivacyViewModel {
        ConnectionsPrivacyViewModel(
            goals: InMemoryGoalStore(), store: journal, favorites: ImportStubFavorites(),
            deliveryGate: gate, deliveryWaitSeconds: waitSeconds)
    }

    /// A restore that finds a Health pass running writes nothing until the pass ends, then restores.
    func testARestoreWaitsForARunningHealthPassBeforeWriting() async throws {
        let gate = DeliveryRunGate()
        let journal = ImportStubStore()
        let model = gatedModel(journal, gate: gate)
        await gate.enter() // a delivery pass is running
        model.importJournal(data: try export())
        XCTAssertTrue(model.isImporting, "the restore has started, so the check below is not vacuous")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(journal.restoredPlans.count, 0, "nothing is written while the pass runs")
        await gate.leave()
        await waitForImportToSettle(model)
        XCTAssertEqual(model.importState, .imported)
        XCTAssertEqual(journal.restoredPlans.count, 1)
    }

    /// A pass still running after the wait leaves the journal untouched, and the screen says why.
    func testARestoreGivesUpWithNothingImportedWhenAHealthPassIsStillRunning() async throws {
        let gate = DeliveryRunGate()
        let journal = ImportStubStore()
        let model = gatedModel(journal, gate: gate, waitSeconds: 0.05)
        await gate.enter()
        model.importJournal(data: try export())
        await waitForImportToSettle(model)
        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importDuringHealthDeliveryMessage)
        // The approved wording (Mike, 2026-10-28), pinned as a literal so a change to it is a visible test change.
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importDuringHealthDeliveryMessage,
            "Apple Health was still being updated, so nothing was imported. Try again in a moment.")
        XCTAssertEqual(journal.restoredPlans.count, 0, "nothing is imported")
        await gate.leave()
    }

    /// The restore lets go of the gate when it finishes, and a timed-out restore releases nothing the pass holds.
    func testARestoreReleasesTheGateAndNeverAPassesHold() async throws {
        let gate = DeliveryRunGate()
        let model = gatedModel(ImportStubStore(), gate: gate)
        model.importJournal(data: try export())
        await waitForImportToSettle(model)
        let free = await gate.pause(upTo: 0.5)
        XCTAssertNotNil(free, "the gate is free after the restore")
        await gate.resume(free)

        let held = DeliveryRunGate()
        let timedOut = gatedModel(ImportStubStore(), gate: held, waitSeconds: 0.05)
        await held.enter()
        timedOut.importJournal(data: try export())
        await waitForImportToSettle(timedOut)
        let stillHeld = await held.pause(upTo: 0.05)
        XCTAssertNil(stillHeld, "a timed-out restore does not release the running pass's hold")
        await held.leave()
    }
}
