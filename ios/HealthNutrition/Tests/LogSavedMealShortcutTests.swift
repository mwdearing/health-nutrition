import NutritionJournal
import NutritionUI
import XCTest

@testable import HealthNutrition

/// What "Log a saved meal" logs and says back. Synthetic names and ids only.
final class LogSavedMealShortcutTests: XCTestCase {
    private struct WriteFailed: Error {}
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func saved(_ id: String = "meal-1", meal: MealLabel? = .breakfast) -> SavedMeal {
        SavedMeal(
            id: id, name: "Usual breakfast", meal: meal,
            items: [FavoriteTemplate(
                id: "item-1", displayName: "Sample oats", category: "food",
                components: [FavoriteComponent(componentID: "oats", name: "Sample oats", amountText: "40", unitSymbol: "g")])])
    }

    /// While an erase or import runs the Shortcut replies with the busy message and writes nothing (#480).
    /// Counts what a run reads and writes, with a meal ready to log.
    private final class Counts {
        var reads = 0, writes = 0, reloads = 0
    }

    private func effects(busy: Bool, _ counts: Counts) -> SavedMealShortcut.Effects {
        SavedMealShortcut.Effects(
            isBusy: { busy },
            readMeals: { counts.reads += 1; return ([self.saved()], nil) },
            logMeal: { _, _, _ in
                counts.writes += 1
                return SavedMealLogResult(createdIDs: ["a"], skippedCount: 0)
            },
            recordLeftovers: { _ in },
            reload: { _ in counts.reloads += 1 })
    }

    func testWhileBusyTheRunReadsAndWritesNothing() {
        let counts = Counts()
        let outcome = SavedMealShortcut.run(id: "meal-1", meal: nil, now: now, effects: effects(busy: true, counts))
        XCTAssertEqual(outcome, .reply(SavedMealShortcut.busyMessage))
        XCTAssertEqual(counts.reads, 0)
        XCTAssertEqual(counts.writes, 0)
        XCTAssertEqual(counts.reloads, 0)
    }

