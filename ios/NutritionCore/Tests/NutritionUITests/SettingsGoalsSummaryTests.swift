import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

final class SettingsGoalsSummaryTests: XCTestCase {
    private func plan(_ aim: GoalAim, pace: Decimal? = nil) -> WeightPlan {
        WeightPlan(aim: aim, goalKilograms: aim == .maintain ? nil : 70, weeklyPaceKilograms: pace)
    }

    func testTheEnergyGoalLineUsesTheDisplayUnit() {
        let summary = SettingsGoalsSummary(
            energyGoal: 2000, energyUnit: .kcal, goalsSetText: "1 set", plan: nil, unitSystem: .metric)
        XCTAssertEqual(summary.title, "Daily goals")
        XCTAssertEqual(summary.energyLine, "2,000 Calories a day")
        XCTAssertEqual(summary.capsuleTitle, "Edit goals")
    }

    func testNoEnergyGoalKeepsTheCurrentWording() {
        for goal in [nil, Decimal(0)] {
            let none = SettingsGoalsSummary(
                energyGoal: goal, energyUnit: .kcal, goalsSetText: "None set", plan: nil, unitSystem: .metric)
            XCTAssertEqual(none.energyLine, "None set")
            XCTAssertEqual(none.capsuleTitle, "Set your goals")
        }
        let some = SettingsGoalsSummary(
            energyGoal: nil, energyUnit: .kcal, goalsSetText: "3 set", plan: nil, unitSystem: .metric)
        XCTAssertEqual(some.energyLine, "3 set")
        XCTAssertEqual(some.capsuleTitle, "Edit goals")
    }

    func testASavedPlanWithNoEnergyGoalStillSaysEditGoals() {
        let summary = SettingsGoalsSummary(
            energyGoal: nil, energyUnit: .kcal, goalsSetText: "None set", plan: plan(.maintain), unitSystem: .metric)
        XCTAssertEqual(summary.planLine, "Keep your weight")
        XCTAssertEqual(summary.capsuleTitle, "Edit goals")
    }

    func testThePlanLineOnlyWithAPlan() {
        func line(_ plan: WeightPlan?) -> String? {
            SettingsGoalsSummary(
                energyGoal: 2000, energyUnit: .kcal, goalsSetText: "1 set", plan: plan, unitSystem: .metric).planLine
        }
        XCTAssertNil(line(nil))
        XCTAssertNil(line(plan(.justTrack)))
        XCTAssertEqual(line(plan(.lose, pace: Decimal(string: "0.5")!)), "Lose 0.5 kg a week")
        XCTAssertEqual(line(plan(.gain, pace: Decimal(string: "0.25")!)), "Gain 0.25 kg a week")
        XCTAssertEqual(line(plan(.maintain)), "Keep your weight")
    }

    func testThePlanLineUsesPoundsForUSUnits() {
        let summary = SettingsGoalsSummary(
            energyGoal: 2000, energyUnit: .kcal, goalsSetText: "1 set",
            plan: plan(.lose, pace: Decimal(string: "0.45359237")!), unitSystem: .usCustomary)
        XCTAssertEqual(summary.planLine, "Lose 1 lb a week")
    }

    @MainActor
    func testTheViewModelReadsTheStoredEnergyGoal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let connections = ConnectionsPrivacyViewModel(
            goals: InMemoryGoalStore(), store: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            preferences: InMemoryDisplayPreferences())
        let store = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        let goals = GoalsViewModel(store: store)
        let model = AppSettingsViewModel(connections: connections, goals: goals)
        model.load()
        XCTAssertEqual(model.goalsSummary.energyLine, "None set")
        try store.setGoal(NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal))
        model.load()
        XCTAssertEqual(model.goalsSummary.energyLine, "2,000 Calories a day")
        XCTAssertNil(model.goalsSummary.planLine)
        try store.setWeightPlan(WeightPlan(aim: .maintain, goalKilograms: nil, weeklyPaceKilograms: nil))
        XCTAssertEqual(model.goalsSummary.planLine, "Keep your weight")
    }
}
