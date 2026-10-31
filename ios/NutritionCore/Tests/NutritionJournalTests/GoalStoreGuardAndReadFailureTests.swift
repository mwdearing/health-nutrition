import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Two rules about the goal store's edges.
///
/// Removing a goal goes through the same receipt guard as setting one: the "restore-receipt:" rows share the
/// goal table, so a caller passing such a key must be refused before anything is deleted, or it would drop a
/// live restore receipt and a resumed restore would write goals again. And the in-memory stores' read failure
/// is a lasting state, not a one-shot: every read throws, which is what the `failReads` name says.
final class GoalStoreGuardAndReadFailureTests: XCTestCase {
    private func makeStore() throws -> SwiftDataGoalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        addTeardownBlock { store.close() }
        return store
    }

    private let protein = NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)

    func testRemovingAGoalUnderTheReceiptPrefixIsRefusedAndTheReceiptStays() throws {
        let store = try makeStore()
        try store.recordGoalRestoreReceipt("live-receipt", goals: [protein])

        XCTAssertThrowsError(try store.removeGoal(nutrient: "restore-receipt:live-receipt")) { error in
            XCTAssertEqual(error as? GoalStoreError, .unknownNutrient)
        }

        XCTAssertEqual(try store.goalRestoreReceipt("live-receipt"), [protein])
        XCTAssertEqual(try store.goalRestoreReceiptDone("live-receipt"), false)
    }

    func testRemovingAnyKeyUnderTheReceiptPrefixIsRefusedEvenWithNoReceipt() throws {
        let store = try makeStore()

        XCTAssertThrowsError(try store.removeGoal(nutrient: "restore-receipt:")) { error in
            XCTAssertEqual(error as? GoalStoreError, .unknownNutrient)
        }
        XCTAssertThrowsError(try store.removeGoal(nutrient: "restore-receipt:never-recorded")) { error in
            XCTAssertEqual(error as? GoalStoreError, .unknownNutrient)
        }
    }

    func testRemovingAnOrdinaryGoalStillRemovesItAndLeavesTheReceipt() throws {
        let store = try makeStore()
        try store.setGoal(protein)
        try store.recordGoalRestoreReceipt("live-receipt", goals: [protein])

        try store.removeGoal(nutrient: "protein")

        XCTAssertNil(try store.goal(for: "protein"))
        XCTAssertEqual(try store.goals(), [])
        XCTAssertEqual(try store.goalRestoreReceipt("live-receipt"), [protein])
    }

    func testRemovingAGoalThatIsNotStoredIsStillNotAnError() throws {
        let store = try makeStore()

        XCTAssertNoThrow(try store.removeGoal(nutrient: "sodium"))
    }

    func testAnInMemoryGoalStoreThatFailsReadsFailsEveryRead() {
        let store = InMemoryGoalStore(goals: [protein], failReads: true)

        for _ in 0..<3 {
            XCTAssertThrowsError(try store.goals())
            XCTAssertThrowsError(try store.goal(for: "protein"))
        }
    }

    func testAnInMemoryWeightPlanStoreThatFailsReadsFailsEveryRead() {
        let plan = WeightPlan(aim: .lose, goalKilograms: Decimal(75), weeklyPaceKilograms: Decimal(string: "0.5")!)
        let store = InMemoryWeightPlanStore(plan: plan, failReads: true)

        for _ in 0..<3 {
            XCTAssertThrowsError(try store.weightPlan())
        }
    }

    func testInMemoryStoresReadByDefault() throws {
        let plan = WeightPlan(aim: .maintain, goalKilograms: nil, weeklyPaceKilograms: nil)

        XCTAssertEqual(try InMemoryGoalStore(goals: [protein]).goals(), [protein])
        XCTAssertEqual(try InMemoryWeightPlanStore(plan: plan).weightPlan(), plan)
    }
}
