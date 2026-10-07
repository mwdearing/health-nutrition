import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A journal store that is never asked to read anything here, so the erase test only exercises the
/// screen's own bookkeeping.
private final class EraseStubStore: JournalStore, @unchecked Sendable {
    private struct Unsupported: Error {}

    var failNextSaveForTesting = false

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        throw Unsupported()
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        throw Unsupported()
    }
    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { [] }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { [] }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { nil }
    func activeIntakesFromBackground() async throws -> [Intake] { [] }
    func close() {}
}

private final class EraseStubFavorites: FavoritesStore, @unchecked Sendable {
    struct Unsupported: Error {}
    func add(_ favorite: FavoriteTemplate) throws { throw Unsupported() }
    func remove(id: String) throws { throw Unsupported() }
    func list() throws -> [FavoriteTemplate] { [] }
    func contains(id: String) throws -> Bool { false }
    func close() {}
}

/// One injected store. `eraseCount` says the screen ran it; `failure` stands in for a store that
/// cannot erase, e.g. one that was closed.
private final class RecordingEraser: JournalErasing, @unchecked Sendable {
    var eraseCount = 0
    var failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func eraseAll() throws {
        eraseCount += 1
        if let failure { throw failure }
    }
}

private struct EraseFailure: Error {}
private struct RemoveFailure: Error {}

