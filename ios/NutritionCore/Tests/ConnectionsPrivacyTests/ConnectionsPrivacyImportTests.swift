import Foundation
import NutritionDomain
import NutritionJournal
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
    @unchecked Sendable
{
    struct Unsupported: Error {}

    var failNextSaveForTesting = false
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
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String, now: Date
    ) throws -> IntakeRevision { throw Unsupported() }

    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { intakes }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { revisionsByIntake[intakeID] ?? [] }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { products[snapshotID] }
    func activeIntakesFromBackground() async throws -> [Intake] { try activeIntakes() }
    func close() {}
    func deletedIntakes() throws -> [Intake] { deleted }

    /// The real store refuses a journal that already holds an intake row, from inside its own transaction,
    /// and the importer reports whatever the store throws. The screen is what these tests are about, so the
    /// stub refuses exactly as the store does and lets the refusal travel the same path.
    func restore(_ plan: JournalRestorePlan) throws -> JournalRestoreReceipt {
        guard intakes.isEmpty, deleted.isEmpty else { throw JournalImportError.notEmpty }
        restoredPlans.append(plan)
        intakes.append(contentsOf: plan.entries.map(\.intake))
        for entry in plan.entries {
            revisionsByIntake[entry.intake.id] = entry.revisions
        }
        deleted.append(contentsOf: plan.tombstones)
        return JournalRestoreReceipt(intakes: [], insertedProductSnapshotIDs: [])
    }

    func undoRestore(_ receipt: JournalRestoreReceipt) throws {
        intakes.removeAll()
        deleted.removeAll()
        revisionsByIntake = [:]
    }
}

private final class ImportStubFavorites: FavoritesStore, @unchecked Sendable {
    var items: [FavoriteTemplate] = []

    func add(_ favorite: FavoriteTemplate) throws { items.append(favorite) }
    func remove(id: String) throws { items.removeAll { $0.id == id } }
    func list() throws -> [FavoriteTemplate] { items }
    func contains(id: String) throws -> Bool { items.contains { $0.id == id } }
    func close() {}
}

@MainActor
final class ConnectionsPrivacyImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_705_313_700)
    private let entryID = "1f0c9d2a-6b3e-4a7f-9c5d-0e2b6f8a1d33"

    /// A version 1 export with one entry, as the screen would have been handed by a file picker.
    private func export() throws -> Data {
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
        return try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: journal, favorites: nil, appVersion: "0.1.0", exportedAt: now))
    }

    func testASuccessfulImportPublishesTheSummaryAndRestoresTheJournal() async throws {
        let journal = ImportStubStore()
        let model = ConnectionsPrivacyViewModel(store: journal, favorites: ImportStubFavorites())
        await importAndSettle(model, data: try export())

        XCTAssertEqual(model.importState, .imported)
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
        let model = ConnectionsPrivacyViewModel(store: journal, favorites: ImportStubFavorites())
        await importAndSettle(model, data: try export())

        XCTAssertEqual(model.importState, .failed)
        XCTAssertNil(model.importSummary)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importNotEmptyMessage)
        XCTAssertTrue(journal.restoredPlans.isEmpty, "a refused import writes nothing")
    }

    func testASuccessfulImportRemovesTheStaleExportThisScreenWasHolding() async throws {
        var written: [URL] = []
        var removed: [URL] = []
        let model = ConnectionsPrivacyViewModel(
            store: ImportStubStore(), favorites: ImportStubFavorites(),
            writer: { _, url, _ in written.append(url) },
            erasers: [],
            remover: { url in removed.append(url) })
        XCTAssertTrue(model.export(now: now))
        let exportedURL = try XCTUnwrap(model.exportFileURL)
        XCTAssertEqual(written, [exportedURL])
        XCTAssertEqual(model.entryCount, 1)
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

    func testAFileThatCannotBeReadIsAFailureRatherThanACancellation() {
        let model = ConnectionsPrivacyViewModel(store: ImportStubStore(), favorites: ImportStubFavorites())
        model.importCouldNotReadFile()

        XCTAssertEqual(model.importState, .failed)
        XCTAssertNil(model.importSummary)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importFailedMessage)
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

        func eraseAll() throws {
            // The erase runs on the main actor, so this is the main actor: exactly the moment an import must
            // not be allowed to start.
            MainActor.assumeIsolated {
                guard let model, let data else { return }
                model.importJournal(data: data)
            }
        }
    }

    func testAnEraseAfterAStartedImportLeavesTheStoresEmpty() throws {
        // The two write the same journal. Run together they could land in either order, and "erase
        // everything" that a restore then undoes is the failure this guards: the erase waits for the restore
        // it found in flight, so the journal it empties is the one the import wrote.
        let (journal, favoritesStore) = try diskStores()
        let model = ConnectionsPrivacyViewModel(
            store: journal, favorites: favoritesStore, erasers: [journal, favoritesStore], remover: { _ in })
        model.importJournal(data: try export())

        XCTAssertTrue(model.eraseAllData())

        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try journal.pendingOutbox().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
        // And the import's own outcome is dropped rather than shown: it would describe a journal that is gone.
        XCTAssertNotEqual(model.importState, .imported)
        XCTAssertNil(model.importSummary)
    }

    func testAnImportStartedWhileAnEraseRunsIsRefused() throws {
        let (journal, favoritesStore) = try diskStores()
        let eraser = EraserThatStartsAnImport()
        let model = ConnectionsPrivacyViewModel(
            store: journal, favorites: favoritesStore, erasers: [eraser, journal, favoritesStore],
            remover: { _ in })
        eraser.model = model
        eraser.data = try export()

        XCTAssertTrue(model.eraseAllData())

        // Queuing it instead would have restored a journal the person had just erased.
        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importDuringEraseMessage)
        XCTAssertNil(model.importSummary)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    /// Starts an import and waits for it to publish. The restore runs off the main actor and publishes its
    /// outcome back on it, so the assertions have to run after that hop rather than straight after the call.
    /// The wait is bounded, so a publish that never arrives fails the test instead of hanging it.
    private func importAndSettle(_ model: ConnectionsPrivacyViewModel, data: Data) async {
        model.importJournal(data: data)
        for _ in 0..<2_000 {
            if model.importState != .idle { return }
            await Task.yield()
        }
        XCTFail("the import never published an outcome")
    }
}
