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
    func edit(intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String, now: Date) throws -> IntakeRevision {
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
        let model = makeModel([journal, favorites, recipes])
        XCTAssertTrue(model.canEraseAll)

        XCTAssertTrue(model.eraseAllData())

        XCTAssertEqual(journal.eraseCount, 1)
        XCTAssertEqual(favorites.eraseCount, 1)
        XCTAssertEqual(recipes.eraseCount, 1)
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

    /// The confirmation the button is guarded by has to say what goes and that it cannot be undone.
    func testTheConfirmationTextSaysWhatIsRemovedAndThatItCannotBeUndone() {
        XCTAssertFalse(ConnectionsPrivacyViewModel.eraseConfirmationMessage.isEmpty)
        let message = ConnectionsPrivacyViewModel.eraseConfirmationMessage.lowercased()
        XCTAssertTrue(message.contains("entry"))
        XCTAssertTrue(message.contains("favorite"))
        XCTAssertTrue(message.contains("recipe"))
        XCTAssertTrue(message.contains("cannot be undone"))
        XCTAssertEqual(ConnectionsPrivacyViewModel.eraseButtonTitle, "Erase all data")
    }
}