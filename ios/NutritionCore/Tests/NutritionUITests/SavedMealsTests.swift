import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A real journal whose second `create` fails, to show a failed write logs nothing.
private final class SecondCreateFailsStore: JournalStore, @unchecked Sendable {
    struct WriteFailed: Error {}
    let inner: SwiftDataJournalStore
    private var creates = 0
    /// Makes every delete fail too, as a closed store or a full disk would.
    var failDeletes = false

    init(_ inner: SwiftDataJournalStore) { self.inner = inner }

    var failNextSaveForTesting: Bool {
        get { inner.failNextSaveForTesting }
        set { inner.failNextSaveForTesting = newValue }
    }
    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        creates += 1
        if creates == 2 { throw WriteFailed() }
        return try inner.create(intake, components: components, product: product, now: now)
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        try inner.edit(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }

    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil, unitRemovals: [String])throws -> IntakeRevision {
        try inner.editRemovingUnits(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier, unitRemovals: unitRemovals)
    }
    func delete(intakeID: String, now: Date) throws {
        if failDeletes { throw WriteFailed() }
        try inner.delete(intakeID: intakeID, now: now)
    }
    func activeIntakes() throws -> [Intake] { try inner.activeIntakes() }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { try inner.revisions(of: intakeID) }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? { try inner.product(snapshotID: snapshotID) }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }
}

