import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A journal store held in memory. `failReads` stands in for a store that cannot be read.
private final class StubStore: JournalStore, JournalTombstoneSource, @unchecked Sendable {
    struct Unsupported: Error {}
    struct ReadFailure: Error {}

    var failReads = false
    var failNextSaveForTesting = false
    var intakes: [Intake] = []
    var deleted: [Intake] = []
    var revisionsByIntake: [String: [IntakeRevision]] = [:]
    var products: [String: ProductDefinition] = [:]

    func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision { throw Unsupported() }

    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision { throw Unsupported() }

    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { if failReads { throw ReadFailure() } else { return intakes } }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { revisionsByIntake[intakeID] ?? [] }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { products[snapshotID] }
    func activeIntakesFromBackground() async throws -> [Intake] { try activeIntakes() }
    func close() {}
    func deletedIntakes() throws -> [Intake] { deleted }
}

private final class StubFavorites: FavoritesStore, @unchecked Sendable {
    var items: [FavoriteTemplate] = []

    func add(_ favorite: FavoriteTemplate) throws { items.append(favorite) }
    func remove(id: String) throws { items.removeAll { $0.id == id } }
    func list() throws -> [FavoriteTemplate] { items }
    func contains(id: String) throws -> Bool { items.contains { $0.id == id } }
    func close() {}
}

