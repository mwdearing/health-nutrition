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

    /// A repeat carries the entry's note to the copy.
    func testRepeatKeepsTheEntryNote() throws {
        let id = UUID().uuidString.lowercased()
        let store = try makeStore()
        var intake = Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast")
        intake.note = "after the run"
        try store.create(
            intake,
            components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 1, unit: .g)],
            product: product(), now: when)
        let original = try XCTUnwrap(try store.activeIntakes().first { $0.id == id })
        let copyID = try IntakeRepeater(
            store: store, timeZoneProvider: { "UTC" }, makeID: { UUID().uuidString.lowercased() }
        ).create(repeating: original, now: when)
        let copy = try XCTUnwrap(try store.activeIntakes().first { $0.id == copyID })
        XCTAssertEqual(copy.note, "after the run")
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

    /// One tap on a Recents row repeats an entry kept out of Library without putting the copy into Products.
    func testOneTapFromRecentsKeepsAnExcludedEntryOutOfProducts() throws {
        let id = UUID().uuidString.lowercased()
        let store = try makeStore()
        try logBar(store, id: id)
        try store.keepOutOfLibrary(intakeID: id)
        let home = AddHomeViewModel(store: store, now: { self.when })
        home.load()
        let recent = try XCTUnwrap(home.recents.first)
        XCTAssertTrue(recent.template.keepsOutOfLibrary)
        let token = try XCTUnwrap(home.quickAdd(recent))
        XCTAssertEqual(try store.intakeIDsNotSavedToLibrary(), [id, token.intakeID])
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

    /// Starring a spoon-logged supplement keeps the unit with the favorite, so it still reads as logged.
    func testAFavoriteKeepsTheLoggedUnit() throws {
        let store = try makeStore()
        _ = try logFiber(store, unit: .teaspoon, amount: "4")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let library = LibraryViewModel(store: store, favorites: favorites)
        library.load()
        let recent = try XCTUnwrap(library.sections.first { $0.title == "Recents" }?.items.first)
        library.addFavorite(recent)
        let favorite = try XCTUnwrap(try favorites.list().first)
        XCTAssertEqual(try store.loggedUnits().filter { $0.intakeID == favorite.id }.map(\.unit), [.teaspoon])
        let template = try XCTUnwrap(RepeatTemplate(
            favorite: favorite, loggedUnitIndex: LoggedUnitIndex.load(from: store)))
        XCTAssertEqual(AmountText.summary(template.components, loggedUnits: template.loggedUnits), "4 tsp")
    }

    /// Typing a new amount over a spoon-logged entry forgets the spoon, so the entry reads as the unit system says
    /// instead of showing the new millimeters as spoons; an edit that changes no amount keeps it.
    func testEditingTheAmountForgetsTheLoggedUnit() throws {
        let store = try makeStore()
        let id = try logFiber(store, unit: .teaspoon, amount: "4")
        let detail = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        detail.load(now: now)
        let componentID = try XCTUnwrap(detail.components.first).id

        XCTAssertTrue(detail.saveDrafts(now: now))
        XCTAssertEqual(try store.loggedUnits().map(\.unit), [.teaspoon], "an untouched save keeps the unit")

        detail.drafts[componentID] = "250"
        XCTAssertTrue(detail.saveDrafts(now: now))
        XCTAssertTrue(try store.loggedUnits().isEmpty)
    }

    /// A time-only correction keeps the unit, and in an entry with two components only the edited one forgets it.
    func testATimeOnlyEditKeepsTheUnit() throws {
        let store = try makeStore()
        let id = try logFiber(store, unit: .teaspoon, amount: "4")
        let detail = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        detail.load(now: now)
        detail.occurredAt = detail.occurredAt.addingTimeInterval(-600)
        XCTAssertTrue(detail.saveDrafts(now: now))
        XCTAssertEqual(try store.loggedUnits().map(\.unit), [.teaspoon])
    }

    func testEditingOneComponentKeepsTheOthersUnit() throws {
        let store = try makeStore()
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC")
        try store.recordLoggedUnit(JournalLoggedUnit(intakeID: intake.id, componentID: "a", unit: .teaspoon))
        try store.recordLoggedUnit(JournalLoggedUnit(intakeID: intake.id, componentID: "b", unit: .tablespoon))
        try store.create(
            intake,
            components: [
                IntakeComponent(componentID: "a", name: "A", amount: Decimal(string: "9.8578431875")!, unit: .mL),
                IntakeComponent(componentID: "b", name: "B", amount: Decimal(string: "14.78676478125")!, unit: .mL),
            ], product: nil, now: now)
        let detail = EntryDetailViewModel(store: store, intakeID: intake.id, timeZoneIdentifier: "UTC")
        detail.load(now: now)
        detail.drafts["a"] = "20"
        XCTAssertTrue(detail.saveDrafts(now: now))
        XCTAssertEqual(try store.loggedUnits().map(\.componentID), ["b"])
    }

    /// Logging an entry again on other days carries the logged unit to each copy.
    func testLoggingOnOtherDaysKeepsTheLoggedUnit() throws {
        let store = try makeStore()
        let id = try logFiber(store, unit: .teaspoon, amount: "4")
        let result = try IntakeMultiDayLogger(store: store).log(
            intakeID: id, onDays: ["2023-11-12"], now: now.addingTimeInterval(86_400 * 10))
        XCTAssertEqual(result.createdIDs.count, 1)
        let copyID = try XCTUnwrap(result.createdIDs.first)
        XCTAssertTrue(try store.loggedUnits().contains { $0.intakeID == copyID && $0.unit == .teaspoon })
    }

    /// Repeating an entry logged by the spoon logs the same spoon again.
    func testRepeatingAnEntryKeepsTheLoggedUnit() throws {
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

    /// A version 6 file naming a unit outside tsp, tbsp, cup and fl oz is refused whole.
    func testAnImportedLoggedUnitOutsideTheContractIsRefused() throws {
        let source = try makeStore()
        _ = try logFiber(source, unit: .teaspoon, amount: "4")
        let data = try JournalExporter.encode(
            JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: now))
        for symbol in ["L", "g"] {
            var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var units = try XCTUnwrap(root["logged_units"] as? [[String: Any]])
            units[0]["unit"] = symbol
            root["logged_units"] = units
            let target = try makeStore()
            XCTAssertThrowsError(try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: target, favorites: nil), symbol)
            XCTAssertTrue(try target.activeIntakes().isEmpty)
        }
    }

    /// The same component listed twice is refused whole, and the exporter refuses to write a unit outside the four.
    func testADuplicateLoggedUnitIsRefusedAndTheEncoderChecksTheUnit() throws {
        let source = try makeStore()
        _ = try logFiber(source, unit: .teaspoon, amount: "4")
        let data = try JournalExporter.encode(
            JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: now))
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var units = try XCTUnwrap(root["logged_units"] as? [[String: Any]])
        var other = units[0]
        other["unit"] = "tbsp"
        units.append(other)
        root["logged_units"] = units
        let target = try makeStore()
        XCTAssertThrowsError(try JournalImporter.importExport(
            try JSONSerialization.data(withJSONObject: root), into: target, favorites: nil))
        XCTAssertTrue(try target.activeIntakes().isEmpty)

        var document = try JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: now)
        document.loggedUnits[0].unit = "L"
        XCTAssertThrowsError(try JournalExporter.encode(document))
    }

    /// A backup that carries a favorite carries its logged unit, and a restore writes it back under the same id.
    func testAFavoritesLoggedUnitSurvivesABackupAndRestore() throws {
        let source = try makeStore()
        _ = try logFiber(source, unit: .teaspoon, amount: "4")
        let sourceFavorites = try makeFavorites()
        let library = LibraryViewModel(store: source, favorites: sourceFavorites)
        library.load()
        library.addFavorite(try XCTUnwrap(library.sections.first { $0.title == "Recents" }?.items.first))
        let favoriteID = try XCTUnwrap(try sourceFavorites.list().first).id
        let data = try JournalExporter.encode(
            JournalExporter.makeExport(store: source, favorites: sourceFavorites, appVersion: "0.1.0", exportedAt: now))

        let restored = try makeStore()
        let restoredFavorites = try makeFavorites()
        _ = try JournalImporter.importExport(data, into: restored, favorites: restoredFavorites)
        XCTAssertTrue(try restored.loggedUnits().contains {
            $0.intakeID == favoriteID && $0.unit == .teaspoon
        })
    }

    /// A restore that carries no favorites leaves the phone's own favorites' units alone.
    func testARestoreKeepsTheUnitsOfFavoritesItDoesNotCarry() throws {
        let source = try makeStore()
        _ = try logFiber(source, unit: .g, amount: "5")
        let data = try JournalExporter.encode(
            JournalExporter.makeExport(store: source, appVersion: "0.1.0", exportedAt: now))
        let target = try makeStore()
        let own = JournalLoggedUnit(intakeID: "an-existing-favorite", componentID: "fiber-powder", unit: .teaspoon)
        try target.recordLoggedUnit(own)
        _ = try JournalImporter.importExport(data, into: target, favorites: nil)
        XCTAssertEqual(try target.loggedUnits(), [own])
    }

    /// A multi-item prefill names its amounts in the unit system, not a logged unit, unless it is a supplement.
    func testAMultiItemPrefillOfANonSupplementIgnoresLoggedUnits() throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setUnitSystem(.usCustomary)
        let home = AddHomeViewModel(store: try makeStore(), preferences: preferences, now: { self.now })
        let template = RepeatTemplate(
            displayName: "Mix", category: "food",
            components: [
                IntakeComponent(componentID: "a", name: "A", amount: Decimal(string: "19.715686375")!, unit: .mL),
                IntakeComponent(componentID: "b", name: "B", amount: 5, unit: .g),
            ],
            loggedUnits: ["a": .teaspoon])
        let details = try home.makeDetails(prefill: template, now: now)
        XCTAssertTrue(details.name.contains("0.6667 fl oz"), details.name)
        XCTAssertFalse(details.name.contains("tsp"), details.name)
    }

    private func makeFavorites() throws -> SwiftDataFavoritesStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
    }
}