    func testWhenIdleTheRunReadsOnceWritesOnceAndReloads() {
        let counts = Counts()
        _ = SavedMealShortcut.run(id: "meal-1", meal: nil, now: now, effects: effects(busy: false, counts))
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.writes, 1)
        XCTAssertEqual(counts.reloads, 1)
    }

    func testABusyAppRepliesWithTheBusyMessageAndLogsNothing() {
        XCTAssertEqual(
            SavedMealShortcut.busyReply(isBusy: true), "The app is busy with an erase or import. Try again in a moment.")
        XCTAssertNil(SavedMealShortcut.busyReply(isBusy: false))
    }

    func testLogsUnderTheMealItWasSavedWithUnlessOneIsNamed() {
        var loggedUnder: [MealLabel?] = []
        let log: (SavedMeal, MealLabel?, Date) throws -> SavedMealLogResult = { _, meal, _ in
            loggedUnder.append(meal)
            return SavedMealLogResult(createdIDs: ["a"], skippedCount: 0)
        }
        let first = SavedMealShortcut.log(id: "meal-1", meal: nil, now: now, meals: [saved()], log: log)
        let second = SavedMealShortcut.log(id: "meal-1", meal: .dinner, now: now, meals: [saved()], log: log)
        XCTAssertEqual(loggedUnder, [.breakfast, .dinner])
        XCTAssertEqual(first, .init(logged: true, message: "Added Usual breakfast to today's diary."))
        XCTAssertTrue(second.logged)
    }

    func testSaysWhatWasSkipped() {
        XCTAssertEqual(
            SavedMealShortcut.message(for: SavedMealLogResult(createdIDs: ["a", "b"], skippedCount: 1), name: "Usual breakfast"),
            "Added 2 of 3 items of Usual breakfast to today's diary. 1 item can no longer be logged.")
        let nothing = SavedMealShortcut.log(id: "meal-1", meal: nil, now: now, meals: [saved()]) { _, _, _ in
            SavedMealLogResult(createdIDs: [], skippedCount: 1)
        }
        XCTAssertEqual(nothing, .init(logged: false, message: "Nothing was added: 1 item can no longer be logged."))
    }

    func testRefusalsWriteNothing() {
        var wrote = false
        let log: (SavedMeal, MealLabel?, Date) throws -> SavedMealLogResult = { _, _, _ in
            wrote = true
            return SavedMealLogResult(createdIDs: ["a"], skippedCount: 0)
        }
        XCTAssertEqual(
            SavedMealShortcut.log(id: "meal-1", meal: nil, now: now, meals: nil, log: log).message,
            SavedMealShortcut.notReadyMessage)
        XCTAssertEqual(
            SavedMealShortcut.log(id: "meal-1", meal: nil, now: now, meals: [], log: log).message,
            "You have no saved meals yet. Save one from a meal in the Diary.")
        XCTAssertEqual(
            SavedMealShortcut.log(id: "gone", meal: nil, now: now, meals: [saved()], log: log).message,
            SavedMealError.notFound.message)
        XCTAssertFalse(wrote)
    }

    func testAsksForASavedMealOnlyWhenThereAreSomeAndNoneIsNamed() {
        XCTAssertTrue(SavedMealShortcut.needsSavedMeal(id: nil, meals: [saved()]))
        XCTAssertFalse(SavedMealShortcut.needsSavedMeal(id: "meal-1", meals: [saved()]))
        XCTAssertFalse(SavedMealShortcut.needsSavedMeal(id: "gone", meals: [saved()]))
        // With none saved, or the list unavailable, the reply says so rather than asking.
        XCTAssertFalse(SavedMealShortcut.needsSavedMeal(id: nil, meals: []))
        XCTAssertFalse(SavedMealShortcut.needsSavedMeal(id: nil, meals: nil))
        var wrote = false
        let log: (SavedMeal, MealLabel?, Date) throws -> SavedMealLogResult = { _, _, _ in
            wrote = true
            return SavedMealLogResult(createdIDs: ["a"], skippedCount: 0)
        }
        XCTAssertEqual(
            SavedMealShortcut.log(id: nil, meal: nil, now: now, meals: [], log: log).message,
            SavedMealShortcut.noSavedMealsMessage)
        XCTAssertEqual(
            SavedMealShortcut.log(id: nil, meal: nil, now: now, meals: nil, log: log).message,
            SavedMealShortcut.notReadyMessage)
        XCTAssertEqual(
            SavedMealShortcut.log(id: nil, meal: nil, now: now, meals: [saved()], log: log).message,
            SavedMealShortcut.unavailableMessage)
        XCTAssertFalse(wrote)
    }

    /// While locked or busy the id still resolves, but the meal's name is held back.
    func testALockedShortcutResolvesAMealWithoutItsName() {
        let entities = SavedMealQuery.entities(for: ["meal-1", "gone"], in: [saved()], revealNames: false)
        XCTAssertEqual(entities.map(\.id), ["meal-1", "gone"])
        XCTAssertEqual(entities.map(\.name), [SavedMealPickerPolicy.standInTitle, SavedMealShortcut.unavailableMessage])
    }

    /// The picker lists saved meals only while the device is unlocked and no erase or import runs.
    func testThePickerOffersNoMealsWhileLockedOrBusy() {
        let meals = [saved()]
        XCTAssertEqual(SavedMealPickerPolicy.enumerated(meals, isUnlocked: true, isBusy: false).map(\.id), ["meal-1"])
        XCTAssertTrue(SavedMealPickerPolicy.enumerated(meals, isUnlocked: false, isBusy: false).isEmpty)
        XCTAssertTrue(SavedMealPickerPolicy.enumerated(meals, isUnlocked: true, isBusy: true).isEmpty)
    }

    func testAShortcutsDeletedSavedMealStillRunsAndSaysSo() {
        let entities = SavedMealQuery.entities(for: ["meal-1", "gone"], in: [saved()], revealNames: true)
        XCTAssertEqual(entities.map(\.id), ["meal-1", "gone"])
        XCTAssertEqual(entities.map(\.name), ["Usual breakfast", SavedMealShortcut.unavailableMessage])
        // A list that cannot be read keeps the id too, so the action reports that rather than asking again.
        XCTAssertEqual(SavedMealQuery.entities(for: ["meal-1"], in: nil, revealNames: true).map(\.id), ["meal-1"])
        // The deleted meal's id reaches the action, which answers instead of asking for another meal.
        XCTAssertFalse(SavedMealShortcut.needsSavedMeal(id: "gone", meals: [saved()]))
        XCTAssertEqual(
            SavedMealShortcut.log(id: "gone", meal: nil, now: now, meals: [saved()]) { _, _, _ in
                SavedMealLogResult(createdIDs: ["a"], skippedCount: 0)
            }.message,
            "This saved meal is no longer available.")
    }

    func testAFailedWriteSaysSoAndReportsLeftovers() {
        let failed = SavedMealShortcut.log(id: "meal-1", meal: nil, now: now, meals: [saved()]) { _, _, _ in
            throw WriteFailed()
        }
        XCTAssertEqual(failed, .init(logged: false, message: "Could not add Usual breakfast. Nothing was logged."))

        var reported: [String] = []
        let partial = SavedMealShortcut.log(
            id: "meal-1", meal: nil, now: now, meals: [saved()],
            log: { _, _, _ in throw SavedMealPartialLogError(remainingIDs: ["left-1"], underlying: WriteFailed()) },
            leftovers: { reported = $0 })
        XCTAssertEqual(partial, .init(logged: false, message: "Could not add Usual breakfast."))
        XCTAssertEqual(reported, ["left-1"])
    }
}
