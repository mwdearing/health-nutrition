import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The persisted daily goals, read back.
///
/// The question these answer is what a read does with a row it cannot decode. `goal(for:)` throws for
/// one, so `goals()` did too: dropping it returned a shorter list that looked complete, and a caller
/// reading that list could not tell a corrupt row from a nutrient nobody set a target for. The two
/// answers have to be the same, or the store says two different things about itself.
final class GoalStoreTests: XCTestCase {
    private func makeStore() throws -> SwiftDataGoalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        addTeardownBlock { store.close() }
        return store
    }

    /// Every stored target, in nutrient-key order, and nothing lost: the read is still a plain read
    /// for a store whose rows are all decodable.
    func testEveryStoredTargetIsReadInNutrientOrder() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "sodium", target: Decimal(2300), unit: .mg))
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try store.setGoal(NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .kcal))

        let all = try store.goals()

        XCTAssertEqual(all.map(\.nutrient), ["energy", "protein", "sodium"])
        XCTAssertEqual(all.map(\.target), [Decimal(2000), Decimal(60), Decimal(2300)])
        XCTAssertEqual(all.map(\.unit), [.kcal, .g, .mg])
    }

    /// A target whose decimal cannot be parsed fails the whole read, as `goal(for:)` already does for
    /// the same row. A truncated or half-written store is not a store with fewer goals in it.
    func testACorruptDecimalFailsTheWholeRead() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try store.setGoal(NutrientGoal(nutrient: "sodium", target: Decimal(2300), unit: .mg))
        try store.writeCorruptTargetForTesting(nutrient: "protein", targetText: "6O g")

        XCTAssertThrowsError(try store.goals()) { error in
            XCTAssertEqual(error as? GoalStoreError, .corruptRecord("protein"))
        }
        // The same row, asked for by key: the same answer, from the same store.
        XCTAssertThrowsError(try store.goal(for: "protein")) { error in
            XCTAssertEqual(error as? GoalStoreError, .corruptRecord("protein"))
        }
        // The readable target is not what a caller gets instead of an answer about the corrupt one.
        XCTAssertEqual(try store.goal(for: "sodium")?.target, Decimal(2300))
    }

    /// A target stored in a unit this registry does not hold fails the read too. A unit symbol the
    /// registry rejects is not a target in some other dimension either, so it is not a number the
    /// screen could compare; reporting it as no goal would be reporting it as something it is not.
    func testACorruptUnitSymbolFailsTheWholeRead() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL))
        try store.writeCorruptTargetForTesting(nutrient: "water", unitSymbol: "cups")

        XCTAssertThrowsError(try store.goals()) { error in
            XCTAssertEqual(error as? GoalStoreError, .corruptRecord("water"))
        }
    }

    /// A target that is not a positive number is unreadable however it got there: zero would read as
    /// a met day and a negative one as more than met.
    func testAZeroOrNegativeTargetFailsTheWholeRead() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g))

        for corrupt in ["0", "-5"] {
            try store.writeCorruptTargetForTesting(nutrient: "fiber", targetText: corrupt)

            XCTAssertThrowsError(try store.goals(), corrupt) { error in
                XCTAssertEqual(error as? GoalStoreError, .corruptRecord("fiber"))
            }
        }
    }

    /// Repairing the row makes the store read again: the failure was the row, not the store, so a
    /// person who fixes their target is not left with a store that refuses to answer.
    func testAReadableRowIsReadAgainAfterTheCorruptOneIsRepaired() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try store.writeCorruptTargetForTesting(nutrient: "protein", targetText: "")
        XCTAssertThrowsError(try store.goals())

        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(75), unit: .g))

        XCTAssertEqual(try store.goals().map(\.target), [Decimal(75)])
    }

    /// Erasing is still a way out of a corrupt row: "Erase all data" clears the goals with everything
    /// else, and the store has to take a write afterwards rather than stay unreadable.
    func testACorruptRowIsGoneAfterAnErase() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try store.writeCorruptTargetForTesting(nutrient: "protein", targetText: "not a number")
        XCTAssertThrowsError(try store.goals())

        try store.eraseAll()

        XCTAssertTrue(try store.goals().isEmpty)
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(90), unit: .g))
        XCTAssertEqual(try store.goal(for: "protein")?.target, Decimal(90))
    }
}
