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

@MainActor
final class LoggedUnitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func logFiber(_ store: SwiftDataJournalStore, unit: MeasureUnit, amount: String) throws -> String {
        let model = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        model.name = "Fiber Powder"
        model.amountText = amount
        model.unit = unit
        XCTAssertTrue(model.save(now: now))
        return try XCTUnwrap(store.activeIntakes().first).id
    }

    /// An amount typed in a spoon is stored as milliliters and its unit is recorded, so it can read back as typed.
    func testASpoonAmountIsStoredAsMillilitersAndItsUnitIsRecorded() throws {
        let store = try makeStore()
        let id = try logFiber(store, unit: .teaspoon, amount: "4")
        let component = try XCTUnwrap(store.revisions(of: id).first?.components.first)
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(component.amount, Decimal(string: "19.715686375"))
        XCTAssertEqual(
            try store.loggedUnits(),
            [JournalLoggedUnit(intakeID: id, componentID: component.componentID, unit: .teaspoon)])
    }

    /// A mass or a milliliter amount typed as such records nothing, so it reads as stored.
    func testAnAmountTypedInTheStoredUnitRecordsNoLoggedUnit() throws {
        let store = try makeStore()
        _ = try logFiber(store, unit: .g, amount: "5")
        XCTAssertTrue(try store.loggedUnits().isEmpty)
        let otherStore = try makeStore()
        _ = try logFiber(otherStore, unit: .mL, amount: "20")
        XCTAssertTrue(try otherStore.loggedUnits().isEmpty)
    }

    /// A backup carries the logged unit and a restore writes it back; a version 5 backup has none.
    func testALoggedUnitSurvivesABackupAndRestore() throws {
        let source = try makeStore()
        let id = try logFiber(source, unit: .teaspoon, amount: "4")
        let data = try JournalExporter.encode(
            JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: now))
        let restored = try makeStore()
        _ = try JournalImporter.importExport(data, into: restored, favorites: nil)
        XCTAssertEqual(try restored.loggedUnits().map(\.intakeID), [id])
        XCTAssertEqual(try restored.loggedUnits().map(\.unit), [.teaspoon])

        var older = try JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: now)
        older.schemaVersion = 5
        let target = try makeStore()
        _ = try JournalImporter.importExport(try JournalExporter.encode(older), into: target, favorites: nil)
        XCTAssertEqual(try target.activeIntakes().map(\.id), [id])
        XCTAssertTrue(try target.loggedUnits().isEmpty)
    }

    /// Repeating an entry logged by the spoon logs the same spoon again, and a prefill opens in it.
    func testRepeatingAndPrefillingKeepTheLoggedUnit() throws {
        let store = try makeStore()
        let id = try logFiber(store, unit: .teaspoon, amount: "4")
        let home = AddHomeViewModel(store: store, now: { self.now })
        home.load()
        let recent = try XCTUnwrap(home.recents.first)
        XCTAssertEqual(recent.template.loggedUnits.values.first, .teaspoon)
        let token = try XCTUnwrap(home.quickAdd(recent))
        XCTAssertEqual(
            Set(try store.loggedUnits().map(\.intakeID)), [id, token.intakeID])
    }
}