@MainActor
final class ConnectionsPrivacyViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_705_313_700)

    private func filledStore() -> StubStore {
        let store = StubStore()
        let id = "1f0c9d2a-6b3e-4a7f-9c5d-0e2b6f8a1d33"
        store.intakes = [
            Intake(
                id: id, category: "food", occurredAt: Date(timeIntervalSince1970: 1_705_264_200),
                timeZoneIdentifier: "Europe/Berlin", meal: "breakfast")
        ]
        store.revisionsByIntake[id] = [
            IntakeRevision(
                intakeID: id, number: 1,
                components: [IntakeComponent(componentID: "oats", name: "Oats", amount: Decimal(string: "37.5")!, unit: .g)],
                productSnapshotID: nil, changeReason: "created", createdAt: Date(timeIntervalSince1970: 1_705_264_200))
        ]
        return store
    }

    private func favorites() -> StubFavorites {
        let favorites = StubFavorites()
        favorites.items = [FavoriteTemplate(
            id: "fav-tea-1", displayName: "Sample tea", category: "drink",
            components: [FavoriteComponent(componentID: "tea", name: "Tea", amountText: "250", unitSymbol: "mL")])]
        return favorites
    }

    func testScreenStartsIdleWithNothingExportedAndNothingSent() {
        let model = ConnectionsPrivacyViewModel(store: filledStore(), favorites: favorites(), appVersion: "0.1.0")
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertNil(model.exportFileURL)
        XCTAssertNil(model.exportFileName)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertFalse(model.appleHealthEnabled)
        XCTAssertFalse(model.healthRelayEnabled)
    }

    func testBothConnectionsAreListedButUnavailableAndSwitchingThemOnStaysOff() {
        let model = ConnectionsPrivacyViewModel(store: filledStore())
        let connections = model.connections
        XCTAssertEqual(connections.map(\.title), ["Apple Health", "HealthRelay"])
        XCTAssertTrue(connections.allSatisfy { !$0.isAvailable })
        XCTAssertTrue(connections.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(connections.allSatisfy { !$0.arrivingNote.isEmpty })
        XCTAssertFalse(ConnectionsPrivacyViewModel.appleHealthAvailable)
        XCTAssertFalse(ConnectionsPrivacyViewModel.healthRelayAvailable)
        // Even if a switch were moved, an unavailable connection stays off.
        model.appleHealthEnabled = true
        model.healthRelayEnabled = true
        XCTAssertTrue(model.connections.allSatisfy { !$0.isEnabled })
    }

    func testPrivacyTextSaysDataStaysOnTheDeviceAndExportIsUserInitiated() {
        let model = ConnectionsPrivacyViewModel(store: filledStore())
        XCTAssertTrue(model.privacyText.contains("stays on this device"))
        XCTAssertTrue(model.privacyText.lowercased().contains("unless you ask"))
        XCTAssertTrue(model.privacyText.lowercased().contains("tap"))
    }

    func testExportWritesALocalFileThatDecodesAsVersionOne() throws {
        let model = ConnectionsPrivacyViewModel(
            store: filledStore(), favorites: favorites(), appVersion: "0.1.0")
        XCTAssertTrue(model.export(now: now))
        XCTAssertEqual(model.exportState, .ready)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entryCount, 1)
        let url = try XCTUnwrap(model.exportFileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.lastPathComponent, "journal-export-2024-01-15-101500.json")
        let document = try JournalExporter.decode(try Data(contentsOf: url))
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.appVersion, "0.1.0")
        XCTAssertEqual(document.intakes.count, 1)
        XCTAssertEqual(document.intakes.first?.revisions.first?.components.first?.amount, "37.5")
        XCTAssertEqual(document.favorites.first?.displayName, "Sample tea")
    }

    func testExportDoesNothingUntilItIsAskedFor() {
        let store = filledStore()
        let model = ConnectionsPrivacyViewModel(store: store, favorites: favorites())
        XCTAssertNil(model.exportFileURL)
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertTrue(model.export(now: now))
        let url = model.exportFileURL
        // Exporting twice just rewrites the same local file; it is not queued or sent anywhere.
        XCTAssertTrue(model.export(now: now))
        XCTAssertEqual(model.exportFileURL, url)
    }

    func testAFailedExportExplainsItselfAndClearsTheFile() throws {
        let store = filledStore()
        let model = ConnectionsPrivacyViewModel(store: store, favorites: favorites())
        XCTAssertTrue(model.export(now: now))
        let firstURL = try XCTUnwrap(model.exportFileURL)
        store.failReads = true
        XCTAssertFalse(model.export(now: now))
        XCTAssertEqual(model.exportState, .failed)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.exportFailedMessage)
        XCTAssertNil(model.exportFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    }

    func testExportingAgainInALaterSecondReplacesTheFileInsteadOfLeavingTheOldOne() throws {
        let model = ConnectionsPrivacyViewModel(store: filledStore(), favorites: favorites())
        XCTAssertTrue(model.export(now: now))
        let firstURL = try XCTUnwrap(model.exportFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        addTeardownBlock { try? FileManager.default.removeItem(at: firstURL) }
        // A second later the file name changes, so the first copy would otherwise stay in the temporary
        // directory with nothing left able to delete it.
        let later = now.addingTimeInterval(1)
        XCTAssertTrue(model.export(now: later))
        let secondURL = try XCTUnwrap(model.exportFileURL)
        XCTAssertNotEqual(secondURL, firstURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        // Only the current copy is left for clearExport() to remove.
        model.clearExport()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testExportingTwiceInTheSameSecondKeepsTheSingleFile() throws {
        let model = ConnectionsPrivacyViewModel(store: filledStore(), favorites: favorites())
        XCTAssertTrue(model.export(now: now))
        let url = try XCTUnwrap(model.exportFileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.export(now: now))
        XCTAssertEqual(model.exportFileURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTheExportedFileIsWrittenCompleteOnlyAndInOneStep() throws {
        // The file holds the whole journal, so it must be written complete-only and atomically. Reading the
        // file afterwards cannot prove that: on macOS the protection attribute comes back as
        // complete-until-first-authentication whatever was asked for, so the options themselves are checked.
        var seen: (url: URL, options: Data.WritingOptions)?
        var written: Data?
        let model = ConnectionsPrivacyViewModel(
            store: filledStore(), favorites: favorites(), appVersion: "0.1.0",
            writer: { data, url, options in
                seen = (url, options)
                written = data
            })
        XCTAssertTrue(model.export(now: now))
        let recorded = try XCTUnwrap(seen)
        XCTAssertEqual(recorded.url, model.exportFileURL)
        XCTAssertTrue(recorded.options.contains(.completeFileProtection), "\(recorded.options)")
        XCTAssertTrue(recorded.options.contains(.atomic), "\(recorded.options)")
        let document = try JournalExporter.decode(try XCTUnwrap(written))
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.intakes.count, 1)
        XCTAssertEqual(ConnectionsPrivacyViewModel.exportWriteOptions, [.atomic, .completeFileProtection])
    }

func testTheRealWriterLeavesADecodableFileBehind() throws {
        let model = ConnectionsPrivacyViewModel(store: filledStore(), favorites: favorites())
        XCTAssertTrue(model.export(now: now))
        let url = try XCTUnwrap(model.exportFileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let document = try JournalExporter.decode(try Data(contentsOf: url))
        XCTAssertEqual(document.schemaVersion, 1)
    }

func testClearingTheExportWhenTheScreenGoesAwayLeavesNothingOnDisk() throws {
        let model = ConnectionsPrivacyViewModel(store: filledStore(), favorites: favorites())
        XCTAssertTrue(model.export(now: now))
        let url = try XCTUnwrap(model.exportFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // What the screen's `onDisappear` calls.
        model.clearExport()
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertNil(model.exportFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Leaving and coming back to the screen must not resurrect the old file or its state.
        XCTAssertNil(model.exportFileName)
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertNil(model.errorMessage)
    }

func testTheExportActionStaysAvailableAfterAFailureSoItCanBeTriedAgain() {
        let store = filledStore()
        let model = ConnectionsPrivacyViewModel(store: store, favorites: favorites())
        store.failReads = true
        XCTAssertFalse(model.export(now: now))
        XCTAssertEqual(model.exportState, .failed)
        XCTAssertNotNil(model.errorMessage)
        // The only way out of a failure is another tap on the same button.
        XCTAssertTrue(model.canExport)
        store.failReads = false
        XCTAssertTrue(model.export(now: now))
        XCTAssertEqual(model.exportState, .ready)
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.exportFileURL)
    }

    func testClearExportReturnsTheScreenToItsEmptyStateAndRemovesTheFile() throws {
        let model = ConnectionsPrivacyViewModel(store: filledStore(), favorites: favorites())
        XCTAssertTrue(model.export(now: now))
        let url = try XCTUnwrap(model.exportFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        model.clearExport()
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertNil(model.exportFileURL)
        XCTAssertNil(model.exportFileName)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entryCount, 0)
        // The journal JSON holds the whole history, so forgetting it must delete it too.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearingWithoutAnExportIsHarmlessAndReportsNothing() {
        let model = ConnectionsPrivacyViewModel(store: filledStore(), favorites: favorites())
        model.clearExport()
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertNil(model.exportFileURL)
        XCTAssertNil(model.errorMessage)
    }

    func testTombstonesOfDeletedEntriesTravelWithTheExport() throws {
        let store = filledStore()
        let deletedID = "7d4a1c55-9e2b-4f60-8a3d-5c1b0f7e2a94"
        store.deleted = [
            Intake(
                id: deletedID, category: "food", occurredAt: Date(timeIntervalSince1970: 1_705_180_000),
                timeZoneIdentifier: "Europe/Berlin", lifecycle: .deleted)
        ]
        let model = ConnectionsPrivacyViewModel(store: store, favorites: favorites())
        XCTAssertTrue(model.export(now: now))
        let document = try JournalExporter.decode(try Data(contentsOf: try XCTUnwrap(model.exportFileURL)))
        XCTAssertEqual(document.tombstones.map(\.intakeID), [deletedID])
        XCTAssertEqual(model.entryCount, 1)
    }
}