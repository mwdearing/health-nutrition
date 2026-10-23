import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Forwards to a real store, and runs `onSet` before each write so a test can fail the write, or change the
/// device's goal in between, the way a stop or an edit would.
final class ScriptedGoalStore: GoalStore, @unchecked Sendable {
    let base: SwiftDataGoalStore
    let onSet: (NutrientGoal, SwiftDataGoalStore) throws -> Void
    let refusesRemoval: Bool
    /// Makes every read fail, as a store that cannot be read at that moment would.
    var failsRead = false
    /// Makes removing a restore receipt fail, as a store that cannot write at that moment would.
    var failsReceiptRemoval = false

    init(
        base: SwiftDataGoalStore, refusesRemoval: Bool = false,
        onSet: @escaping (NutrientGoal, SwiftDataGoalStore) throws -> Void
    ) {
        self.base = base
        self.refusesRemoval = refusesRemoval
        self.onSet = onSet
    }

    func goals() throws -> [NutrientGoal] { try base.goals() }
    func goal(for nutrient: String) throws -> NutrientGoal? {
        if failsRead { throw JournalImportError.corrupt("the goal store cannot be read") }
        return try base.goal(for: nutrient)
    }
    func setGoal(_ goal: NutrientGoal) throws {
        try onSet(goal, base)
        try base.setGoal(goal)
    }
    func removeGoal(nutrient: String) throws {
        if refusesRemoval { throw JournalImportError.corrupt("removal refused") }
        try base.removeGoal(nutrient: nutrient)
    }
    func writeRestoredGoal(_ goal: NutrientGoal, receipt: String) throws -> Bool {
        try onSet(goal, base)
        return try base.writeRestoredGoal(goal, receipt: receipt)
    }
    /// Makes marking a receipt done fail, as a store that cannot write at that moment would.
    var failsMark = false
    func markGoalRestoreReceiptDone(_ receipt: String) throws {
        if failsMark { throw JournalImportError.corrupt("mark refused") }
        try base.markGoalRestoreReceiptDone(receipt)
    }
    func goalRestoreReceiptDone(_ receipt: String) throws -> Bool? { try base.goalRestoreReceiptDone(receipt) }
    func close() { base.close() }
    func recordGoalRestoreReceipt(_ receipt: String, goals: [NutrientGoal]) throws {
        try base.recordGoalRestoreReceipt(receipt, goals: goals)
    }
    func goalRestoreReceipt(_ receipt: String) throws -> [NutrientGoal]? {
        try base.goalRestoreReceipt(receipt)
    }
    func removeGoalRestoreReceipt(_ receipt: String) throws {
        if failsReceiptRemoval { throw JournalImportError.corrupt("receipt removal refused") }
        try base.removeGoalRestoreReceipt(receipt)
    }
}
