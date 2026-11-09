import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The instant every strip test loads at: noon UTC on 2023-11-14, a Tuesday.
private let stripNow = stripInstant(14)

private func stripInstant(_ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar.date(from: DateComponents(year: 2023, month: 11, day: day, hour: 12))
        ?? Date(timeIntervalSince1970: 1_700_000_000)
}

private func stripDaysBack(_ back: Int) -> Date { stripInstant(14 - back) }

private struct StripFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue { .unknown }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// The Diary's week strip: the seven days the "This week" summary covers, read from the loaded journal.
/// Synthetic entries only, a fixed UTC zone and a fixed clock.
@MainActor
final class DiaryWeekStripModelTests: XCTestCase {
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

    private func logFood(_ store: JournalStore, daysBack back: Int, protein: Decimal = 12, energy: Decimal = 200) throws {
        let date = stripDaysBack(back)
        let snapshotID = "snapshot-\(UUID().uuidString.lowercased())"
        let product = ProductDefinition(
            snapshotID: snapshotID, productID: "product-\(snapshotID)", name: "Example product",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1", kind: .food,
            nutrients: ["protein": .known(protein, .g), "energy": .known(energy, .kcal)])
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-product", name: "Example product", amount: Decimal(100), unit: .g)],
            product: product, now: date)
    }

    private func logWater(_ store: JournalStore, daysBack back: Int) throws {
        let date = stripDaysBack(back)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-water", name: "Example water", amount: Decimal(250), unit: .mL)],
            product: nil, now: date)
    }

    private func makeModel(_ store: JournalStore, goals: GoalStore? = nil) -> JournalViewModel {
        JournalViewModel(
            store: store, goals: goals, lookup: StripFacts(), timeZoneIdentifier: "UTC",
            locale: Locale(identifier: "en_US_POSIX"), preferences: InMemoryDisplayPreferences())
    }

    private func dayKey(_ back: Int) -> String {
        JournalViewModel.dayKey(stripDaysBack(back), zone: TimeZone(identifier: "UTC") ?? .current)
    }

    /// The strip lists the seven days ending today, oldest first, each with its day letter and date number.
    func testTheStripShowsTheSevenDaysOfTheWeekSummary() throws {
        let journal = try makeJournalStore()
        try logFood(journal, daysBack: 0)
        let model = makeModel(journal)
        model.load(now: stripNow)

        let strip = try XCTUnwrap(model.weekStrip(chosen: nil, now: stripNow))
        XCTAssertEqual(strip.days.map(\.id), (0..<7).reversed().map { dayKey($0) })
        // 2023-11-08 (Wednesday) through 2023-11-14 (Tuesday).
        XCTAssertEqual(strip.days.map(\.letter), ["W", "T", "F", "S", "S", "M", "T"])
        XCTAssertEqual(strip.days.map(\.number), ["8", "9", "10", "11", "12", "13", "14"])
        XCTAssertEqual(strip.chosenID, dayKey(0), "the chosen day starts on today")
    }

    /// A logged day has a dot and an empty day has none, by the rule the summary counts logged days with:
    /// water alone does not log a day, and a day only Apple Health states intake for does.
    func testALoggedDayHasADotAndAnEmptyDayHasNone() throws {
        let journal = try makeJournalStore()
        try logFood(journal, daysBack: 0)
        try logFood(journal, daysBack: 2)
        try logWater(journal, daysBack: 3)
        let model = makeModel(journal)
        model.outsideIntakeByDay = [dayKey(5): .read(values: ["protein": 9], readKeys: ["protein"])]
        model.load(now: stripNow)

        let strip = try XCTUnwrap(model.weekStrip(chosen: nil, now: stripNow))
        let logged = Set(strip.days.filter(\.isLogged).map(\.id))
        XCTAssertEqual(logged, [dayKey(0), dayKey(2), dayKey(5)])
        XCTAssertEqual(model.weekSummary?.headline, "Logged \(logged.count) of 7 days", "the strip and the summary agree")
    }

    /// The chosen day's figures are the ones its day header shows, and a day with no section says so in the header's words.
    func testTheChosenDayShowsTheFiguresOfItsDayHeader() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logFood(journal, daysBack: 0, protein: 20, energy: 340)
        let model = makeModel(journal, goals: goals)
        model.load(now: stripNow)

        let today = try XCTUnwrap(model.diarySections.first { $0.id == dayKey(0) })
        let strip = try XCTUnwrap(model.weekStrip(chosen: dayKey(0), now: stripNow))
        XCTAssertEqual(strip.figures.calories, today.energyText)
        XCTAssertEqual(strip.figures.protein, today.headerBars.first { $0.id == "protein" }?.valueText)

        let empty = try XCTUnwrap(model.weekStrip(chosen: dayKey(3), now: stripNow))
        XCTAssertEqual(empty.chosenID, dayKey(3))
        XCTAssertEqual(empty.figures.calories, "Nothing logged yet")
        XCTAssertEqual(empty.figures.protein, "Nothing logged yet")
        XCTAssertEqual(empty.figures.water, "Nothing logged yet")
    }

    /// A goal Today hides keeps its target but leaves its figure off the strip, as it leaves its bar off the day header.
    func testAHiddenProteinGoalLeavesProteinOffTheStrip() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logFood(journal, daysBack: 0, protein: 20, energy: 340)
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("protein", shown: false)
        let model = JournalViewModel(
            store: journal, goals: goals, lookup: StripFacts(), timeZoneIdentifier: "UTC",
            locale: Locale(identifier: "en_US_POSIX"), preferences: preferences)
        model.load(now: stripNow)

        let strip = try XCTUnwrap(model.weekStrip(chosen: dayKey(0), now: stripNow))
        XCTAssertNil(strip.figures.protein)
        XCTAssertNotEqual(strip.figures.calories, "Nothing logged yet")
    }

    func testAHiddenWaterGoalLeavesWaterOffTheStrip() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL))
        try logFood(journal, daysBack: 0, protein: 20, energy: 340)
        try logWater(journal, daysBack: 0)
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("water", shown: false)
        let model = JournalViewModel(
            store: journal, goals: goals, lookup: StripFacts(), timeZoneIdentifier: "UTC",
            locale: Locale(identifier: "en_US_POSIX"), preferences: preferences)
        model.load(now: stripNow)

        let strip = try XCTUnwrap(model.weekStrip(chosen: dayKey(0), now: stripNow))
        XCTAssertNil(strip.figures.water)
        XCTAssertNotEqual(strip.figures.calories, "Nothing logged yet")
    }

    /// A day logged only through Apple Health follows the same rule: a hidden goal's figure stays off the strip.
    func testAHiddenGoalIsLeftOffAHealthOnlyDay() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logFood(journal, daysBack: 0)
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("protein", shown: false)
        let model = JournalViewModel(
            store: journal, goals: goals, lookup: StripFacts(), timeZoneIdentifier: "UTC",
            locale: Locale(identifier: "en_US_POSIX"), preferences: preferences)
        model.outsideIntakeByDay = [dayKey(5): .read(values: ["protein": 9], readKeys: ["protein"])]
        model.load(now: stripNow)

        let strip = try XCTUnwrap(model.weekStrip(chosen: dayKey(5), now: stripNow))
        XCTAssertTrue(try XCTUnwrap(strip.days.first { $0.id == dayKey(5) }).isLogged)
        XCTAssertNil(strip.figures.protein)
    }

    /// Each day carries the jump target the arrows and the date sheet get for that date.
    func testEachDayCarriesTheJumpTargetOfItsDate() throws {
        let journal = try makeJournalStore()
        try logFood(journal, daysBack: 0)
        try logFood(journal, daysBack: 4)
        let model = makeModel(journal)
        model.load(now: stripNow)

        let strip = try XCTUnwrap(model.weekStrip(chosen: nil, now: stripNow))
        for day in strip.days {
            XCTAssertEqual(day.jumpTarget, model.jumpTarget(for: day.date, now: stripNow), day.id)
        }
        let withEntries = try XCTUnwrap(strip.days.first { $0.id == dayKey(4) })
        XCTAssertEqual(withEntries.jumpTarget, JournalJumpTarget(sectionID: dayKey(4), message: nil))
        let without = try XCTUnwrap(strip.days.first { $0.id == dayKey(2) })
        XCTAssertNotNil(without.jumpTarget.message, "an empty day goes to the closest day with a sentence")
    }

    /// A day counted as logged only because Apple Health states intake never reads the empty wording.
    func testAHealthOnlyLoggedDayNeverReadsNothingLoggedYet() throws {
        let journal = try makeJournalStore()
        try logFood(journal, daysBack: 0)
        let model = makeModel(journal)
        model.outsideIntakeByDay = [dayKey(5): .read(values: ["protein": 9], readKeys: ["protein"])]
        model.load(now: stripNow)

        let strip = try XCTUnwrap(model.weekStrip(chosen: dayKey(5), now: stripNow))
        XCTAssertTrue(try XCTUnwrap(strip.days.first { $0.id == dayKey(5) }).isLogged)
        let texts: [String?] = [strip.figures.calories, strip.figures.protein, strip.figures.water]
        XCTAssertEqual(texts.compactMap { $0 }.count, 3)
        for text in texts.compactMap({ $0 }) {
            XCTAssertNotEqual(text, "Nothing logged yet")
            XCTAssertFalse(text.isEmpty)
        }
    }
}
