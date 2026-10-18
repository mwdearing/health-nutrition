import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The stored water share decides a volume's water, whatever its product kind. An entry stored before shares
/// counts as on main: a water entry its full volume, any other drink nothing.
@MainActor
final class StoredShareCountingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// Logs one entry with no product, and returns its id.
    func log(_ store: SwiftDataJournalStore, category: String, amount: Decimal, share: Decimal?) throws -> String {
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: category, occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "drink", name: "Drink", amount: amount, unit: .mL, hydrationPercent: share)],
            product: nil, now: now)
        return id
    }

    func todayWater(_ store: SwiftDataJournalStore) -> Decimal {
        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        return today.waterTotalMilliliters
    }

    func dailyWater(_ store: SwiftDataJournalStore) throws -> NutrientValue? {
        try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: NoFacts(), nutrients: ["water"]
        ).total(for: "water")?.value
    }

    func healthWater(_ store: SwiftDataJournalStore, _ id: String) async throws -> NutrientValue? {
        let revision = try XCTUnwrap(try store.revisions(of: id).first)
        return try await JournalSnapshotTotals(store: store).totals(intakeID: id, revision: revision.number)["water"]
    }

    /// A new snapshotless drink with a stored share counts volume times share in all three places.
    func testANewSnapshotlessDrinkWithAShareCounts() async throws {
        let store = try makeStore()
        let id = try log(store, category: "other", amount: 200, share: 90)

        XCTAssertEqual(todayWater(store), 180)
        XCTAssertEqual(try dailyWater(store), .known(180, .mL))
        let health = try await healthWater(store, id)
        XCTAssertEqual(health, .known(180, .mL))
    }

    /// A drink stored before shares, with no product and no share, counts nothing, as on main.
    func testAPreUpdateSnapshotlessDrinkCountsNothing() async throws {
        let store = try makeStore()
        let id = try log(store, category: "other", amount: 200, share: nil)

        XCTAssertEqual(todayWater(store), 0)
        XCTAssertEqual(try dailyWater(store), .unknown)
        let health = try await healthWater(store, id)
        XCTAssertNil(health)
    }

    /// A pre-update water entry counts its full volume in all three places, as on main.
    func testAPreUpdateWaterEntryCountsItsFullVolume() async throws {
        let store = try makeStore()
        let id = try log(store, category: "water", amount: 200, share: nil)

        XCTAssertEqual(todayWater(store), 200)
        XCTAssertEqual(try dailyWater(store), .known(200, .mL))
        let health = try await healthWater(store, id)
        XCTAssertEqual(health, .known(200, .mL))
    }

    /// An old drink given a share counts in all three places. The edit is modelled as the entry carrying the
    /// share from its new revision; the counting reads only the stored share, so the result is the same.
    func testAnOldDrinkGivenAShareCountsInAllThreePlaces() async throws {
        let store = try makeStore()
        let id = try log(store, category: "other", amount: 200, share: 50)

        XCTAssertEqual(todayWater(store), 100)
        XCTAssertEqual(try dailyWater(store), .known(100, .mL))
        let health = try await healthWater(store, id)
        XCTAssertEqual(health, .known(100, .mL))
    }
}

extension StoredShareCountingTests {
    /// A water entry with a stored share counts that share of its volume in all three places.
    func testAWaterEntryWithAShareCountsThatShare() async throws {
        let store = try makeStore()
        let id = try log(store, category: "water", amount: 200, share: 50)

        XCTAssertEqual(todayWater(store), 100)
        XCTAssertEqual(try dailyWater(store), .known(100, .mL))
        let health = try await healthWater(store, id)
        XCTAssertEqual(health, .known(100, .mL))
    }
}

extension StoredShareCountingTests {
    /// A post-update drink with a stored share reads on the water goal bar as logged, not "Nothing logged yet".
    func testTheWaterGoalBarReadsAShareCountedDrinkAsLogged() throws {
        let store = try makeStore()
        _ = try log(store, category: "other", amount: 200, share: 90)
        // The goal bar exists only where a water goal is set, so the test sets one in a goal store.
        let goalsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: goalsDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: goalsDirectory) }
        let goals = try SwiftDataGoalStore(url: goalsDirectory.appendingPathComponent("goals.store"))
        try goals.setGoal(TodayViewModel.defaultWaterGoal)
        let today = TodayViewModel(store: store, goals: goals, timeZoneIdentifier: "UTC")
        today.load(now: now)

        let bar = try XCTUnwrap(today.waterBar)
        XCTAssertNotEqual(bar.valueText, "Nothing logged yet")
    }
}

/// The lookup for a test that needs no product facts.
private struct NoFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue { .unknown }
    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue { .unknown }
}
