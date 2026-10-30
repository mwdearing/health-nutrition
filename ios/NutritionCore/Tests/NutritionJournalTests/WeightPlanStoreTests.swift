import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// The persisted weight plan, read back, and its place in the same store file as the goals.
///
/// The plan is one row in `goals.store`. These check that a plan round-trips with its decimals intact,
/// that a refused plan leaves the stored one alone, that erase takes the plan with the goals, and that
/// a store written before the plan existed still opens and reads its goals.
final class WeightPlanStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore() throws -> SwiftDataGoalStore {
        let directory = try makeDirectory()
        let store = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        addTeardownBlock { store.close() }
        return store
    }

    private func loseWeightPlan() -> WeightPlan {
        WeightPlan(
            aim: .lose, goalKilograms: Decimal(string: "80")!, weeklyPaceKilograms: Decimal(string: "0.5")!)
    }

    /// `WeightPlan` is compared field by field, so the check does not depend on how the type is declared.
    private func assertSamePlan(
        _ actual: WeightPlan?, _ expected: WeightPlan, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual?.aim, expected.aim, file: file, line: line)
        XCTAssertEqual(actual?.goalKilograms, expected.goalKilograms, file: file, line: line)
        XCTAssertEqual(actual?.weeklyPaceKilograms, expected.weeklyPaceKilograms, file: file, line: line)
    }

    /// A plan written and read back is the same plan, decimals included: 80 kg and a 0.5 kg weekly pace.
    func testAPlanRoundTripsWithItsDecimals() throws {
        let store = try makeStore()

        try store.setWeightPlan(loseWeightPlan())

        assertSamePlan(try store.weightPlan(), loseWeightPlan())
    }

    /// A second write replaces the first, and only one plan is ever stored.
    func testASecondPlanReplacesTheFirst() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        let replacement = WeightPlan(
            aim: .gain, goalKilograms: Decimal(string: "70")!, weeklyPaceKilograms: Decimal(string: "0.25")!)

        try store.setWeightPlan(replacement)

        assertSamePlan(try store.weightPlan(), replacement)
    }

    /// Removing the plan leaves no plan, and removing again, with none stored, is not an error.
    func testRemovingThePlanLeavesNoPlan() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())

        try store.removeWeightPlan()

        XCTAssertNil(try store.weightPlan())
        XCTAssertNoThrow(try store.removeWeightPlan())
    }

    /// A refused plan writes nothing: the stored plan is still the valid one the person set before.
    func testAnInvalidPlanWritesNothing() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        let invalid = WeightPlan(aim: .lose, goalKilograms: nil, weeklyPaceKilograms: nil)

        XCTAssertThrowsError(try store.setWeightPlan(invalid))

        assertSamePlan(try store.weightPlan(), loseWeightPlan())
    }

    /// Erase all data clears the plan with the goals, and the store takes a new plan straight after.
    func testEraseAllRemovesThePlanAndTheGoals() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))

        try store.eraseAll()

        XCTAssertNil(try store.weightPlan())
        XCTAssertTrue(try store.goals().isEmpty)
        try store.setWeightPlan(loseWeightPlan())
        assertSamePlan(try store.weightPlan(), loseWeightPlan())
    }

    /// A closed store refuses every plan operation with `closed`, not with a silent nil.
    func testAClosedStoreThrowsClosedForEveryPlanOperation() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        store.close()

        XCTAssertThrowsError(try store.weightPlan()) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.closed)
        }
        XCTAssertThrowsError(try store.setWeightPlan(loseWeightPlan())) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.closed)
        }
        XCTAssertThrowsError(try store.removeWeightPlan()) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.closed)
        }
    }

    /// A row whose aim is not a storage text fails the read rather than reading as no plan.
    func testACorruptAimFailsTheRead() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        try store.writeCorruptPlanForTesting(aimText: "Lose")

        XCTAssertThrowsError(try store.weightPlan()) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.corruptRecord("weight plan"))
        }
    }

    /// A goal weight that is not a whole decimal fails the read, as a corrupt target does for a goal.
    func testACorruptGoalWeightFailsTheRead() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        try store.writeCorruptPlanForTesting(goalText: "6O")

        XCTAssertThrowsError(try store.weightPlan()) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.corruptRecord("weight plan"))
        }
    }

    /// A weekly pace that is not a whole decimal fails the read, as a corrupt goal weight does.
    func testACorruptPaceFailsTheRead() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        try store.writeCorruptPlanForTesting(paceText: "0,5")

        XCTAssertThrowsError(try store.weightPlan()) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.corruptRecord("weight plan"))
        }
    }

    /// A maintain row that carries a goal weight fails `validate()` on the way out, so it fails the read.
    func testAMaintainRowWithAGoalWeightFailsTheRead() throws {
        let store = try makeStore()
        try store.setWeightPlan(WeightPlan(aim: .maintain, goalKilograms: nil, weeklyPaceKilograms: nil))
        try store.writeCorruptPlanForTesting(goalText: "70")

        XCTAssertThrowsError(try store.weightPlan()) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.corruptRecord("weight plan"))
        }
    }

    /// Two stored rows no longer say which plan the person set, so the read fails rather than picking one.
    func testTwoStoredPlansFailTheRead() throws {
        let store = try makeStore()
        try store.setWeightPlan(loseWeightPlan())
        try store.insertExtraPlanForTesting(WeightPlan(
            aim: .gain, goalKilograms: Decimal(string: "70")!, weeklyPaceKilograms: Decimal(string: "0.25")!))

        XCTAssertThrowsError(try store.weightPlan()) { error in
            XCTAssertEqual(error as? GoalStoreError, GoalStoreError.corruptRecord("weight plan"))
        }
    }

    /// A store written before the plan existed opens under the current schema, keeps its goals, and takes a
    /// plan. The file is first written with the goal model alone, as the earlier build wrote it, then
    /// reopened by the store.
    func testAStoreWrittenBeforeThePlanOpensWithItsGoalsIntact() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("goals.store")
        do {
            let oldSchema = Schema([NutrientGoalRecord.self])
            let oldContainer = try ModelContainer(
                for: oldSchema,
                configurations: ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none))
            let context = ModelContext(oldContainer)
            context.insert(NutrientGoalRecord(
                nutrient: "protein", targetText: "60", unitSymbol: MeasureUnit.g.symbol))
            try context.save()
        }

        let store = try SwiftDataGoalStore(url: url)
        addTeardownBlock { store.close() }

        XCTAssertEqual(try store.goal(for: "protein")?.target, Decimal(60))
        XCTAssertNil(try store.weightPlan())
        try store.setWeightPlan(loseWeightPlan())
        assertSamePlan(try store.weightPlan(), loseWeightPlan())
    }

    // MARK: In-memory store

    func testTheInMemoryStoreRoundTripsAPlanAndRemovesIt() throws {
        let store = InMemoryWeightPlanStore()

        try store.setWeightPlan(loseWeightPlan())
        assertSamePlan(try store.weightPlan(), loseWeightPlan())

        try store.removeWeightPlan()
        XCTAssertNil(try store.weightPlan())
    }

    func testTheInMemoryStoreThrowsOnAFailedRead() {
        let store = InMemoryWeightPlanStore(plan: loseWeightPlan(), failReads: true)

        XCTAssertThrowsError(try store.weightPlan())
    }

    func testTheInMemoryStoreRefusesWritesWhenAsked() {
        let store = InMemoryWeightPlanStore(refusesWrites: true)

        XCTAssertThrowsError(try store.setWeightPlan(loseWeightPlan()))
        XCTAssertThrowsError(try store.removeWeightPlan())
    }

    func testTheInMemoryStoreWritesNothingForAnInvalidPlan() throws {
        let store = InMemoryWeightPlanStore(plan: loseWeightPlan())
        let invalid = WeightPlan(aim: .lose, goalKilograms: nil, weeklyPaceKilograms: nil)

        XCTAssertThrowsError(try store.setWeightPlan(invalid))

        assertSamePlan(try store.weightPlan(), loseWeightPlan())
    }
}
