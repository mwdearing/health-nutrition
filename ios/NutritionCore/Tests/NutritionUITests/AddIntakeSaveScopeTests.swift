import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeSaveScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testTypedInEntryIsDiaryOnly() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.name = "Example snack"
        model.amountText = "50"
        model.unit = .g
        XCTAssertEqual(model.saveScopeMessage, "Adds one entry to your Diary only.")
    }

    func testLabelProductIsAlsoSavedToProducts() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-label", productID: "example-label",
            name: "Example bar", labelBasis: "per serving", catalogOrigin: ProductOrigin.label_capture,
            catalogVersion: "1", nutrients: ["protein": .known(10, .g)]), fromLabelCapture: true)
        XCTAssertEqual(model.saveScopeMessage,
            "Adds one entry to your Diary. The product is also saved to Library > Products.")
    }
}

@MainActor
final class AddIntakeLibrarySwitchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func labelProduct() -> ProductDefinition {
        ProductDefinition(snapshotID: "example-label", productID: "example-label", name: "Example bar",
            labelBasis: "per serving", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "1",
            nutrients: ["protein": .known(10, .g)])
    }

    func testSwitchOffKeepsTheProductOutOfProductsButKeepsTheEntry() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now)
        model.applyLabelProduct(labelProduct(), fromLabelCapture: true)
        model.name = "Example bar"
        model.amountText = "30"
        model.savesToLibrary = false
        XCTAssertTrue(model.save(now: now))
        XCTAssertEqual(try store.intakeIDsNotSavedToLibrary().count, 1)
        XCTAssertEqual(try store.activeIntakes().count, 1)
    }

    func testSwitchOnWritesNoExclusion() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now)
        model.applyLabelProduct(labelProduct(), fromLabelCapture: true)
        model.name = "Example bar"
        model.amountText = "30"
        XCTAssertTrue(model.save(now: now))
        XCTAssertTrue(try store.intakeIDsNotSavedToLibrary().isEmpty)
    }

    func testTypedEntryHasNoSwitch() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.name = "Example snack"
        XCTAssertFalse(model.canChooseLibrary)
    }
}

@MainActor
final class LibraryExclusionStoreTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func product() -> ProductDefinition {
        ProductDefinition(snapshotID: "example-label", productID: "example-label", name: "Example bar",
            labelBasis: "per 100 g", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "1",
            nutrients: ["protein": .known(10, .g)])
    }

    private func logBar(_ store: SwiftDataJournalStore, id: String) throws {
        try store.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 1, unit: .g)],
            product: product(), now: when)
    }

    /// A failed save writes no entry, and its exclusion is not left behind.
    func testFailedSaveLeavesNoEntryAndNoExclusion() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: when)
        model.applyLabelProduct(product(), fromLabelCapture: true)
        model.name = "Example bar"
        model.amountText = "1"
        model.savesToLibrary = false
        store.failNextSaveForTesting = true
        XCTAssertFalse(model.save(now: when))
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.intakeIDsNotSavedToLibrary().isEmpty)
    }

    /// If an exclusion outlives an entry that never saved, it names an id no entry has, so a later entry
    /// saved to Library keeps its Library item.
    func testLeftoverExclusionDoesNotHideALaterEntry() throws {
        let store = try makeStore()
        let orphan = UUID().uuidString.lowercased()
        try store.keepOutOfLibrary(intakeID: orphan)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try logBar(store, id: orphan))
        let later = UUID().uuidString.lowercased()
        try logBar(store, id: later)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [later])
        XCTAssertFalse(try store.intakeIDsNotSavedToLibrary().contains(later))
    }
}

@MainActor
final class LibraryChoiceExportTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func product() -> ProductDefinition {
        ProductDefinition(snapshotID: "example-label", productID: "example-label", name: "Example bar",
            labelBasis: "per 100 g", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "1",
            nutrients: ["protein": .known(10, .g)])
    }

    private func logBar(_ store: SwiftDataJournalStore, id: String) throws {
        try store.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 1, unit: .g)],
            product: product(), now: when)
    }

    /// A version 5 backup keeps a switched-off entry out of Products after a restore.
    func testVersion5RoundTripKeepsASwitchedOffEntryOutOfProducts() throws {
        let id = UUID().uuidString.lowercased()
        let source = try makeStore()
        try logBar(source, id: id)
        try source.keepOutOfLibrary(intakeID: id)
        let data = try JournalExporter.encode(
            JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: when))
        let restored = try makeStore()
        _ = try JournalImporter.importExport(data, into: restored, favorites: nil)
        XCTAssertEqual(try restored.intakeIDsNotSavedToLibrary(), [id])
    }

    /// Repeating an entry kept out of Library keeps the copy out of Library too.
    func testRepeatOfASwitchedOffEntryStaysOutOfProducts() throws {
        let id = UUID().uuidString.lowercased()
        let store = try makeStore()
        try logBar(store, id: id)
        try store.keepOutOfLibrary(intakeID: id)
        let original = try XCTUnwrap(try store.activeIntakes().first { $0.id == id })
        let copyID = try IntakeRepeater(
            store: store, timeZoneProvider: { "UTC" }, makeID: { UUID().uuidString.lowercased() }
        ).create(repeating: original, now: when)
        XCTAssertEqual(try store.intakeIDsNotSavedToLibrary(), [id, copyID])
    }

    /// A version 4 backup has no choices, so every entry it restores is saved to Library.
    func testVersion4ImportSavesEveryEntryToLibrary() throws {
        let id = UUID().uuidString.lowercased()
        let source = try makeStore()
        try logBar(source, id: id)
        try source.keepOutOfLibrary(intakeID: id)
        var document = try JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: when)
        document.schemaVersion = 4
        let data = try JournalExporter.encode(document)
        let restored = try makeStore()
        _ = try JournalImporter.importExport(data, into: restored, favorites: nil)
        XCTAssertEqual(try restored.activeIntakes().map(\.id), [id])
        XCTAssertTrue(try restored.intakeIDsNotSavedToLibrary().isEmpty)
    }
}
