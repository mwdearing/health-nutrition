import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The instant every week test loads at: noon UTC on 2023-11-14, so today is the 14th in UTC.
private let weekNow = utcWeekInstant(2023, 11, 14)

/// A UTC instant at noon on the given day, so a day lands on that same day in the zone the tests use.
private func utcWeekInstant(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        ?? Date(timeIntervalSince1970: 1_700_000_000)
}

/// Noon UTC on the day `back` days before the 14th of November 2023. Zero is today.
private func daysBack(_ back: Int) -> Date {
    utcWeekInstant(2023, 11, 14 - back)
}

/// Reads a stored snapshot's values as they are, and the builder scales them to the amount logged.
private struct WeekFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// The Journal's week summary: the seven local days ending today, read from the loaded day sections.
/// Synthetic entries only, a fixed UTC zone and a fixed clock.
@MainActor
final class JournalWeekSummaryTests: XCTestCase {
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

    /// A typed food entry with no product, so none of its nutrients can be totaled.
    private func logTypedFood(_ store: JournalStore, daysBack back: Int) throws {
        let date = daysBack(back)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-typed", name: "Example typed", amount: Decimal(100), unit: .g)],
            product: nil, now: date)
    }

    /// A food-or-supplement entry of 100 g whose product states `nutrients` per 100 g.
    private func logProduct(
        _ store: JournalStore, daysBack back: Int, kind: ProductKind = .food,
        nutrients: [String: NutrientValue]
    ) throws {
        let date = daysBack(back)
        let snapshotID = "snapshot-\(UUID().uuidString.lowercased())"
        let product = ProductDefinition(
            snapshotID: snapshotID, productID: "product-\(snapshotID)", name: "Example product",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1", kind: kind, nutrients: nutrients)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-product", name: "Example product", amount: Decimal(100), unit: .g)],
            product: product, now: date)
    }

    /// A food entry of 100 g of a product stating `protein` grams per 100 g.
    private func logProtein(_ store: JournalStore, daysBack back: Int, _ protein: Decimal) throws {
        try logProduct(store, daysBack: back, nutrients: ["protein": .known(protein, .g)])
    }

    /// A water entry of 250 mL, which is not a food or drink in the week's sense.
    private func logWater(_ store: JournalStore, daysBack back: Int) throws {
        let date = daysBack(back)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-water", name: "Example water", amount: Decimal(250), unit: .mL)],
            product: nil, now: date)
    }

    private func makeModel(
        _ store: JournalStore, goals: GoalStore? = nil,
        preferences: DisplayPreferences = InMemoryDisplayPreferences()
    ) -> JournalViewModel {
        JournalViewModel(
            store: store, goals: goals, lookup: WeekFacts(), timeZoneIdentifier: "UTC",
            locale: Locale(identifier: "en_US_POSIX"), preferences: preferences)
    }

    // MARK: Days logged

    /// Food on today, two days back and five days back: three logged days with gaps between them.
    func testLoggedCountIsTheDaysWithFoodAcrossAGap() throws {
        let journal = try makeJournalStore()
        try logProtein(journal, daysBack: 0, 13)
        try logProtein(journal, daysBack: 2, 13)
        try logProtein(journal, daysBack: 5, 13)

        let model = makeModel(journal)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.headline, "Logged 3 of 7 days")
    }

    /// A water-only day and a supplement-only day do not count; a food day does.
    func testWaterOnlyAndSupplementOnlyDaysDoNotCount() throws {
        let journal = try makeJournalStore()
        try logWater(journal, daysBack: 0)
        try logProduct(journal, daysBack: 1, kind: .supplement, nutrients: ["protein": .known(Decimal(50), .g)])
        try logProtein(journal, daysBack: 2, 13)

        let model = makeModel(journal)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.headline, "Logged 1 of 7 days")
    }

    // MARK: Averages

    /// The average is over the logged days only. The supplement-only day holds 50 g of protein, which
    /// would move the average if it were counted: (13 + 14) / 2 is 13.5, not (13 + 14 + 50) / 3.
    func testTheAverageIsOverLoggedDaysOnly() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logProtein(journal, daysBack: 0, 13)
        try logProduct(journal, daysBack: 1, kind: .supplement, nutrients: ["protein": .known(Decimal(50), .g)])
        try logProtein(journal, daysBack: 2, 14)

        let model = makeModel(journal, goals: goals)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.goalLines, ["Protein: average 13.5 g a day against 60 g"])
    }

    /// The target in the line is the stored goal, not the day's total and not a default.
    func testTheTargetInTheLineIsTheStoredGoal() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(45), unit: .g))
        try logProtein(journal, daysBack: 0, 13)

        let model = makeModel(journal, goals: goals)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.goalLines, ["Protein: average 13 g a day against 45 g"])
    }

    /// An average that does not end (40 / 3) is shown to one fraction digit, as a figure of ten or more.
    func testAnAverageThatDoesNotEndIsRoundedForShowing() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logProtein(journal, daysBack: 0, 13)
        try logProtein(journal, daysBack: 2, 13)
        try logProtein(journal, daysBack: 4, 14)

        let model = makeModel(journal, goals: goals)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.goalLines, ["Protein: average 13.3 g a day against 60 g"])
    }

    /// A day whose protein cannot be totaled is left out of the average and counted in the parenthetical.
    func testADayWithAnUnknownTotalIsCountedNotAveraged() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logProtein(journal, daysBack: 0, 13)
        try logTypedFood(journal, daysBack: 2)
        try logProtein(journal, daysBack: 4, 14)

        let model = makeModel(journal, goals: goals)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.headline, "Logged 3 of 7 days")
        XCTAssertEqual(
            model.weekSummary?.goalLines,
            ["Protein: average 13.5 g a day against 60 g (1 day could not be totaled)"])
    }

    /// When no logged day can total the nutrient, the line says so and gives no figure.
    func testANutrientNoLoggedDayCanTotalSaysCantTotalYet() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logTypedFood(journal, daysBack: 0)

        let model = makeModel(journal, goals: goals)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.goalLines, ["Protein: can't total yet"])
    }

    // MARK: Goals on Today

    /// A goal switched off on Today gets no line, water never gets one, and the rest keep their order.
    func testHiddenGoalsAreLeftOutAndWaterNeverShows() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL))
        try logProduct(journal, daysBack: 0, nutrients: [
            "protein": .known(Decimal(13), .g), "fiber": .known(Decimal(4), .g),
        ])
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("protein", shown: false)

        let model = makeModel(journal, goals: goals, preferences: preferences)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.goalLines, ["Fiber: average 4 g a day against 30 g"])
    }

    // MARK: Window

    /// Entries older than seven days are ignored: today and six days back count, seven days back does not.
    func testEntriesOlderThanSevenDaysAreIgnored() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logProtein(journal, daysBack: 6, 13)
        try logProtein(journal, daysBack: 7, 99)

        let model = makeModel(journal, goals: goals)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.headline, "Logged 1 of 7 days")
        XCTAssertEqual(model.weekSummary?.goalLines, ["Protein: average 13 g a day against 60 g"])
    }

    /// A journal whose only entries are older than the week says nothing was logged this week, and gives no line.
    func testAnEmptyWeekSaysNothingWasLogged() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logProtein(journal, daysBack: 10, 13)

        let model = makeModel(journal, goals: goals)
        model.load(now: weekNow)

        XCTAssertEqual(model.weekSummary?.headline, "Nothing logged this week.")
        XCTAssertEqual(model.weekSummary?.goalLines, [])
    }

    /// An empty journal has no summary at all, before or after a load.
    func testAnEmptyJournalHasNoSummary() throws {
        let journal = try makeJournalStore()

        let model = makeModel(journal)
        XCTAssertNil(model.weekSummary)
        model.load(now: weekNow)

        XCTAssertNil(model.weekSummary)
    }

    // MARK: Units

    /// Nutrient goals read in grams under the US system too, exactly as the goal bars on the same screen do.
    func testUSUnitsKeepNutrientGoalsInGrams() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logProtein(journal, daysBack: 0, 13)
        let preferences = InMemoryDisplayPreferences(unitSystem: .usCustomary)

        let model = makeModel(journal, goals: goals, preferences: preferences)
        model.load(now: weekNow)

        let line = try XCTUnwrap(model.weekSummary?.goalLines.first)
        XCTAssertTrue(line.hasPrefix("Protein: average "), line)
        XCTAssertTrue(line.hasSuffix(" g a day against 60 g"), line)
    }
}
