import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// The Today nutrient card: only nutrients with a value today, goal nutrients first, then the rest by the
/// fixed importance ranking, at most three rows, and no card at all when nothing qualifies (#817).
private let cardWhen = Date(timeIntervalSince1970: 1_700_000_000)

private struct CardFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue { .unknown }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

@MainActor
final class TodayNutrientCardTests: XCTestCase {
    private func makeJournalStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeGoalStore() throws -> SwiftDataGoalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
    }

    /// One food with fiber, sodium, potassium and iron stated, so all four have a value today.
    private func logFood(_ store: JournalStore) throws {
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-card", productID: "product-card", name: "Card food",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: [
                "fiber": .known(Decimal(10), .g), "sodium": .known(Decimal(300), .mg),
                "potassium": .known(Decimal(400), .mg), "iron": .known(Decimal(4), .mg),
            ])
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: cardWhen, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "food", name: "Card food", amount: Decimal(100), unit: .g)],
            product: snapshot, now: cardWhen)
    }

    /// The card's rows: every bar except the macros, energy and water, which the header or its own card shows.
    private func cardIDs(_ model: TodayViewModel) -> [String] {
        let outside: Set<String> = ["energy", "protein", "carbohydrate", "fat", "water"]
        return model.goalBars.map(\.id).filter { !outside.contains($0) }
    }

    /// With a goal, a logged value and two more logged nutrients, the card shows the goal first, then the
    /// highest ranked of the rest, and no more than three rows. Magnesium has a goal but nothing logged: hidden.
    func testCardShowsGoalsFirstThenRankedValuesAtMostThree() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try logFood(journal)
        try goals.setGoal(NutrientGoal(nutrient: "iron", target: Decimal(18), unit: .mg))
        try goals.setGoal(NutrientGoal(nutrient: "magnesium", target: Decimal(400), unit: .mg))

        let model = TodayViewModel(
            store: journal, goals: goals, lookup: CardFacts(), preferences: InMemoryDisplayPreferences())
        model.load(now: cardWhen)

        XCTAssertEqual(cardIDs(model), ["iron", "fiber", "sodium"])
    }

    /// With nothing logged and only an unlogged goal, there is no card to show.
    func testCardIsAbsentWhenNothingQualifies() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "magnesium", target: Decimal(400), unit: .mg))

        let model = TodayViewModel(
            store: journal, goals: goals, lookup: CardFacts(), preferences: InMemoryDisplayPreferences())
        model.load(now: cardWhen)

        XCTAssertEqual(cardIDs(model), [])
    }
}
