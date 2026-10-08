import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// What Today publishes for the redesigned screen: the goal bars, the water bar, the entries grouped
/// by meal, and the one line that replaces the Coverage section. The older line models stay under
/// test in `TodayTests` and `DailyGoalsTests`.
@MainActor
final class TodayDesignTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func oats(withValues: Bool, kind: ProductKind = .food) -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snap-oats-\(withValues)-\(kind.rawValue)", productID: "p-oats", name: "Sample oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1", kind: kind,
            nutrients: withValues ? ["protein": .known(Decimal(13), .g), "fiber": .known(Decimal(10), .g)] : [:])
    }

    @discardableResult
    private func log(
        _ store: JournalStore, name: String = "Sample oats", grams: Decimal = 100, meal: String? = nil,
        category: String = "food", product: ProductDefinition? = nil, at date: Date? = nil
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let when = date ?? now
        let unit: MeasureUnit = category == "water" ? .mL : .g
        try store.create(
            Intake(id: id, category: category, occurredAt: when, timeZoneIdentifier: "UTC", meal: meal),
            components: [IntakeComponent(componentID: id, name: name, amount: grams, unit: unit)],
            product: product, now: when)
        return id
    }

    private func model(
        _ store: JournalStore, goals: [NutrientGoal] = [], tracked: [String] = ["protein", "fiber"]
    ) -> TodayViewModel {
        TodayViewModel(
            store: store, goals: InMemoryGoalStore(goals: goals), lookup: SnapshotNutrientFacts(),
            trackedNutrients: tracked, timeZoneIdentifier: "UTC")
    }

    // MARK: Goal bars

    func testGoalBarsFollowTheTrackedOrderAndLeaveWaterToItsOwnCard() throws {
        let store = try makeStore()
        try log(store, product: oats(withValues: true))
        let today = model(store, goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])
        today.load(now: now)
        XCTAssertEqual(today.goalBars.map(\.id), ["protein", "fiber"])
        XCTAssertFalse(today.goalBars.contains { $0.id == "water" })
        XCTAssertEqual(today.goalBars.first?.valueText, "13 g of 60 g")
        XCTAssertEqual(today.goalBars.first?.state, .progress)
        XCTAssertEqual(today.goalBars.last?.state, .noGoal)
        XCTAssertEqual(today.progress.first?.text, "Protein 13 g of 60 g", "the line model is still published")
    }

    func testGoalBarsSayNothingLoggedOnADayWithNoFoodEvenWhenWaterIsLogged() throws {
        let store = try makeStore()
        try log(store, name: "Water", grams: 250, category: "water")
        let today = model(store, goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])
        today.load(now: now)
        XCTAssertEqual(today.goalBars.map(\.state), [.nothingLogged, .nothingLogged])
        XCTAssertEqual(today.goalBars.first?.valueText, "Nothing logged yet")
    }

    func testGoalBarNothingLoggedOnADayOfOnlySupplements() throws {
        let store = try makeStore()
        try log(store, name: "Sample multi", product: oats(withValues: false, kind: .supplement))
        let today = model(store)
        today.load(now: now)
        XCTAssertEqual(today.goalBars.map(\.state), [.nothingLogged, .nothingLogged])
        XCTAssertEqual(today.rows.count, 1, "the supplement is still listed")
    }

    func testGoalBarCannotTotalWhenAnEntryStatesNoValueAndSaysWhichKind() throws {
        let store = try makeStore()
        try log(store, product: oats(withValues: true))
        try log(store, name: "Plain toast", product: oats(withValues: false))
        let today = model(store, goals: [NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g)])
        today.load(now: now)
        let fiber = try XCTUnwrap(today.goalBars.first { $0.id == "fiber" })
        XCTAssertEqual(fiber.state, .cannotTotal)
        XCTAssertNil(fiber.fraction)
        XCTAssertEqual(fiber.reason, "1 entry has no fiber value")
    }

    func testGoalBarOverGoalKeepsTheRealFigureOnToday() throws {
        let store = try makeStore()
        try log(store, grams: 500, product: oats(withValues: true))
        let today = model(store, goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])
        today.load(now: now)
        let protein = try XCTUnwrap(today.goalBars.first { $0.id == "protein" })
        XCTAssertEqual(protein.state, .overGoal)
        XCTAssertEqual(protein.valueText, "65 g of 60 g")
        XCTAssertEqual(protein.fraction, Decimal(1))
    }

    func testWaterBarExistsOnlyWithAWaterGoalAndCountsWaterEntries() throws {
        let store = try makeStore()
        try log(store, name: "Water", grams: 250, category: "water")
        try log(store, name: "Water", grams: 250, category: "water")
        let without = model(store)
        without.load(now: now)
        XCTAssertNil(without.waterBar)
        XCTAssertEqual(without.waterEntryCount, 2)
        let goal = NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL)
        let with = model(store, goals: [goal])
        with.load(now: now)
        XCTAssertEqual(with.waterBar?.state, .progress)
        XCTAssertEqual(with.waterBar?.valueText, "500 mL of 2000 mL")
    }

    func testWaterBarIsNothingLoggedUntilAWaterEntryExists() throws {
        let store = try makeStore()
        try log(store, product: oats(withValues: true))
        let goal = NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL)
        let today = model(store, goals: [goal])
        today.load(now: now)
        XCTAssertEqual(today.waterBar?.state, .nothingLogged)
    }

    // MARK: Meal sections

    func testMealSectionsFollowBreakfastLunchDinnerSnackOtherAndSkipEmptyOnes() throws {
        let store = try makeStore()
        try log(store, name: "Late snack", meal: "snack")
        try log(store, name: "Porridge", meal: "breakfast")
        try log(store, name: "Soup", meal: "dinner")
        let today = model(store)
        today.load(now: now)
        XCTAssertEqual(today.mealSections.map(\.title), ["Breakfast", "Dinner", "Snack"])
        XCTAssertEqual(today.mealSections.first?.rows.map(\.title), ["Porridge"])
    }

    func testMealSectionPutsAnEntryWithoutAMealOrWithFreeTextInOther() throws {
        let store = try makeStore()
        try log(store, name: "Plain", meal: nil)
        try log(store, name: "Picnic", meal: "Picnic")
        let today = model(store)
        today.load(now: now)
        XCTAssertEqual(today.mealSections.map(\.title), ["Other"])
        XCTAssertEqual(Set(today.mealSections.first?.rows.map(\.title) ?? []), ["Plain", "Picnic"])
    }

    func testMealSectionsDoNotListWaterEntriesAsRows() throws {
        let store = try makeStore()
        try log(store, name: "Water", grams: 250, category: "water")
        try log(store, name: "Porridge", meal: "breakfast")
        let today = model(store)
        today.load(now: now)
        XCTAssertEqual(today.mealSections.flatMap(\.rows).map(\.title), ["Porridge"])
        XCTAssertEqual(today.waterEntryCount, 1)
        XCTAssertEqual(today.rows.count, 2, "the older flat list still holds every entry")
    }

    func testMealSectionIdsAreStableAcrossLoads() throws {
        let store = try makeStore()
        try log(store, name: "Porridge", meal: "Breakfast")
        let today = model(store)
        today.load(now: now)
        let first = today.mealSections.map(\.id)
        today.load(now: now)
        XCTAssertEqual(today.mealSections.map(\.id), first)
        XCTAssertEqual(today.mealSections.map(\.title), ["Breakfast"])
    }

    // MARK: The one line that replaces Coverage

    func testMissingValuesSummaryIsNilWhenNothingIsMissing() throws {
        let store = try makeStore()
        try log(store, product: oats(withValues: true))
        let today = model(store)
        today.load(now: now)
        XCTAssertNil(today.missingValuesSummary)
        let empty = model(try makeStore())
        empty.load(now: now)
        XCTAssertNil(empty.missingValuesSummary)
    }

    func testMissingValuesSummaryCountsFoodAndDrinkEntriesThatStateNoValues() throws {
        let store = try makeStore()
        try log(store, name: "Typed by hand")
        try log(store, name: "Plain toast", product: oats(withValues: false))
        try log(store, name: "Oats", product: oats(withValues: true))
        let today = model(store)
        today.load(now: now)
        XCTAssertEqual(today.missingValuesSummary, "2 entries have no nutrition values")
        let oneStore = try makeStore()
        try log(oneStore, name: "Typed by hand")
        let one = model(oneStore)
        one.load(now: now)
        XCTAssertEqual(one.missingValuesSummary, "1 entry has no nutrition values")
    }

    func testMissingValuesSummaryExcludesSupplementsAndWater() throws {
        let store = try makeStore()
        try log(store, name: "Sample multi", product: oats(withValues: false, kind: .supplement))
        try log(store, name: "Water", grams: 250, category: "water")
        let today = model(store)
        today.load(now: now)
        XCTAssertNil(today.missingValuesSummary)
    }

    // MARK: Date line and row time

    func testDateSubtitleReadsWeekdayMonthAndDayInTheModelsZone() throws {
        let today = model(try makeStore())
        today.load(now: now)
        XCTAssertEqual(today.dateSubtitle, "Tuesday, November 14")
    }

    func testRowsCarryTheTimeOfDayAndWhetherTheyAreWater() throws {
        let store = try makeStore()
        try log(store, name: "Porridge")
        try log(store, name: "Water", grams: 250, category: "water")
        let today = model(store)
        today.load(now: now)
        XCTAssertEqual(today.rows.map(\.timeText), ["22:13", "22:13"])
        XCTAssertEqual(today.rows.filter(\.isWater).count, 1)
        XCTAssertEqual(today.rows.first { !$0.isWater }?.detailLine, "100 g · 22:13")
    }
}
