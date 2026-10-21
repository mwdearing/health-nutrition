import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A real journal that can fail one intake's revision read, or every write after the first create.
private final class FaultyJournal: JournalStore, JournalLoggedUnits, @unchecked Sendable {
    struct Failure: Error {}
    let inner: SwiftDataJournalStore
    var unreadableIntakeID: String?
    /// From when it is set, one more create succeeds and every later create and delete fails.
    var failWritesAfterFirstCreate = false { didSet { creates = 0 } }
    private var creates = 0

    init(_ inner: SwiftDataJournalStore) { self.inner = inner }

    var failNextSaveForTesting: Bool {
        get { inner.failNextSaveForTesting }
        set { inner.failNextSaveForTesting = newValue }
    }
    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        creates += 1
        if failWritesAfterFirstCreate && creates > 1 { throw Failure() }
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
        if failWritesAfterFirstCreate { throw Failure() }
        try inner.delete(intakeID: intakeID, now: now)
    }
    func activeIntakes() throws -> [Intake] { try inner.activeIntakes() }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        if intakeID == unreadableIntakeID { throw Failure() }
        return try inner.revisions(of: intakeID)
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? { try inner.product(snapshotID: snapshotID) }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }

    /// When set, every write of a logged unit fails; reads and removals still reach the real store.
    var failUnitWrites = false
    /// Called before each unit write, so a test can see what was saved at that moment.
    var onUnitWrite: (() -> Void)?
    func recordLoggedUnit(_ loggedUnit: JournalLoggedUnit) throws {
        onUnitWrite?()
        if failUnitWrites { throw Failure() }
        try inner.recordLoggedUnit(loggedUnit)
    }
    /// When set, reading the recorded units fails.
    var failUnitReads = false
    func loggedUnits() throws -> [JournalLoggedUnit] {
        if failUnitReads { throw Failure() }
        return try inner.loggedUnits()
    }
    func removeLoggedUnit(intakeID: String, componentID: String) throws {
        try inner.removeLoggedUnit(intakeID: intakeID, componentID: componentID)
    }
}

/// The screen model for saved meals, and Save as meal from the Journal.
///
/// Synthetic names and ids only. Lowercase UUID intake ids.
@MainActor
final class SavedMealsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDefaults() -> UserDefaults {
        let suite = "saved-meals-model-\(UUID().uuidString)"
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