/// Saved meals: a named group of foods kept on this phone and logged together as ordinary entries.
///
/// Synthetic names and ids only. Lowercase UUID intake ids.
@MainActor
final class SavedMealsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDefaults() -> UserDefaults {
        let suite = "saved-meals-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func template(
        _ name: String, amount: Decimal = 40, unit: MeasureUnit = .g, meal: String? = "breakfast",
        snapshotID: String? = nil
    ) -> RepeatTemplate {
        RepeatTemplate(
            displayName: name, category: "food", meal: meal,
            components: [IntakeComponent(componentID: name.lowercased(), name: name, amount: amount, unit: unit)],
            productSnapshotID: snapshotID)
    }

    // MARK: Saving

    func testAddKeepsExactAmountsTrimsTheNameAndListsNewestFirst() throws {
        let book = SavedMealBook(store: UserDefaultsSavedMealStore(defaults: makeDefaults()))
        try book.add(name: "  Usual breakfast ", meal: .breakfast, templates: [template("Oats"), template("Milk", amount: 0.5, unit: .L)])
        try book.add(name: "Lunch box", meal: nil, templates: [template("Apple")])

        let meals = try book.meals()
        XCTAssertEqual(meals.map(\.name), ["Lunch box", "Usual breakfast"])
        XCTAssertEqual(meals[1].meal, .breakfast)
        XCTAssertEqual(meals[1].items.map(\.displayName), ["Oats", "Milk"])
        XCTAssertEqual(meals[1].items.flatMap(\.components).map(\.amountText), ["40", "0.5"])
        // The group's meal applies to every item, so no item keeps one of its own.
        XCTAssertEqual(meals[1].items.map(\.meal), [nil, nil])
    }

    func testRefusalsWriteNothing() throws {
        let store = UserDefaultsSavedMealStore(defaults: makeDefaults())
        let book = SavedMealBook(store: store)
        try book.add(name: "Usual breakfast", meal: .breakfast, templates: [template("Oats")])
        let cases: [(String, [RepeatTemplate], SavedMealError)] = [
            ("   ", [template("Oats")], .emptyName),
            (String(repeating: "a", count: SavedMealBook.maximumNameLength + 1), [template("Oats")], .nameTooLong),
            (" usual BREAKFAST ", [template("Oats")], .duplicateName),
            ("Empty", [], .itemCount),
            ("Too many", Array(repeating: template("Oats"), count: SavedMealBook.maximumItems + 1), .itemCount),
            ("Unknown amount", [template("Oats", amount: .nan)], .unsavableAmount),
            ("Zero amount", [template("Oats", amount: 0)], .unsavableAmount),
        ]
        for (name, templates, expected) in cases {
            XCTAssertThrowsError(try book.add(name: name, meal: nil, templates: templates), name) {
                XCTAssertEqual($0 as? SavedMealError, expected, name)
            }
        }
        XCTAssertEqual(try store.meals().map(\.name), ["Usual breakfast"])
    }

    func testRenameAndRemove() throws {
        let book = SavedMealBook(store: UserDefaultsSavedMealStore(defaults: makeDefaults()))
        let breakfast = try book.add(name: "Usual breakfast", meal: .breakfast, templates: [template("Oats")])
        let lunch = try book.add(name: "Lunch box", meal: .lunch, templates: [template("Apple")])

        // A meal may keep its own name in another case; it may not take another meal's.
        try book.rename(id: breakfast.id, to: "USUAL breakfast")
        XCTAssertThrowsError(try book.rename(id: lunch.id, to: "usual breakfast")) {
            XCTAssertEqual($0 as? SavedMealError, .duplicateName)
        }
        try book.remove(id: lunch.id)
        XCTAssertEqual(try book.meals().map(\.name), ["USUAL breakfast"])
        XCTAssertThrowsError(try book.remove(id: lunch.id)) { XCTAssertEqual($0 as? SavedMealError, .notFound) }
        XCTAssertThrowsError(try book.rename(id: lunch.id, to: "Lunch")) { XCTAssertEqual($0 as? SavedMealError, .notFound) }
    }

    func testADamagedListIsAnErrorNotAnEmptyList() throws {
        let defaults = makeDefaults()
        defaults.set(Data("not a list".utf8), forKey: UserDefaultsSavedMealStore.key)
        let store = UserDefaultsSavedMealStore(defaults: defaults)

        XCTAssertThrowsError(try store.meals()) { XCTAssertEqual($0 as? SavedMealError, .unreadable) }
        // Nothing is saved over a list that cannot be read.
        XCTAssertThrowsError(try SavedMealBook(store: store).add(name: "Oats", meal: nil, templates: [template("Oats")]))
        XCTAssertEqual(defaults.data(forKey: UserDefaultsSavedMealStore.key), Data("not a list".utf8))
    }

    func testAValueOfAnotherTypeIsAnErrorNotAnEmptyList() throws {
        let defaults = makeDefaults()
        defaults.set("not data", forKey: UserDefaultsSavedMealStore.key)

        XCTAssertThrowsError(try UserDefaultsSavedMealStore(defaults: defaults).meals()) {
            XCTAssertEqual($0 as? SavedMealError, .unreadable)
        }
    }

    func testTheListIsCappedAtTheMaximumNumberOfMeals() throws {
        let store = UserDefaultsSavedMealStore(defaults: makeDefaults())
        let book = SavedMealBook(store: store)
        for index in 1...SavedMealBook.maximumMeals {
            try book.add(name: "Meal \(index)", meal: nil, templates: [template("Oats")])
        }

        XCTAssertThrowsError(try book.add(name: "One more", meal: nil, templates: [template("Oats")])) {
            XCTAssertEqual($0 as? SavedMealError, .tooManyMeals)
        }
        XCTAssertEqual(try store.meals().count, SavedMealBook.maximumMeals)
    }

    func testEraseRemovesTheList() throws {
        let defaults = makeDefaults()
        let store = UserDefaultsSavedMealStore(defaults: defaults)
        try SavedMealBook(store: store).add(name: "Usual breakfast", meal: .breakfast, templates: [template("Oats")])

        try store.eraseAll()
        XCTAssertNil(defaults.object(forKey: UserDefaultsSavedMealStore.key))
        XCTAssertEqual(try store.meals(), [])
    }

    // MARK: Logging

    private func savedMeal(_ templates: [RepeatTemplate], meal: MealLabel? = .breakfast) throws -> SavedMeal {
        try SavedMealBook(store: UserDefaultsSavedMealStore(defaults: makeDefaults()))
            .add(name: "Usual breakfast", meal: meal, templates: templates)
    }

    func testLoggingCreatesOneEntryPerItemUnderTheChosenMeal() throws {
        let journal = try makeJournal()
        let saved = try savedMeal([template("Oats"), template("Milk", amount: 0.5, unit: .L)])

        let result = try SavedMealLogger(store: journal, timeZoneIdentifier: "UTC").log(saved, as: .lunch, now: now)
        XCTAssertEqual(result.loggedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)
        let intakes = try journal.activeIntakes()
        XCTAssertEqual(Set(intakes.map(\.id)), Set(result.createdIDs))
        XCTAssertEqual(intakes.map(\.meal), ["lunch", "lunch"])
        XCTAssertEqual(intakes.map(\.occurredAt), [now, now])
        let amounts = try intakes.flatMap { try journal.revisions(of: $0.id).flatMap(\.components).map(\.amount) }
        XCTAssertEqual(Set(amounts), [40, 0.5])
    }

    func testLoggingWithNoMealStatesNone() throws {
        let journal = try makeJournal()
        let saved = try savedMeal([template("Oats")])

        _ = try SavedMealLogger(store: journal, timeZoneIdentifier: "UTC").log(saved, as: nil, now: now)
        XCTAssertEqual(try journal.activeIntakes().map(\.meal), [nil])
    }

    func testAnItemThatCannotBeLoggedIsSkippedAndTheRestAreLogged() throws {
        let journal = try makeJournal()
        var saved = try savedMeal([template("Oats"), template("Bar", snapshotID: "s-gone"), template("Milk")])
        // An amount that no longer reads back, as a hand-edited or damaged store could hold.
        saved.items[2].components[0].amountText = "a lot"

        let result = try SavedMealLogger(store: journal, timeZoneIdentifier: "UTC").log(saved, as: .breakfast, now: now)
        XCTAssertEqual(result.loggedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), result.createdIDs)
    }

    func testAFailedWriteLogsNothing() throws {
        let journal = try makeJournal()
        let store = SecondCreateFailsStore(journal)
        let saved = try savedMeal([template("Oats"), template("Milk"), template("Apple")])

        XCTAssertThrowsError(try SavedMealLogger(store: store, timeZoneIdentifier: "UTC").log(saved, as: .breakfast, now: now)) {
            XCTAssertTrue($0 is SecondCreateFailsStore.WriteFailed)
        }
        XCTAssertEqual(try journal.activeIntakes(), [])
    }

    func testAFailedWriteWhoseCleanupFailsNamesTheEntriesLeft() throws {
        let journal = try makeJournal()
        let store = SecondCreateFailsStore(journal)
        store.failDeletes = true
        let saved = try savedMeal([template("Oats"), template("Milk")])

        XCTAssertThrowsError(try SavedMealLogger(store: store, timeZoneIdentifier: "UTC").log(saved, as: .breakfast, now: now)) {
            let failure = $0 as? SavedMealPartialLogError
            XCTAssertNotNil(failure)
            XCTAssertTrue(failure?.underlying is SecondCreateFailsStore.WriteFailed)
            XCTAssertEqual(failure?.remainingIDs, (try? journal.activeIntakes().map(\.id)) ?? [])
            XCTAssertEqual(failure?.remainingIDs.count, 1)
        }
    }

    func testUndoRemovesExactlyTheLoggedEntries() throws {
        let journal = try makeJournal()
        let earlier = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now.addingTimeInterval(-60),
            timeZoneIdentifier: "UTC", meal: "breakfast")
        _ = try journal.create(
            earlier, components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: nil, now: earlier.occurredAt)
        let logger = SavedMealLogger(store: journal, timeZoneIdentifier: "UTC")
        let result = try logger.log(try savedMeal([template("Oats"), template("Milk")]), as: .breakfast, now: now)

        try logger.undo(result, now: now)
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [earlier.id])
        // Undoing again finds the entries already gone, which is not a failure.
        XCTAssertNoThrow(try logger.undo(result, now: now))
    }

    /// Store-level: a restore whose generation is stale is refused and writes nothing.
    func testRestoreRefusesAStaleEraseGenerationAndWritesNothing() throws {
        let defaults = UserDefaults(suiteName: "saved-meals-generation-\(UUID().uuidString)")!
        let store = UserDefaultsSavedMealStore(defaults: defaults)
        let book = SavedMealBook(store: store)
        let kept = SavedMeal(id: "kept-meal", name: "Usual", meal: .breakfast, items: [])
        try store.update { $0.insert(kept, at: 0) }
        let stale = book.removalEpoch()
        try store.eraseAll()
        XCTAssertThrowsError(try book.restore(kept, at: 0, epoch: stale)) { error in
            XCTAssertEqual(error as? SavedMealError, .erasedSinceRemoval)
        }
        XCTAssertTrue(try store.meals().isEmpty)
    }
}
