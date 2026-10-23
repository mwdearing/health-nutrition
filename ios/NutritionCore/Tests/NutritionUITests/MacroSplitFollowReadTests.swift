import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A goal store whose reads can be switched to fail after a successful load, so a test can fail the read
/// that follows a save.
private final class ReadSwitchGoalStore: GoalStore, @unchecked Sendable {
    private let inner: InMemoryGoalStore
    var failReads = false

    init(goals: [NutrientGoal]) {
        inner = InMemoryGoalStore(goals: goals)
    }

    private struct ReadFailed: Error {}

    func goals() throws -> [NutrientGoal] {
        if failReads { throw ReadFailed() }
        return try inner.goals()
    }
    func goal(for nutrient: String) throws -> NutrientGoal? {
        if failReads { throw ReadFailed() }
        return try inner.goal(for: nutrient)
    }
    func setGoal(_ goal: NutrientGoal) throws { try inner.setGoal(goal) }
    func removeGoal(nutrient: String) throws { try inner.removeGoal(nutrient: nutrient) }
    func close() { inner.close() }
}

/// The macro split line on the Goals screen must never read as setup copy when the goals could not be read.
@MainActor
final class MacroSplitFollowReadTests: XCTestCase {
    /// A load whose goals read fails shows no follow line, not the setup copy.
    func testFailedLoadShowsNoFollowLine() {
        let model = GoalsViewModel(store: UnreadableGoalStore(), preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertNil(model.followCopy)
    }

    /// A macro save whose follow-up refresh read fails shows no follow line, not the setup copy.
    func testFailedRefreshAfterSaveShowsNoFollowLine() throws {
        let store = ReadSwitchGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)])
        let model = GoalsViewModel(store: store, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertNil(model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"))
        XCTAssertNotNil(model.followCopy)
        store.failReads = true
        model.refreshFollowedMacroSplit()
        XCTAssertNil(model.followCopy)
    }
}