    @discardableResult
    private func addEntry(_ store: JournalStore, _ name: String, at date: Date, meal: String? = "breakfast") throws -> Intake {
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: date, timeZoneIdentifier: "UTC", meal: meal)
        try store.create(
            intake, components: [IntakeComponent(componentID: name.lowercased(), name: name, amount: 40, unit: .g)],
            product: nil, now: date)
        return intake
    }

    // MARK: Removing

    /// Remove on a saved meal offers Undo, and Undo puts the meal back where it was in the list.
    func testUndoPutsARemovedSavedMealBackInItsPlace() throws {
        let journal = try makeJournal()
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        let oats = try addEntry(journal, "Oats", at: now.addingTimeInterval(-120))
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)
        XCTAssertTrue(model.save(name: "First", meal: .breakfast, intakes: [milk]))
        XCTAssertTrue(model.save(name: "Second", meal: .lunch, intakes: [oats]))
        XCTAssertTrue(model.save(name: "Third", meal: .dinner, intakes: [milk]))
        let before = model.meals.map(\.id)

        model.remove(model.meals[1])
        XCTAssertEqual(model.meals.map(\.name), ["Third", "First"])
        XCTAssertEqual(model.removalUndo?.message, "Removed Second.")

        XCTAssertTrue(model.undoRemove())
        XCTAssertEqual(model.meals.map(\.id), before)
        XCTAssertNil(model.removalUndo)
    }

    /// Saving a meal after a removal is a newer action, so the removal's Undo goes and the removal is final.
    func testSavingAfterARemovalClearsTheRemovalOffer() throws {
        let journal = try makeJournal()
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        let oats = try addEntry(journal, "Oats", at: now.addingTimeInterval(-120))
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)
        XCTAssertTrue(model.save(name: "First", meal: .breakfast, intakes: [milk]))
        model.remove(model.meals[0])
        XCTAssertNotNil(model.removalUndo)

        XCTAssertTrue(model.save(name: "Second", meal: .lunch, intakes: [oats]))

        XCTAssertNil(model.removalUndo)
        XCTAssertFalse(model.undoRemove())
        XCTAssertEqual(model.meals.map(\.name), ["Second"])
    }

    /// A restore whose name a newer meal now uses fails, says so, and writes no duplicate.
    func testRestoreWithAClashingNameFailsWithoutADuplicate() throws {
        let journal = try makeJournal()
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        let defaults = makeDefaults()
        let store = UserDefaultsSavedMealStore(defaults: defaults)
        let model = SavedMealsModel(store: store, journal: journal)
        XCTAssertTrue(model.save(name: "Usual", meal: .breakfast, intakes: [milk]))
        let original = try XCTUnwrap(model.meals.first)
        model.remove(original)
        // A meal named "usual" (any case) is saved by another route while the removal's Undo is still up.
        var clash = original
        clash.id = "clashing-meal"
        clash.name = "usual"
        try store.update { $0.insert(clash, at: 0) }

        XCTAssertFalse(model.undoRemove())

        XCTAssertEqual(try store.meals().map(\.name), ["usual"])
        XCTAssertTrue(model.noticeIsFailure)
        XCTAssertEqual(model.notice, "Couldn't put back Usual. Tap Undo to try again.")
    }

    /// An erase after a removal is a newer action: Undo must not write the meal back into the erased data.
    func testUndoAfterAnEraseDoesNotWriteTheMealBack() throws {
        let journal = try makeJournal()
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        let defaults = makeDefaults()
        let store = UserDefaultsSavedMealStore(defaults: defaults)
        let model = SavedMealsModel(store: store, journal: journal)
        XCTAssertTrue(model.save(name: "Usual", meal: .breakfast, intakes: [milk]))
        model.remove(model.meals[0])
        XCTAssertNotNil(model.removalUndo)

        // The Erase button runs each store through JournalErasing (AppServices.eraseStores lists this store), so the
        // test erases through that same protocol rather than calling the store's method directly.
        let eraser: JournalErasing = store
        try eraser.eraseAll()

        XCTAssertFalse(model.undoRemove())
        XCTAssertEqual(try store.meals().count, 0)
        XCTAssertNil(model.removalUndo)
        XCTAssertTrue(model.noticeIsFailure)
    }

    /// Once the Undo window has passed, the removal stays and Undo has nothing to put back.
    func testExpiredRemovalCannotBeUndone() throws {
        let journal = try makeJournal()
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)
        XCTAssertTrue(model.save(name: "Only", meal: nil, intakes: [milk]))

        model.remove(model.meals[0])
        let removal = try XCTUnwrap(model.removalUndo)
        model.expireRemoval(removal)

        XCTAssertNil(model.removalUndo)
        XCTAssertFalse(model.undoRemove())
        XCTAssertTrue(model.meals.isEmpty)
    }

    /// Logging the same saved meal twice gives two offers with the same text and different ids, so the toast keys
    /// each offer on its own id.
    func testLoggingTheSameSavedMealTwiceGivesTwoOffersWithDifferentIds() throws {
        let journal = try makeJournal()
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)
        XCTAssertTrue(model.save(name: "Usual", meal: .breakfast, intakes: [milk]))
        let saved = try XCTUnwrap(model.meals.first)

        XCTAssertTrue(model.log(saved, as: .breakfast, now: now))
        let first = try XCTUnwrap(model.undoToken)
        XCTAssertTrue(model.log(saved, as: .breakfast, now: now))
        let second = try XCTUnwrap(model.undoToken)
        XCTAssertEqual(first.message, second.message)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: Saving

    func testSaveKeepsTheEntriesInTheOrderTheyWereEaten() throws {
        let journal = try makeJournal()
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        let oats = try addEntry(journal, "Oats", at: now.addingTimeInterval(-120))
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)

        XCTAssertTrue(model.save(name: "Usual breakfast", meal: .breakfast, intakes: [milk, oats]))
        XCTAssertEqual(model.meals.first?.items.map(\.displayName), ["Oats", "Milk"])
        XCTAssertEqual(model.meals.first?.meal, .breakfast)
        XCTAssertFalse(model.noticeIsFailure)
    }

    /// A spoon-logged entry saved into a meal keeps its unit, and logging the meal again writes it onto the new entry.
    func testASavedMealKeepsTheUnitAnItemWasLoggedIn() throws {
        let journal = try makeJournal()
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC",
            meal: "breakfast")
        try journal.recordLoggedUnit(JournalLoggedUnit(intakeID: intake.id, componentID: "fiber", unit: .teaspoon))
        try journal.create(
            intake,
            components: [IntakeComponent(
                componentID: "fiber", name: "Fiber", amount: Decimal(string: "19.715686375")!, unit: .mL)],
            product: nil, now: now)
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)

        XCTAssertTrue(model.save(name: "Usual", meal: .breakfast, intakes: [intake]))
        let saved = try XCTUnwrap(model.meals.first)
        XCTAssertTrue(try journal.loggedUnits().contains { $0.intakeID == saved.items[0].id && $0.unit == .teaspoon })

        XCTAssertTrue(model.log(saved, as: .breakfast, now: now))
        let loggedAgain = try journal.loggedUnits().filter { $0.intakeID != intake.id && $0.intakeID != saved.items[0].id }
        XCTAssertEqual(loggedAgain.map(\.unit), [.teaspoon])
    }

    /// A meal whose units cannot be written is not saved at all, and says so.
    /// Units are written before the meal, so a failed unit write means no meal is ever written; the test
    /// checks no meal exists and the entry's own unit row is untouched.
    func testAFailedUnitWriteSavesNoMeal() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC",
            meal: "breakfast")
        try inner.recordLoggedUnit(JournalLoggedUnit(intakeID: intake.id, componentID: "fiber", unit: .teaspoon))
        try inner.create(
            intake,
            components: [IntakeComponent(
                componentID: "fiber", name: "Fiber", amount: Decimal(string: "19.715686375")!, unit: .mL)],
            product: nil, now: now)
        let store = UserDefaultsSavedMealStore(defaults: makeDefaults())
        let model = SavedMealsModel(store: store, journal: journal)
        journal.failUnitWrites = true
        // Units come first, so no meal exists yet when the first unit write is attempted.
        var mealsAtFirstUnitWrite: Int?
        journal.onUnitWrite = {
            if mealsAtFirstUnitWrite == nil { mealsAtFirstUnitWrite = (try? store.meals())?.count ?? -1 }
        }

        XCTAssertFalse(model.save(name: "Usual", meal: .breakfast, intakes: [intake]))
        XCTAssertEqual(mealsAtFirstUnitWrite, 0)
        XCTAssertTrue(model.noticeIsFailure)
        XCTAssertEqual(model.notice, "Could not save the meal.")
        XCTAssertEqual(try store.meals(), [])
        XCTAssertEqual(try inner.loggedUnits().map(\.intakeID), [intake.id], "only the entry's own row remains")
    }

    private func fiberEntry(_ inner: SwiftDataJournalStore) throws -> Intake {
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC",
            meal: "breakfast")
        try inner.recordLoggedUnit(JournalLoggedUnit(intakeID: intake.id, componentID: "fiber", unit: .teaspoon))
        try inner.create(
            intake,
            components: [IntakeComponent(
                componentID: "fiber", name: "Fiber", amount: Decimal(string: "19.715686375")!, unit: .mL)],
            product: nil, now: now)
        return intake
    }

    /// A failed read of the recorded units stops the writes that would carry them, instead of creating the copy or
    /// the meal without its units.
    func testAFailedUnitReadStopsSavingAMeal() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        let intake = try fiberEntry(inner)
        let store = UserDefaultsSavedMealStore(defaults: makeDefaults())
        let model = SavedMealsModel(store: store, journal: journal)
        journal.failUnitReads = true

        XCTAssertFalse(model.save(name: "Usual", meal: .breakfast, intakes: [intake]))
        XCTAssertEqual(model.notice, "Could not save the meal.")
        XCTAssertEqual(try store.meals(), [])
    }

    /// Recents refuse to build rows while the recorded units cannot be read, so a one-tap copy is never made without
    /// the unit its entry was logged in.
    func testAFailedUnitReadRefusesTheRecentsRows() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        _ = try fiberEntry(inner)
        journal.failUnitReads = true
        let home = AddHomeViewModel(store: journal, now: { self.now })

        home.load()

        XCTAssertEqual(home.errorMessage, "Could not read recent items.")
        XCTAssertTrue(home.recents.isEmpty)
    }

    func testAFailedUnitReadStopsLoggingOnOtherDays() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        let intake = try fiberEntry(inner)
        journal.failUnitReads = true

        XCTAssertThrowsError(try IntakeMultiDayLogger(store: journal).log(
            intakeID: intake.id, onDays: ["2023-11-12"], now: now.addingTimeInterval(86_400 * 10)))
        XCTAssertEqual(try inner.activeIntakes().map(\.id), [intake.id], "no copy was created")
    }

    /// The unit of a changed amount is forgotten in the same commit as the edit, so an unreadable unit index no
    /// longer stops the edit. Only the changed component's unit goes; the unchanged one survives (#430).
    func testAFailedUnitReadStillSavesTheEditAndForgetsOnlyItsChangedUnit() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC",
            meal: "breakfast")
        try inner.create(
            intake,
            components: [
                IntakeComponent(componentID: "fiber", name: "Fiber", amount: Decimal(string: "19.715686375")!, unit: .mL),
                IntakeComponent(componentID: "protein", name: "Protein", amount: 3, unit: .mL),
            ],
            product: nil, now: now)
        try inner.recordLoggedUnit(JournalLoggedUnit(intakeID: intake.id, componentID: "fiber", unit: .teaspoon))
        try inner.recordLoggedUnit(JournalLoggedUnit(intakeID: intake.id, componentID: "protein", unit: .teaspoon))
        let detail = EntryDetailViewModel(store: journal, intakeID: intake.id, timeZoneIdentifier: "UTC")
        detail.load(now: now)
        let fiberID = try XCTUnwrap(detail.components.first { $0.id == "fiber" }).id
        detail.drafts[fiberID] = "250"
        journal.failUnitReads = true

        XCTAssertTrue(detail.saveDrafts(now: now))
        let saved = try XCTUnwrap(inner.revisions(of: intake.id).last?.components.first { $0.componentID == "fiber" })
        XCTAssertEqual(saved.amount, Decimal(250))
        XCTAssertEqual(try inner.loggedUnits().map(\.componentID), ["protein"], "only the changed unit is forgotten")
    }

    /// A save made from a screen whose entry changed underneath it is refused, not written over the newer revision.
    func testAStaleScreenRefusesToOverwriteANewerRevision() throws {
        let inner = try makeJournal()
        let intake = try fiberEntry(inner)
        let detail = EntryDetailViewModel(store: inner, intakeID: intake.id, timeZoneIdentifier: "UTC")
        detail.load(now: now)
        let componentID = try XCTUnwrap(detail.components.first).id
        detail.drafts[componentID] = "250"
        _ = try inner.edit(
            intakeID: intake.id,
            components: [IntakeComponent(componentID: "fiber", name: "Fiber", amount: 4, unit: .mL)],
            product: nil, changeReason: "Edited elsewhere", now: now, occurredAt: nil, timeZoneIdentifier: nil)

        XCTAssertFalse(detail.saveDrafts(now: now))
        XCTAssertEqual(detail.errorMessage, "This entry changed since you opened it. Reopen it to see the latest amounts.")
        XCTAssertEqual(try inner.revisions(of: intake.id).last?.changeReason, "Edited elsewhere")
    }

    func testAnUnreadableEntryRefusesTheWholeSave() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        let oats = try addEntry(journal, "Oats", at: now.addingTimeInterval(-120))
        let milk = try addEntry(journal, "Milk", at: now.addingTimeInterval(-60))
        journal.unreadableIntakeID = milk.id
        let store = UserDefaultsSavedMealStore(defaults: makeDefaults())
        let model = SavedMealsModel(store: store, journal: journal)

        XCTAssertFalse(model.save(name: "Usual breakfast", meal: .breakfast, intakes: [oats, milk]))
        XCTAssertTrue(model.noticeIsFailure)
        XCTAssertEqual(model.notice, "One of these entries can't be read, so the meal was not saved.")
        XCTAssertEqual(try store.meals(), [])
    }

    func testARefusalKeepsItsMessageAfterTheReload() throws {
        let journal = try makeJournal()
        let oats = try addEntry(journal, "Oats", at: now)
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)
        model.save(name: "Usual breakfast", meal: .breakfast, intakes: [oats])

        XCTAssertFalse(model.save(name: "usual breakfast", meal: .breakfast, intakes: [oats]))
        XCTAssertEqual(model.notice, SavedMealError.duplicateName.message)
        XCTAssertTrue(model.noticeIsFailure)
        XCTAssertEqual(model.meals.count, 1)
        // A later read, such as another screen opening, drops the notice with it.
        model.load()
        XCTAssertNil(model.notice)
    }

    func testAFailedReadEmptiesTheListRatherThanKeepingTheLastOne() throws {
        let journal = try makeJournal()
        let oats = try addEntry(journal, "Oats", at: now)
        let defaults = makeDefaults()
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: defaults), journal: journal)
        model.save(name: "Usual breakfast", meal: .breakfast, intakes: [oats])
        XCTAssertEqual(model.meals.count, 1)

        defaults.set(Data("damaged".utf8), forKey: UserDefaultsSavedMealStore.key)
        model.load()
        XCTAssertEqual(model.meals, [])
        XCTAssertEqual(model.loadError, SavedMealError.unreadable.message)
    }

    // MARK: Logging

    private func modelWithMeal(_ journal: JournalStore, names: [String]) throws -> (SavedMealsModel, SavedMeal) {
        var intakes: [Intake] = []
        for (index, name) in names.enumerated() {
            intakes.append(try addEntry(journal, name, at: now.addingTimeInterval(TimeInterval(-600 + index))))
        }
        let model = SavedMealsModel(
            store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal, timeZoneIdentifier: "UTC")
        XCTAssertTrue(model.save(name: "Usual breakfast", meal: .breakfast, intakes: intakes))
        return (model, try XCTUnwrap(model.meals.first))
    }

    func testLogOffersUndoForExactlyWhatItWrote() throws {
        let journal = try makeJournal()
        let (model, saved) = try modelWithMeal(journal, names: ["Oats", "Milk"])

        XCTAssertTrue(model.log(saved, as: .lunch, now: now))
        let token = try XCTUnwrap(model.undoToken)
        XCTAssertEqual(token.message, "Logged Usual breakfast.")
        XCTAssertEqual(token.result.loggedCount, 2)
        XCTAssertEqual(try journal.activeIntakes().filter { $0.occurredAt == now }.map(\.meal), ["lunch", "lunch"])

        XCTAssertTrue(model.undo(now: now))
        XCTAssertNil(model.undoToken)
        XCTAssertEqual(try journal.activeIntakes().filter { $0.occurredAt == now }, [])
    }

    func testAMealWithNothingLeftToLogSaysSoAndOffersNoUndo() throws {
        let journal = try makeJournal()
        let (model, saved) = try modelWithMeal(journal, names: ["Oats"])
        var damaged = saved
        damaged.items[0].components[0].amountText = "a lot"

        XCTAssertFalse(model.log(damaged, as: .breakfast, now: now))
        XCTAssertNil(model.undoToken)
        XCTAssertTrue(model.noticeIsFailure)
        XCTAssertEqual(model.notice, "Nothing was logged: 1 item can no longer be logged.")
    }

    func testAFailedWriteWhoseCleanupFailsOffersToRemoveWhatWasLeft() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        let (model, saved) = try modelWithMeal(journal, names: ["Oats", "Milk"])
        journal.failWritesAfterFirstCreate = true

        XCTAssertFalse(model.log(saved, as: .breakfast, now: now))
        let token = try XCTUnwrap(model.undoToken)
        XCTAssertEqual(token.result.createdIDs.count, 1)
        XCTAssertEqual(token.message, "Could not log Usual breakfast. 1 entry was left in the journal.")
        let warning = "1 entry left over from logging or undoing a saved meal is still in the Journal. Delete it there."
        XCTAssertEqual(model.leftoverWarning, warning)
        // The warning outlives the timed Undo offer, a later read and a later log.
        model.expireUndo(token)
        XCTAssertNil(model.undoToken)
        model.load()
        XCTAssertEqual(model.leftoverWarning, warning)
        // It goes once the entry is gone, here deleted in the Journal.
        try inner.delete(intakeID: token.result.createdIDs[0], now: now)
        model.load()
        XCTAssertNil(model.leftoverWarning)
    }

    func testAFailedUndoWarnsUntilTheEntriesAreGone() throws {
        let inner = try makeJournal()
        let journal = FaultyJournal(inner)
        let (model, saved) = try modelWithMeal(journal, names: ["Oats", "Milk"])
        XCTAssertTrue(model.log(saved, as: .breakfast, now: now))
        journal.failWritesAfterFirstCreate = true

        XCTAssertFalse(model.undo(now: now))
        XCTAssertEqual(model.undoToken?.message, "Could not remove 2 entries. Try again.")
        XCTAssertEqual(
            model.leftoverWarning,
            "2 entries left over from logging or undoing a saved meal are still in the Journal. Delete them there.")
        journal.failWritesAfterFirstCreate = false
        XCTAssertTrue(model.undo(now: now))
        XCTAssertNil(model.leftoverWarning)
    }

    func testMealChoicesPutTheSavedMealFirstThenTheOthersThenNone() {
        let saved = SavedMeal(id: "m", name: "Usual dinner", meal: .dinner, items: [])
        XCTAssertEqual(SavedMealsModel.mealChoices(for: saved), [.dinner, .breakfast, .lunch, .snack, nil])
        let unnamed = SavedMeal(id: "n", name: "Anything", meal: nil, items: [])
        XCTAssertEqual(SavedMealsModel.mealChoices(for: unnamed), [.breakfast, .lunch, .dinner, .snack, nil])
    }

    func testMatchingNarrowsByNameIgnoringCase() throws {
        let journal = try makeJournal()
        let (model, _) = try modelWithMeal(journal, names: ["Oats"])

        XCTAssertEqual(model.matching("  BREAK ").map(\.name), ["Usual breakfast"])
        XCTAssertEqual(model.matching("lunch"), [])
        XCTAssertEqual(model.matching("").count, 1)
    }

    // MARK: Save as meal from the Journal

    /// A saved meal that is refused keeps the copy's Undo, because only a saved meal finalizes it (#535).
    func testARefusedSavedMealKeepsTheCopysUndo() throws {
        let journal = try makeJournal()
        let yesterday = now.addingTimeInterval(-86_400)
        try addEntry(journal, "Oats", at: yesterday)
        try addEntry(journal, "Rice", at: yesterday.addingTimeInterval(120), meal: "dinner")
        let model = JournalViewModel(store: journal, timeZoneIdentifier: "UTC")
        let savedMeals = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)
        model.savedMeals = savedMeals
        model.load(now: now)
        let day = try XCTUnwrap(model.sections.first)
        XCTAssertTrue(model.saveMeal(day.id, groupID: "Breakfast", name: "Usual breakfast"))
        _ = try XCTUnwrap(model.copyDayToToday(day.id, now: now))
        XCTAssertTrue(model.canUndoCopy(now: now))

        // The Dinner group has entries, so this is the duplicate-name refusal from the store, not an empty group.
        XCTAssertFalse(model.saveMeal(day.id, groupID: "Dinner", name: "Usual breakfast"))
        XCTAssertEqual(model.copyNotice, SavedMealError.duplicateName.message)
        XCTAssertTrue(model.canUndoCopy(now: now), "a refused save does not finalize the copy's Undo")
    }

    func testJournalSavesOneMealGroupOfADay() throws {
        let journal = try makeJournal()
        let yesterday = now.addingTimeInterval(-86_400)
        try addEntry(journal, "Oats", at: yesterday)
        try addEntry(journal, "Milk", at: yesterday.addingTimeInterval(60))
        try addEntry(journal, "Rice", at: yesterday.addingTimeInterval(120), meal: "dinner")
        let model = JournalViewModel(store: journal, timeZoneIdentifier: "UTC")
        let savedMeals = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: makeDefaults()), journal: journal)
        model.savedMeals = savedMeals
        model.load(now: now)
        let day = try XCTUnwrap(model.sections.first)

        XCTAssertTrue(model.saveMeal(day.id, groupID: "Breakfast", name: "Usual breakfast"))
        XCTAssertEqual(savedMeals.meals.first?.items.map(\.displayName), ["Oats", "Milk"])
        XCTAssertEqual(savedMeals.meals.first?.meal, .breakfast)
        XCTAssertEqual(model.copyNotice, "Saved Usual breakfast. Log it again from Add, in Search foods.")
        XCTAssertFalse(model.copyFailed)

        XCTAssertFalse(model.saveMeal(day.id, groupID: "Dinner", name: "Usual breakfast"))
        XCTAssertEqual(model.copyNotice, SavedMealError.duplicateName.message)
        XCTAssertTrue(model.copyFailed)
    }
}
