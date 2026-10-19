import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The entry screen's meal row: the options it offers, choosing one writes a new revision and reloads the
/// screen, and the Changes list, Today and the Journal read the entry in its new meal. Synthetic data only.
@MainActor
final class EntryMealEditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let intakeID = "5a0e9c4b-1d2f-4a7e-8b3c-9f6d0e1a2b34"

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// One entry with one component, in UTC, at the given meal.
    private func logEntry(_ store: SwiftDataJournalStore, meal: String?) throws {
        try store.create(
            Intake(id: intakeID, category: "food", occurredAt: now, timeZoneIdentifier: "UTC", meal: meal),
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)],
            product: nil, now: now)
    }

    private func entryModel(_ store: SwiftDataJournalStore) -> EntryDetailViewModel {
        EntryDetailViewModel(store: store, intakeID: intakeID, timeZoneIdentifier: "UTC")
    }

    func testTheOptionsAreEachNamedMealThenNotSet() {
        XCTAssertEqual(EntryDetailViewModel.mealOptions.map(\.title), ["Breakfast", "Lunch", "Dinner", "Snack", "Not set"])
        XCTAssertEqual(EntryDetailViewModel.mealOptions.map(\.meal), [.breakfast, .lunch, .dinner, .snack, nil])
    }

    func testChoosingAMealReloadsTheMealTextAndWritesOneRevision() throws {
        let store = try makeStore()
        try logEntry(store, meal: "breakfast")
        let model = entryModel(store)
        model.load(now: now)
        XCTAssertEqual(model.mealText, "Breakfast")
        XCTAssertTrue(model.changeMeal(to: .dinner, now: now))
        XCTAssertEqual(model.mealText, "Dinner")
        XCTAssertEqual(model.selectedMeal, .dinner)
        XCTAssertEqual(model.currentRevision, 2)
        XCTAssertEqual(try store.revisions(of: intakeID).count, 2)
    }

    func testTheChangesListShowsMealChangedWithoutAReasonRepeatingIt() throws {
        let store = try makeStore()
        try logEntry(store, meal: "breakfast")
        let model = entryModel(store)
        model.load(now: now)
        model.changeMeal(to: .lunch, now: now)
        let newest = try XCTUnwrap(model.changes.first)
        XCTAssertEqual(newest.id, 2)
        XCTAssertEqual(newest.verb, "Meal changed")
        XCTAssertNil(newest.note)
    }

    func testTheReasonTheStoreWritesIsTheReasonTheScreenNamesAndTheDayListsReadIt() throws {
        let store = try makeStore()
        try logEntry(store, meal: "breakfast")
        let model = entryModel(store)
        model.load(now: now)
        model.changeMeal(to: .snack, now: now)
        XCTAssertEqual(try store.revisions(of: intakeID).last?.changeReason, EntryDetailViewModel.mealChangedReason)
        XCTAssertEqual(EntryDetailViewModel.mealChangedReason, "Meal changed")
    }

    func testTodayAndTheJournalMoveTheEntryToItsNewMealGroupAfterReload() throws {
        let store = try makeStore()
        try logEntry(store, meal: "breakfast")
        let entry = entryModel(store)
        entry.load(now: now)
        entry.changeMeal(to: .dinner, now: now)

        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        XCTAssertEqual(today.mealSections.map(\.title), ["Dinner"])

        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        journal.load(now: now)
        XCTAssertEqual(journal.sections.first?.mealGroups.map(\.title), ["Dinner"])
    }

    func testAnEntryWithANonVocabularyMealIsShownAsWrittenAndCannotBeChangedFromHere() throws {
        let store = try makeStore()
        try logEntry(store, meal: "Brunch")
        let model = entryModel(store)
        model.load(now: now)
        XCTAssertEqual(model.mealText, "Brunch")
        XCTAssertFalse(model.canChangeMeal)
        XCTAssertFalse(model.changeMeal(to: .dinner, now: now))
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
    }

    func testChoosingTheCurrentMealWritesNothingAndAFailedChangeSaysSo() throws {
        let store = try makeStore()
        try logEntry(store, meal: "breakfast")
        let model = entryModel(store)
        model.load(now: now)
        XCTAssertFalse(model.changeMeal(to: .breakfast, now: now), "the meal already shown is not a change")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
        try store.delete(intakeID: intakeID, now: now)
        XCTAssertFalse(model.changeMeal(to: .dinner, now: now))
        XCTAssertNotNil(model.errorMessage)
    }

    /// Choosing a meal reloads the screen, so it is refused while an amount or time edit is unsaved rather than
    /// quietly discarding it.
    func testAMealCannotBeChangedWhileAnEditIsUnsaved() throws {
        let store = try makeStore()
        try logEntry(store, meal: "breakfast")
        let model = entryModel(store)
        model.load(now: now)
        let component = try XCTUnwrap(model.drafts.keys.first)
        model.drafts[component] = "55"
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.canChangeMeal)

        XCTAssertFalse(model.changeMeal(to: .dinner, now: now))

        XCTAssertEqual(model.drafts[component], "55", "the unsaved edit is still there")
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
    }
}
