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

    /// A receipt that still lists a goal is not all written, so marking it done is refused and leaves it pending.
    func testMarkingAReceiptWithPendingGoalsDoneThrows() throws {
        let store = try makeStore()
        try store.recordGoalRestoreReceipt("pending-receipt", goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])
        XCTAssertThrowsError(try store.markGoalRestoreReceiptDone("pending-receipt"))
        XCTAssertEqual(try store.goalRestoreReceiptDone("pending-receipt"), false)
    }

    /// A goal the person already holds is skipped, not written, and still leaves the pending list, so a restore that
    /// skipped it can be marked done. Fails if a skipped goal stays pending, which the pending-goals guard would refuse.
    func testASkippedGoalLeavesTheReceiptSoItCanBeMarkedDone() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(90), unit: .g))
        try store.recordGoalRestoreReceipt("skip-receipt", goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])
        XCTAssertFalse(try store.writeRestoredGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g), receipt: "skip-receipt"))
        try store.markGoalRestoreReceiptDone("skip-receipt")
        XCTAssertEqual(try store.goalRestoreReceiptDone("skip-receipt"), true)
        XCTAssertEqual(try store.goal(for: "protein")?.target, Decimal(90), "the person's own goal is kept")
    }

    /// A receipt is recorded before its goals are written, so marking one done when it is not there means the store lost it.
    /// Fails when a missing receipt is marked done without an error, which would hide the loss.
    func testMarkingAMissingReceiptDoneThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.markGoalRestoreReceiptDone("never-recorded"))
    }

    /// A key outside the Goals screen's fixed list, such as a compound a captured label states, is stored and read
    /// back like any other key. `goals()` does not filter to the fixed list on purpose: a label's compound goal must
    /// come back so the screen can list it under "From your labels".
    func testAStoredCompoundKeyOutsideTheFixedListRoundTrips() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "creatine-monohydrate", target: Decimal(5), unit: .g))
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))

        let all = try store.goals()

        XCTAssertEqual(all.map(\.nutrient), ["creatine-monohydrate", "protein"])
        XCTAssertEqual(all.first, NutrientGoal(nutrient: "creatine-monohydrate", target: Decimal(5), unit: .g))
        XCTAssertEqual(try store.goal(for: "creatine-monohydrate"), all.first)
    }

    /// A compound row whose stored unit symbol cannot be decoded fails the whole read, as a fixed-list row does. The
    /// read does not drop the compound row and return the rest as if the list were complete.
    func testACompoundRowWithAnUndecodableUnitFailsTheWholeRead() throws {
        let store = try makeStore()
        try store.setGoal(NutrientGoal(nutrient: "creatine-monohydrate", target: Decimal(5), unit: .g))
        try store.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try store.writeCorruptTargetForTesting(nutrient: "creatine-monohydrate", unitSymbol: "cups")

        XCTAssertThrowsError(try store.goals()) { error in
            XCTAssertEqual(error as? GoalStoreError, .corruptRecord("creatine-monohydrate"))
        }
        XCTAssertEqual(try store.goal(for: "protein")?.target, Decimal(60))
    }
}
