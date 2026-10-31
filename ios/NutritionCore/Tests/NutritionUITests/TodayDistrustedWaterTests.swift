import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// #1137: an entry whose values are distrusted (a negative logged, stated or lookup value) and that carries water
/// makes the Diary's water for that day unknown. Today must not add that water as known; it shows the known part
/// as "at least" (Mike's pick A, 2026-10-31), or "No data" when nothing is known.
@MainActor
final class TodayDistrustedWaterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func log(
        _ store: SwiftDataJournalStore, category: String, componentID: String, amount: Decimal, share: Decimal?
    ) throws {
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: category, occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [
                IntakeComponent(componentID: componentID, name: componentID, amount: amount, unit: .mL, hydrationPercent: share)
            ],
            product: nil, now: now)
    }

    private func today(_ store: SwiftDataJournalStore) -> TodayViewModel {
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC", lookup: SuspectFacts())
        model.load(now: now)
        return model
    }

    private func diaryWater(_ store: SwiftDataJournalStore) throws -> NutrientValue? {
        try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SuspectFacts(), nutrients: ["water"]
        ).total(for: "water")?.value
    }

    /// The issue's case: 200 mL of water and a distrusted 250 mL soup with an 80% share. The Diary says the
    /// day's water is unknown; Today shows the known 200 mL as "at least", not 400 mL as known.
    func testADistrustedSoupWithAShareMakesTodaysWaterAtLeastTheKnownPart() throws {
        let store = try makeStore()
        try log(store, category: "water", componentID: "glass", amount: 200, share: nil)
        try log(store, category: "other", componentID: "suspect", amount: 250, share: 80)

        XCTAssertEqual(try diaryWater(store), .unknown)
        let model = today(store)
        XCTAssertEqual(model.waterTotalMilliliters, 200)
        XCTAssertTrue(model.waterHasUnknown)
        XCTAssertEqual(model.waterFigureText, "at least 200 mL")
        XCTAssertEqual(model.waterAccessibilityValue, "at least 200 milliliters today")
    }

    /// A distrusted drink is unknown water in the Diary, so Today does not count it either.
    func testADistrustedDrinkIsNotCountedAsKnownWater() throws {
        let store = try makeStore()
        try log(store, category: "water", componentID: "glass", amount: 200, share: nil)
        try log(store, category: "water", componentID: "suspect", amount: 300, share: nil)

        XCTAssertEqual(try diaryWater(store), .unknown)
        let model = today(store)
        XCTAssertEqual(model.waterTotalMilliliters, 200)
        XCTAssertEqual(model.waterFigureText, "at least 200 mL")
    }

    /// Nothing known: the figure reads the existing "No data", never "0 mL" or "at least 0 mL".
    func testOnlyADistrustedSoupReadsNoData() throws {
        let store = try makeStore()
        try log(store, category: "other", componentID: "suspect", amount: 250, share: 80)

        let model = today(store)
        XCTAssertEqual(model.waterTotalMilliliters, 0)
        XCTAssertEqual(model.waterFigureText, "No data")
        XCTAssertEqual(model.waterAccessibilityValue, "No data")
    }

    /// A distrusted food with no water share never carried water, so the day's water stays exact.
    func testADistrustedFoodWithNoShareLeavesWaterExact() throws {
        let store = try makeStore()
        try log(store, category: "water", componentID: "glass", amount: 200, share: nil)
        try log(store, category: "other", componentID: "suspect", amount: 250, share: nil)

        XCTAssertEqual(try diaryWater(store), .known(200, .mL))
        let model = today(store)
        XCTAssertFalse(model.waterHasUnknown)
        XCTAssertEqual(model.waterFigureText, "200 mL")
        XCTAssertEqual(model.waterAccessibilityValue, "200 milliliters today")
    }

    /// A healthy soup with a share still counts its water, unchanged.
    func testATrustedSoupWithAShareStillCounts() throws {
        let store = try makeStore()
        try log(store, category: "water", componentID: "glass", amount: 200, share: nil)
        try log(store, category: "other", componentID: "soup", amount: 250, share: 80)

        let model = today(store)
        XCTAssertEqual(model.waterTotalMilliliters, 400)
        XCTAssertFalse(model.waterHasUnknown)
        XCTAssertEqual(model.waterFigureText, "400 mL")
    }
}

/// Answers a negative protein for the component named "suspect", which distrusts that entry; nothing else is known.
private struct SuspectFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        value(for: component, snapshot: nil, nutrient: nutrient)
    }
    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        component.componentID == "suspect" && nutrient == "protein" ? .known(-5, .g) : .unknown
    }
}