@MainActor
final class ConnectionsPrivacyEraseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_705_313_700)

    private func makeModel(_ erasers: [JournalErasing]) -> ConnectionsPrivacyViewModel {
        ConnectionsPrivacyViewModel(store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: erasers)
    }

    func testEraseAllDataRunsEveryInjectedStore() {
        let journal = RecordingEraser()
        let favorites = RecordingEraser()
        let recipes = RecordingEraser()
        let goals = RecordingEraser()
        let model = makeModel([journal, favorites, recipes, goals])
        XCTAssertTrue(model.canEraseAll)

        XCTAssertTrue(model.eraseAllData())

        XCTAssertEqual(journal.eraseCount, 1)
        XCTAssertEqual(favorites.eraseCount, 1)
        XCTAssertEqual(recipes.eraseCount, 1)
        // A daily goal is what the person is aiming at every day, so it goes with the entries it
        // was measured against rather than outliving them.
        XCTAssertEqual(goals.eraseCount, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entryCount, 0)
    }

    /// The exported copy holds the same history as the stores, so it is deleted rather than left in the
    /// temporary directory with nothing able to remove it.
    func testEraseAllDataRemovesTheExportFileAndResetsTheExportState() throws {
        let model = ConnectionsPrivacyViewModel(
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [RecordingEraser()])
        XCTAssertTrue(model.export(now: now))
        let url = try XCTUnwrap(model.exportFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(model.exportState, .ready)

        XCTAssertTrue(model.eraseAllData())

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(model.exportFileURL)
        XCTAssertNil(model.exportFileName)
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertNil(model.errorMessage)
    }

    /// One store that cannot erase must not stop the others, and the person has to be told that
    /// something was left behind.
    func testAStoreThatFailsIsReportedAndTheRestStillRun() {
        let failing = RecordingEraser(failure: EraseFailure())
        let working = RecordingEraser()
        let model = makeModel([failing, working])

        XCTAssertFalse(model.eraseAllData())

        XCTAssertEqual(failing.eraseCount, 1)
        XCTAssertEqual(working.eraseCount, 1)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseFailedMessage)
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertEqual(model.entryCount, 0)
    }

    /// With no store injected there is nothing to erase, so the screen does not offer the action at all
    /// rather than reporting that an erase it never ran succeeded.
    func testTheActionIsNotOfferedWithoutAnInjectedStore() {
        let model = makeModel([])
        XCTAssertFalse(model.canEraseAll)
        XCTAssertTrue(model.eraseAllData())
        XCTAssertNil(model.errorMessage)
    }

    /// An export this screen never made still belongs to the app and still holds the journal: the app
    /// can be killed after an export and relaunched into a model that has forgotten the URL. The erase
    /// has to sweep the temporary directory, not only the one file this model remembers.
    func testEraseRemovesEveryExportFileEvenOneThisScreenNeverWrote() throws {
        let writtenEarlier = ConnectionsPrivacyViewModel.exportFileURL(for: now.addingTimeInterval(-86_400))
        let stray = ConnectionsPrivacyViewModel.exportFileURL(for: now.addingTimeInterval(-172_800))
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-\(UUID().uuidString).txt")
        for url in [writtenEarlier, stray, unrelated] {
            try Data("{}".utf8).write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        }
        // A screen that has exported nothing this session, which is the case the finding is about.
        let model = makeModel([RecordingEraser()])
        XCTAssertNil(model.exportFileURL)

        XCTAssertTrue(model.eraseAllData())

        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenEarlier.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        // Only this app's own exports are removed: a file the app did not write is none of its business.
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// A name that only looks like an export is not this app's file, and an erase that deletes it would
    /// be destroying something it never wrote.
    func testEraseLeavesAMalformedExportNameAlone() throws {
        let malformed = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-export-.json")
        let shortStamp = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-export-2024-1-15-101500.json")
        for url in [malformed, shortStamp] {
            try Data("{}".utf8).write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        }
        let model = makeModel([RecordingEraser()])

        XCTAssertTrue(model.eraseAllData())

        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortStamp.path))
    }

    /// A file that cannot be removed is an erase that did not finish. Reporting success would promise a
    /// deletion that never happened, so the failure is reported like a store's.
    func testEraseReportsFailureWhenAnExportFileCannotBeRemoved() throws {
        let stray = ConnectionsPrivacyViewModel.exportFileURL(for: now.addingTimeInterval(-86_400))
        try Data("{}".utf8).write(to: stray)
        addTeardownBlock { try? FileManager.default.removeItem(at: stray) }
        let model = ConnectionsPrivacyViewModel(
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [RecordingEraser()],
            remover: { url in if url == stray { throw RemoveFailure() } })

        XCTAssertFalse(model.eraseAllData())

        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseFailedMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    /// The export names the sweep looks for have to be the names the exporter writes, or the sweep
    /// matches nothing and every strayed export survives. A name it matches wrongly is just as bad: it
    /// deletes a file this app never wrote.
    func testTheSweepPatternMatchesTheNamesTheExporterWrites() throws {
        let model = makeModel([RecordingEraser()])
        XCTAssertTrue(model.export(now: now.addingTimeInterval(-86_400)))
        let url = try XCTUnwrap(model.exportFileURL)
        let name = url.lastPathComponent
        XCTAssertTrue(ConnectionsPrivacyViewModel.exportFilePatternMatches(name), name)
        for rejected in [
            "journal-export-.json",
            "journal-export-2024-1-15-101500.json",
            "journal-export-2024-01-15-101500.txt",
            "journal-export-2024-01-15T101500.json",
            "some-other-export-2024-01-15-101500.json",
            "journal-export-2024-01-15-101500.json.bak",
            "journal-export-2024-99-99-999999.json",
            "journal-export-2024-02-30-101500.json",
        ] {
            XCTAssertFalse(ConnectionsPrivacyViewModel.exportFilePatternMatches(rejected), rejected)
        }
        model.eraseAllData()
    }

    /// The host has to be able to see that an erase happened, or the tabs showing cached entries reload
    /// only on some unrelated state change.
    func testErasingBumpsTheGenerationAHostWatches() {
        let model = makeModel([RecordingEraser()])
        XCTAssertEqual(model.eraseGeneration, 0)
        model.eraseAllData()
        XCTAssertEqual(model.eraseGeneration, 1)
        model.eraseAllData()
        XCTAssertEqual(model.eraseGeneration, 2)
    }

    /// The confirmation the button is guarded by has to say what goes and that it cannot be undone.
    func testTheConfirmationTextSaysWhatIsRemovedAndThatItCannotBeUndone() {
        XCTAssertFalse(ConnectionsPrivacyViewModel.eraseConfirmationMessage.isEmpty)
        let message = ConnectionsPrivacyViewModel.eraseConfirmationMessage.lowercased()
        XCTAssertTrue(message.contains("entry"))
        XCTAssertTrue(message.contains("favorite"))
        XCTAssertTrue(message.contains("recipe"))
        XCTAssertTrue(message.contains("goal"), "goals are erased too, so the warning says so")
        XCTAssertTrue(ConnectionsPrivacyViewModel.eraseFooterMessage.lowercased().contains("goal"))
        XCTAssertTrue(message.contains("cannot be undone"))
        XCTAssertEqual(ConnectionsPrivacyViewModel.eraseButtonTitle, "Erase all data")
    }

    /// A copy the person already shared or saved elsewhere is not reachable from here, and saying
    /// otherwise would let someone erase their journal and leave a shared copy behind not knowing.
    func testTheConfirmationAndFooterWarnThatASharedCopyIsNotErased() {
        let texts = [
            ConnectionsPrivacyViewModel.eraseConfirmationMessage,
            ConnectionsPrivacyViewModel.eraseFooterMessage,
        ]
        for text in texts {
            let message = text.lowercased()
            XCTAssertTrue(message.contains("shared") || message.contains("saved"), message)
            XCTAssertTrue(message.contains("files"), message)
            XCTAssertTrue(message.contains("mail"), message)
            XCTAssertTrue(message.contains("another app"), message)
            XCTAssertTrue(message.contains("delete it"), message)
            // The wording that made this false must not come back.
            XCTAssertFalse(message.contains("nothing has to be deleted"), message)
            XCTAssertFalse(message.contains("nothing needs deleting"), message)
            XCTAssertFalse(message.contains("nothing needs to be deleted"), message)
        }
    }
}