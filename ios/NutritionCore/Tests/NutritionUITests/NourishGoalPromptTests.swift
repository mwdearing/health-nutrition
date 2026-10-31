import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// #499: Today asks for a calorie goal only when it read the goals and found none.
@MainActor
final class NourishGoalPromptTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func calories(goal: Decimal?) -> CalorieRemaining {
        CalorieRemaining.make(goal: goal, food: 120, partial: false, missingCount: 0, burned: nil, energyLabel: "Calories")
    }

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testNoEnergyGoalPublishesTheCalorieGoalPrompt() {
        XCTAssertEqual(
            NourishTodayHeader.goalPrompt(calories(goal: nil), goalKnownAbsent: true),
            "Set a calorie goal to see what's left")
    }

    func testAnEnergyGoalHidesThePrompt() {
        XCTAssertNil(NourishTodayHeader.goalPrompt(calories(goal: 2000), goalKnownAbsent: false))
    }

    func testAGoalNotKnownToBeAbsentHidesThePrompt() {
        XCTAssertNil(NourishTodayHeader.goalPrompt(calories(goal: nil), goalKnownAbsent: false))
    }

    /// Before the first load nothing is known, so no prompt.
    func testBeforeTheFirstLoadTheGoalIsNotKnownAbsent() throws {
        let model = TodayViewModel(store: try makeJournal(), goals: InMemoryGoalStore(), timeZoneIdentifier: "UTC")
        XCTAssertFalse(model.calorieGoalKnownAbsent)
    }

    /// A readable store with no calorie goal asks for one.
    func testAReadableStoreWithNoCalorieGoalIsKnownAbsent() throws {
        let model = TodayViewModel(store: try makeJournal(), goals: InMemoryGoalStore(), timeZoneIdentifier: "UTC")
        model.load(now: when)
        XCTAssertTrue(model.calorieGoalKnownAbsent)
    }

    /// A stored calorie goal is not absent.
    func testAStoredCalorieGoalIsNotAbsent() throws {
        let goals = InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)])
        let model = TodayViewModel(store: try makeJournal(), goals: goals, timeZoneIdentifier: "UTC")
        model.load(now: when)
        XCTAssertFalse(model.calorieGoalKnownAbsent)
    }

    /// A goal store that cannot be read is not a person without a goal: no prompt.
    func testAnUnreadableGoalStoreDoesNotAskForAGoal() throws {
        let goals = InMemoryGoalStore(
            goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)], failReads: true)
        let model = TodayViewModel(store: try makeJournal(), goals: goals, timeZoneIdentifier: "UTC")
        model.load(now: when)
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertFalse(model.calorieGoalKnownAbsent)
    }
}
