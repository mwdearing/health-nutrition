import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

private let noon = Date(timeIntervalSince1970: 1_700_049_600)

/// Answers from the snapshot an entry was recorded with, as the app's lookup does.
private struct GapsSnapshotFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue { .unknown }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// Answers each component by its id, the way a lookup that knows some foods and not others does.
private struct GapsComponentFacts: NutrientFactsLookup {
    let values: [String: [String: NutrientValue]]

    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        values[component.componentID]?[nutrient] ?? .unknown
    }
}

private func gapsSuite() -> UserDefaults {
    let name = "healthnutrition.tests.gaps.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
final class NutrientGapsTests: XCTestCase {
    private let men31 = ReferenceGroup(sex: .male, ageBand: .years31To50)

    private func reference(_ nutrient: String, _ group: ReferenceGroup? = nil) throws -> ReferenceIntake {
        try XCTUnwrap(ReferenceIntakes.intake(for: nutrient, group: group ?? men31))
    }

    private func row(_ nutrient: String, _ tally: NutrientDayTally, unit: MeasureUnit = .mg, grouped: Bool = true) throws -> NutrientGapRow {
        var compared: ReferenceIntake?
        if grouped { compared = try reference(nutrient) }
        return NutrientGapRow(
            nutrient: nutrient, label: NutrientNames.displayName(for: nutrient), unit: unit, tally: tally,
            reference: compared)
    }

    // MARK: Status

    func testNothingStatedIsNothingLoggedAndUnstatedIsUnknownNeverZero() throws {
        XCTAssertEqual(try row("iron", NutrientDayTally()).status, .nothingLogged)
        let unknown = try row("iron", NutrientDayTally(missing: 2))
        XCTAssertEqual(unknown.status, .unknown)
        XCTAssertEqual(unknown.amountText, "Unknown")
        XCTAssertEqual(unknown.detailLines, ["Unknown for 2 entries"])
        XCTAssertNil(unknown.statusText)
    }

    func testWithoutAGroupTheAmountIsShownAlone() throws {
        let plain = try row("zinc", NutrientDayTally(fromFood: 6, known: 1), grouped: false)
        XCTAssertEqual(plain.status, .noReference)
        XCTAssertEqual(plain.amountText, "6 mg")
        XCTAssertNil(plain.referenceText)
        XCTAssertNil(plain.statusText)
        XCTAssertNil(plain.foodFraction)
    }

    func testBelowTheReferenceIsOnlySaidPlainlyWhenEveryEntryStatedIt() throws {
        let complete = try row("zinc", NutrientDayTally(fromFood: 6, known: 2))
        XCTAssertEqual(complete.status, .belowReference)
        XCTAssertEqual(complete.statusText, "Below the RDA")
        XCTAssertEqual(complete.referenceText, "RDA 11 mg, upper limit 40 mg")
        let partial = try row("zinc", NutrientDayTally(fromFood: 6, known: 1, missing: 1))
        XCTAssertEqual(partial.status, .belowReferenceSoFar)
        XCTAssertEqual(partial.statusText, "Below the RDA so far")
        XCTAssertEqual(partial.amountText, "At least 6 mg")
    }

    func testKnownAmountsAloneCanReachTheReferenceEvenWithEntriesMissing() throws {
        let reached = try row("vitaminC", NutrientDayTally(fromFood: 60, fromSupplements: 500, known: 2, missing: 1))
        XCTAssertEqual(reached.status, .reachedReference)
        XCTAssertEqual(reached.statusText, "Reached the RDA")
        XCTAssertEqual(reached.detailLines, ["Food 60 mg, supplements 500 mg", "Unknown for 1 entry"])
    }

    func testAnAllSourcesLimitCountsFoodAndSupplementsTogether() throws {
        let over = try row("zinc", NutrientDayTally(fromFood: 30, fromSupplements: 15, known: 2))
        XCTAssertEqual(over.status, .aboveUpperLimit)
        XCTAssertEqual(over.statusText, "Above the upper limit")
    }

    func testASupplementOnlyLimitIgnoresFoodAndCountsSupplements() throws {
        // 500 mg of magnesium from food is above 350 mg, but the limit counts supplements alone.
        let food = try row("magnesium", NutrientDayTally(fromFood: 500, known: 1))
        XCTAssertEqual(food.status, .reachedReference)
        // 400 mg from a supplement is above it, even though the day is still below the 420 mg RDA.
        let pill = try row("magnesium", NutrientDayTally(fromFood: 0, fromSupplements: 400, known: 1))
        XCTAssertEqual(pill.status, .aboveUpperLimit)
        XCTAssertEqual(
            pill.detailLines,
            ["All from supplements",
             "The upper limit counts supplements and medicines only, not food or water. Supplements are checked."])
    }

    func testNiacinAndVitaminELimitsCheckTheSupplementFloorAndSaySo() throws {
        let niacin = try row("niacin", NutrientDayTally(fromFood: 30, fromSupplements: 40, known: 2))
        XCTAssertEqual(niacin.status, .aboveUpperLimit)
        // Food niacin (some of it may be fortified) never makes the day over the limit on its own.
        let food = try row("niacin", NutrientDayTally(fromFood: 60, known: 1))
        XCTAssertEqual(food.status, .reachedReference)
        XCTAssertEqual(
            food.detailLines.last,
            "The upper limit counts supplements and fortified foods, not food itself. Only supplements are checked.")
    }

    func testFolateAndVitaminALimitsAreNotCheckedBecauseTheFormIsUnknown() throws {
        // 1,500 mcg from a supplement may be folic acid stated as DFE, or methylfolate: not a proven excess.
        let folate = try row("folate", NutrientDayTally(fromSupplements: 1500, known: 1), unit: .mcg)
        XCTAssertEqual(folate.status, .reachedReference)
        XCTAssertEqual(folate.referenceText, "RDA 400 mcg, upper limit 1000 mcg of folic acid")
        XCTAssertEqual(
            folate.detailLines.last,
            "The upper limit counts folic acid only. The app can't tell it from other folate, so it isn't checked.")
        let vitaminA = try row("vitaminA", NutrientDayTally(fromSupplements: 5000, known: 1), unit: .mcg)
        XCTAssertEqual(vitaminA.status, .reachedReference)
        XCTAssertEqual(
            vitaminA.detailLines.last,
            "The upper limit counts preformed vitamin A only. The app can't tell it from beta carotene, so it isn't checked.")
    }

    func testANutrientWithNoLimitSaysSoRatherThanShowingNone() throws {
        let k = try row("vitaminK", NutrientDayTally(fromFood: 200, known: 1), unit: .mcg)
        XCTAssertEqual(k.referenceText, "AI 120 mcg, no upper limit set")
        XCTAssertEqual(k.statusText, "Reached the AI")
    }

    // MARK: Figures and the bar

    func testFiguresRoundForReadingButNeverShowARealAmountAsZero() {
        XCTAssertEqual(NutrientGapRow.figure(Decimal(string: "0.9")!, .mg), "0.9 mg")
        XCTAssertEqual(NutrientGapRow.figure(Decimal(string: "1.25")!, .mg), "1.3 mg")
        XCTAssertEqual(NutrientGapRow.figure(Decimal(string: "0.004")!, .mg), "< 0.01 mg")
        XCTAssertEqual(NutrientGapRow.figure(Decimal(string: "123.456")!, .mcg), "123.5 mcg")
        XCTAssertEqual(NutrientGapRow.figure(0, .mg), "0 mg")
    }

    func testTheBarSplitsFoodAndSupplementsAgainstTheReference() throws {
        let below = try row("zinc", NutrientDayTally(fromFood: Decimal(string: "5.5")!, known: 1))
        XCTAssertEqual(below.foodFraction, Decimal(string: "0.5"))
        XCTAssertEqual(below.supplementFraction, 0)
        XCTAssertNil(below.referenceMarker)
        // Past the reference the bar is full and the marker shows where 90 mg sits in 180 mg.
        let past = try row("vitaminC", NutrientDayTally(fromFood: 90, fromSupplements: 90, known: 2))
        XCTAssertEqual(past.foodFraction, Decimal(string: "0.5"))
        XCTAssertEqual(past.supplementFraction, Decimal(string: "0.5"))
        XCTAssertEqual(past.referenceMarker, Decimal(string: "0.5"))
    }

    // MARK: The shared limit rule

    func testTheSharedLimitCheckOnlyReportsACertainExcess() throws {
        let zinc = try reference("zinc")
        XCTAssertTrue(NutrientGaps.exceededLimit(intake: zinc, total: 45, supplementTotal: 15))
        XCTAssertFalse(NutrientGaps.exceededLimit(intake: zinc, total: 40, supplementTotal: 40))
        let magnesium = try reference("magnesium")
        XCTAssertFalse(NutrientGaps.exceededLimit(intake: magnesium, total: 500, supplementTotal: 0))
        XCTAssertTrue(NutrientGaps.exceededLimit(intake: magnesium, total: 400, supplementTotal: 400))
        XCTAssertFalse(NutrientGaps.exceededLimit(intake: try reference("folate"), total: 5000, supplementTotal: 5000))
        XCTAssertFalse(NutrientGaps.exceededLimit(intake: try reference("vitaminA"), total: 9000, supplementTotal: 9000))
        XCTAssertFalse(NutrientGaps.exceededLimit(intake: try reference("vitaminK"), total: 9000, supplementTotal: 9000))
        XCTAssertNil(NutrientGaps.limitNote(.allSources))
    }

    // MARK: Sections

    func testSectionsPutLimitsFirstAndUnknownsLast() throws {
        let rows = try [
            row("zinc", NutrientDayTally(fromFood: 6, known: 1)),
            row("vitaminC", NutrientDayTally(fromFood: 100, known: 1)),
            row("magnesium", NutrientDayTally(fromSupplements: 400, known: 1)),
            row("iron", NutrientDayTally(missing: 1)),
            row("iodine", NutrientDayTally(), unit: .mcg),
        ]
        let sections = NutrientGapsViewModel.sections(rows, hasGroup: true)
        XCTAssertEqual(sections.map(\.title), [
            "Above an upper limit", "Below the reference", "Reached the reference", "Not known today",
        ])
        XCTAssertEqual(sections.map { $0.rows.map(\.nutrient) }, [["magnesium"], ["zinc"], ["vitaminC"], ["iron", "iodine"]])
    }

    // MARK: The day from the journal

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func log(
        _ store: JournalStore, _ name: String, at date: Date, category: String = "food",
        amount: Decimal = 100, unit: MeasureUnit = .g, product: ProductDefinition? = nil, zone: String = "UTC"
    ) throws {
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: category, occurredAt: date, timeZoneIdentifier: zone)
        try store.create(
            intake, components: [IntakeComponent(
                componentID: Slug.make(name), name: name, amount: amount, unit: unit)],
            product: product, now: date)
    }

    private func product(_ id: String, kind: ProductKind, nutrients: [String: NutrientValue]) -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-\(id)", productID: "product-\(id)", name: id, labelBasis: "per 100 g",
            catalogOrigin: "test", catalogVersion: "1", kind: kind, nutrients: nutrients)
    }

    func testTheDaySplitsFoodFromSupplementsAndCountsUnstatedEntriesAsUnknown() throws {
        let store = try makeStore()
        try log(store, "Orange", at: noon, product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))
        try log(store, "Multi", at: noon, product: product("multi", kind: .supplement, nutrients: [
            "vitaminC": .known(500, .mg), "magnesium": .known(Decimal(string: "0.4")!, .g),
        ]))
        // Typed by hand: it states nothing, so it is unknown for every nutrient a food could carry.
        try log(store, "Toast", at: noon)
        // Water says nothing about vitamins, and yesterday is not today.
        try log(store, "Water", at: noon, category: "water", amount: 250, unit: .mL)
        try log(store, "Orange", at: noon.addingTimeInterval(-86_400), product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))

        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts(), preferences: preferences)
        model.load(now: noon)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.referenceGroup, men31)
        let vitaminC = try XCTUnwrap(model.rows.first { $0.nutrient == "vitaminC" })
        XCTAssertEqual(vitaminC.tally, NutrientDayTally(fromFood: 60, fromSupplements: 500, known: 2, missing: 1))
        XCTAssertEqual(vitaminC.status, .reachedReference)
        // 0.4 g is read in milligrams, and from a supplement it is above the supplement-only limit.
        let magnesium = try XCTUnwrap(model.rows.first { $0.nutrient == "magnesium" })
        XCTAssertEqual(magnesium.tally, NutrientDayTally(fromSupplements: 400, known: 1, missing: 2))
        XCTAssertEqual(magnesium.status, .aboveUpperLimit)
        // The multi does not declare iron, so it says nothing; the two foods do not state it either.
        let iron = try XCTUnwrap(model.rows.first { $0.nutrient == "iron" })
        XCTAssertEqual(iron.tally, NutrientDayTally(missing: 2))
        XCTAssertEqual(iron.status, .unknown)
        XCTAssertEqual(model.rows.map(\.nutrient), ReferenceIntakes.nutrients)
        XCTAssertEqual(model.sections.first?.title, "Above an upper limit")
    }

    func testATypedEntryKeepsTheComponentsItKnowsAndCountsTheRestAsUnknown() throws {
        let store = try makeStore()
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: noon, timeZoneIdentifier: "UTC")
        try store.create(
            intake, components: [
                IntakeComponent(componentID: "egg", name: "Egg", amount: 50, unit: .g),
                IntakeComponent(componentID: "toast", name: "Toast", amount: 30, unit: .g),
            ], product: nil, now: noon)
        let lookup = GapsComponentFacts(values: ["egg": ["zinc": .known(Decimal(string: "0.65")!, .mg)]])
        let model = NutrientGapsViewModel(store: store, lookup: lookup)
        model.load(now: noon)
        let zinc = try XCTUnwrap(model.rows.first { $0.nutrient == "zinc" })
        // The egg's zinc is known and kept; the toast's is not, so the entry is also one unknown.
        XCTAssertEqual(zinc.tally, NutrientDayTally(fromFood: Decimal(string: "0.65")!, known: 1, missing: 1))
        XCTAssertEqual(zinc.amountText, "At least 0.65 mg")
    }

    func testAnEntryWithTwoMissingComponentsCountsOnceAsMissing() throws {
        let store = try makeStore()
        let intake = Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: noon, timeZoneIdentifier: "UTC")
        try store.create(
            intake, components: [
                IntakeComponent(componentID: "toast", name: "Toast", amount: 30, unit: .g),
                IntakeComponent(componentID: "jam", name: "Jam", amount: 15, unit: .g),
            ], product: nil, now: noon)
        let model = NutrientGapsViewModel(store: store, lookup: GapsComponentFacts(values: [:]))
        model.load(now: noon)
        // Neither component states zinc, so the entry is one missing entry, not two.
        let zinc = try XCTUnwrap(model.rows.first { $0.nutrient == "zinc" })
        XCTAssertEqual(zinc.tally, NutrientDayTally(fromFood: 0, known: 0, missing: 1))
    }

    func testABelowThresholdBoundCountsAsMissingNotAsKnownOnTheGapsScreen() throws {
        let store = try makeStore()
        try log(store, "Seasoning", at: noon, product: product("seasoning", kind: .food, nutrients: [
            "vitaminC": .belowReportingThreshold(.mg),
        ]))
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts())
        model.load(now: noon)
        // A bound says the amount is small, not what it is: the entry is one missing entry and adds no known amount.
        let vitaminC = try XCTUnwrap(model.rows.first { $0.nutrient == "vitaminC" })
        XCTAssertEqual(vitaminC.tally, NutrientDayTally(fromFood: 0, known: 0, missing: 1))
    }

    func testAFullyKnownEntryIsTalliedOnItsOwnWithNoMissingEntry() throws {
        let store = try makeStore()
        try log(store, "Orange", at: noon, product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts())
        model.load(now: noon)
        let vitaminC = try XCTUnwrap(model.rows.first { $0.nutrient == "vitaminC" })
        XCTAssertEqual(vitaminC.tally, NutrientDayTally(fromFood: 60, known: 1, missing: 0))
    }

    func testAnEntryWhoseDayCannotBeToldIsCountedAndSaid() throws {
        let store = try makeStore()
        try log(store, "Orange", at: noon, product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))
        let bad = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: noon, timeZoneIdentifier: "Not/AZone")
        try store.create(
            bad, components: [IntakeComponent(componentID: "bad", name: "Bad zone", amount: 100, unit: .g)],
            product: nil, now: noon)
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts())
        model.load(now: noon)
        XCTAssertEqual(model.skippedIntakeCount, 1)
        XCTAssertEqual(
            model.skippedNotice,
            "1 entry has a time zone the app can't read and is left out, so these figures may be low.")
        XCTAssertEqual(model.rows.first { $0.nutrient == "vitaminC" }?.tally, NutrientDayTally(fromFood: 60, known: 1))
    }

    func testTheWeekAveragesOverTheDaysSomethingWasLogged() throws {
        let store = try makeStore()
        let day: TimeInterval = 86_400
        try log(store, "Orange", at: noon, product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))
        try log(store, "Multi", at: noon - 2 * day, product: product("multi", kind: .supplement, nutrients: [
            "vitaminC": .known(500, .mg),
        ]))
        // A water-only day is not a logged day, and days outside the last seven are not in the week.
        try log(store, "Water", at: noon - 3 * day, category: "water", amount: 250, unit: .mL)
        try log(store, "Old orange", at: noon - 7 * day, product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))
        try log(store, "Tomorrow's orange", at: noon + day, product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts(), preferences: preferences)

        model.chooseSpan(.week, now: noon)

        XCTAssertEqual(model.loggedDays, 2)
        XCTAssertEqual(model.spanSummary, "Average per day over the 2 days you logged in the last 7.")
        let vitaminC = try XCTUnwrap(model.rows.first { $0.nutrient == "vitaminC" })
        // (60 + 500) over 2 logged days: 30 mg from food and 250 mg from supplements a day.
        XCTAssertEqual(vitaminC.tally, NutrientDayTally(fromFood: 30, fromSupplements: 250, known: 2))
        XCTAssertEqual(vitaminC.status, .reachedReference)

        model.chooseSpan(.day, now: noon)
        XCTAssertEqual(model.loggedDays, 1)
        XCTAssertNil(model.spanSummary)
        XCTAssertEqual(
            model.rows.first { $0.nutrient == "vitaminC" }?.tally, NutrientDayTally(fromFood: 60, known: 1))
    }

    func testADailyUpperLimitIsCheckedDayByDayInTheWeek() throws {
        let store = try makeStore()
        let day: TimeInterval = 86_400
        // 400 mg of supplement magnesium on one day is above the 350 mg limit; spread over 3 logged
        // days the average is about 133 mg, which would hide it.
        try log(store, "Magnesium", at: noon - day, product: product("mag", kind: .supplement, nutrients: [
            "magnesium": .known(400, .mg),
        ]))
        try log(store, "Orange", at: noon, product: product("orange", kind: .food, nutrients: ["vitaminC": .known(60, .mg)]))
        try log(store, "Orange", at: noon - 2 * day, product: product("orange", kind: .food, nutrients: ["vitaminC": .known(60, .mg)]))
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts(), preferences: preferences)

        model.chooseSpan(.week, now: noon)

        let magnesium = try XCTUnwrap(model.rows.first { $0.nutrient == "magnesium" })
        XCTAssertEqual(model.loggedDays, 3)
        XCTAssertEqual(magnesium.daysAboveLimit, 1)
        XCTAssertEqual(magnesium.status, .aboveUpperLimit)
        XCTAssertTrue(magnesium.detailLines.contains("Above the upper limit on 1 of 3 logged days."))
        XCTAssertTrue(magnesium.accessibilityText.hasPrefix("Magnesium, daily average "))
        // A row with no figure is not read as an average of nothing.
        let iodine = try XCTUnwrap(model.rows.first { $0.nutrient == "iodine" })
        XCTAssertFalse(iodine.accessibilityText.contains("daily average"))
    }

    func testTheUpperLimitLineCountsEveryLoggedDay() throws {
        let store = try makeStore()
        let day: TimeInterval = 86_400
        try log(store, "Magnesium", at: noon - day, product: product("mag", kind: .supplement, nutrients: [
            "magnesium": .known(400, .mg),
        ]))
        // Today only a vitamin C supplement was logged, which says nothing about magnesium.
        try log(store, "Vitamin C", at: noon, product: product("c", kind: .supplement, nutrients: [
            "vitaminC": .known(500, .mg),
        ]))
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts(), preferences: preferences)

        model.chooseSpan(.week, now: noon)

        let magnesium = try XCTUnwrap(model.rows.first { $0.nutrient == "magnesium" })
        XCTAssertEqual(model.loggedDays, 2)
        XCTAssertEqual(magnesium.averagedOverDays, 1)
        XCTAssertTrue(magnesium.detailLines.contains(
            "Averaged over 1 of 2 logged days. Nothing else you logged lists it."))
        XCTAssertTrue(magnesium.detailLines.contains("Above the upper limit on 1 of 2 logged days."))
    }

    func testEntriesOnDifferentDatesInDifferentTimeZonesAreNeverOneDay() throws {
        let store = try makeStore()
        // Now is Wednesday 15 November 2023, 20:00 in Chicago, which is Thursday 11:00 in Tokyo.
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let magnesium = product("mag", kind: .supplement, nutrients: ["magnesium": .known(200, .mg)])
        // Wednesday 09:00 in Tokyo and Tuesday 20:00 in Chicago are each one day before their own today,
        // but they are different dates, so neither day holds 400 mg.
        try log(store, "Magnesium", at: Date(timeIntervalSince1970: 1_700_006_400), product: magnesium, zone: "Asia/Tokyo")
        try log(store, "Magnesium", at: Date(timeIntervalSince1970: 1_700_013_600), product: magnesium, zone: "America/Chicago")
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts(), preferences: preferences)

        model.chooseSpan(.week, now: now)

        XCTAssertEqual(model.loggedDays, 2)
        let row = try XCTUnwrap(model.rows.first { $0.nutrient == "magnesium" })
        XCTAssertEqual(row.averagedOverDays, 2)
        XCTAssertEqual(row.daysAboveLimit, 0)
        XCTAssertNotEqual(row.status, .aboveUpperLimit)
        XCTAssertEqual(row.tally.total, 200)
    }

    func testADayThatSaysNothingAboutANutrientDoesNotDiluteItsAverage() throws {
        let store = try makeStore()
        let day: TimeInterval = 86_400
        try log(store, "Orange", at: noon, product: product("orange", kind: .food, nutrients: ["vitaminC": .known(60, .mg)]))
        // Yesterday only a magnesium supplement was logged: it says nothing about vitamin C.
        try log(store, "Magnesium", at: noon - day, product: product("mag", kind: .supplement, nutrients: [
            "magnesium": .known(200, .mg),
        ]))
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts())

        model.chooseSpan(.week, now: noon)

        XCTAssertEqual(model.loggedDays, 2)
        let vitaminC = try XCTUnwrap(model.rows.first { $0.nutrient == "vitaminC" })
        XCTAssertEqual(vitaminC.tally, NutrientDayTally(fromFood: 60, known: 1))
        XCTAssertEqual(vitaminC.averagedOverDays, 1)
        XCTAssertTrue(vitaminC.detailLines.contains(
            "Averaged over 1 of 2 logged days. Nothing else you logged lists it."))
        // Magnesium was stated only by the supplement; the orange says nothing about it either way.
        let magnesium = try XCTUnwrap(model.rows.first { $0.nutrient == "magnesium" })
        XCTAssertEqual(magnesium.averagedOverDays, 2)
    }

    func testAWeekWithNothingLoggedSaysSo() throws {
        let model = NutrientGapsViewModel(store: try makeStore(), lookup: GapsSnapshotFacts())
        model.chooseSpan(.week, now: noon)
        XCTAssertEqual(model.loggedDays, 0)
        XCTAssertEqual(model.spanSummary, "Nothing was logged in the last 7 days.")
        XCTAssertTrue(model.rows.allSatisfy { $0.status == .nothingLogged })
        XCTAssertEqual(model.sections.map(\.title), ["Not known this week"])
    }

    func testTheWeekHasItsOwnHeadingsAndIntro() throws {
        let rows = [try row("zinc", NutrientDayTally(fromFood: 6, known: 1), grouped: false)]
        XCTAssertEqual(NutrientGapsViewModel.sections(rows, hasGroup: false, span: .week).map(\.title), ["Last 7 days"])
        XCTAssertEqual(
            NutrientGapsCopy.intro(hasGroup: true, span: .week),
            "Your daily averages beside the published adult values for this group.")
        XCTAssertEqual(
            NutrientGapsCopy.intro(hasGroup: true), "Today's amounts beside the published adult values for this group.")
        XCTAssertEqual(
            NutrientGapsCopy.intro(hasGroup: false, span: .week),
            "Pick a group to see your daily averages beside its published adult values.")
    }

    func testDaysBeforeCountsLocalDaysInTheEntrysOwnZone() {
        let entry = Intake(id: "x", category: "food", occurredAt: noon - 6 * 86_400, timeZoneIdentifier: "UTC")
        XCTAssertEqual(NutrientGapsViewModel.daysBefore(noon, entry), 6)
        let bad = Intake(id: "y", category: "food", occurredAt: noon, timeZoneIdentifier: "Not/AZone")
        XCTAssertNil(NutrientGapsViewModel.daysBefore(noon, bad))
    }

    func testClearingTheGroupShowsAmountsAloneAndForgetsTheChoice() throws {
        let store = try makeStore()
        try log(store, "Orange", at: noon, product: product("orange", kind: .food, nutrients: [
            "vitaminC": .known(60, .mg),
        ]))
        let preferences = InMemoryDisplayPreferences()
        let model = NutrientGapsViewModel(store: store, lookup: GapsSnapshotFacts(), preferences: preferences)
        model.load(now: noon)
        XCTAssertNil(model.referenceGroup)
        XCTAssertEqual(model.sections.map(\.title), ["Today", "Not known today"])

        model.chooseReferenceGroup(ReferenceGroup(sex: .female, ageBand: .years19To30))
        XCTAssertEqual(preferences.referenceGroup, ReferenceGroup(sex: .female, ageBand: .years19To30))
        XCTAssertEqual(model.rows.first { $0.nutrient == "vitaminC" }?.status, .belowReference)

        model.chooseReferenceGroup(nil)
        XCTAssertNil(preferences.referenceGroup)
        XCTAssertEqual(model.rows.first { $0.nutrient == "vitaminC" }?.status, .noReference)
    }

    func testTodayHandsTheScreenItsStoreAndTheStoredGroup() throws {
        let store = try makeStore()
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC", preferences: preferences)
        let gaps = today.makeNutrientGaps()
        XCTAssertEqual(gaps.referenceGroup, men31)
    }

    // MARK: Stored choice

    func testTheGroupIsStoredAsOneKeyAndErasedWithTheOtherPreferences() {
        let defaults = gapsSuite()
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)
        XCTAssertNil(preferences.referenceGroup)
        preferences.setReferenceGroup(ReferenceGroup(sex: .female, ageBand: .years51To70))
        XCTAssertEqual(defaults.string(forKey: "display.reference.group"), "female.years51To70")
        XCTAssertEqual(
            UserDefaultsDisplayPreferences(defaults: defaults).referenceGroup,
            ReferenceGroup(sex: .female, ageBand: .years51To70))
        preferences.resetToDefaults()
        XCTAssertNil(defaults.object(forKey: "display.reference.group"))
        XCTAssertNil(preferences.referenceGroup)
    }

    func testAStoredValueThatIsNotAPublishedRowReadsAsNoGroup() {
        let defaults = gapsSuite()
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)
        for text in [
            "", "female", "female.years12To18", "other.years19To30", "female.years19To30.extra",
            "male.years19To30.pregnancy", "female.years51To70.lactation", "female.years19To30.standard",
            "female.years19To30.pregnancy.extra",
        ] {
            defaults.set(text, forKey: "display.reference.group")
            XCTAssertNil(preferences.referenceGroup, text)
        }
    }

    func testAPregnancyRowIsComparedWithItsOwnValuesAndLimit() throws {
        let pregnant = try XCTUnwrap(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years31To50))
        // 3,600 mg of phosphorus is under the adult 4,000 mg limit but over pregnancy's 3,500 mg.
        let phosphorus = NutrientGapRow(
            nutrient: "phosphorus", label: "Phosphorus", unit: .mg,
            tally: NutrientDayTally(fromFood: 3600, known: 1),
            reference: ReferenceIntakes.intake(for: "phosphorus", group: pregnant))
        XCTAssertEqual(phosphorus.status, .aboveUpperLimit)
        XCTAssertEqual(phosphorus.referenceText, "RDA 700 mg, upper limit 3500 mg")
        // 18 mg of iron reaches a woman's RDA but is below pregnancy's 27 mg.
        let iron = NutrientGapRow(
            nutrient: "iron", label: "Iron", unit: .mg, tally: NutrientDayTally(fromFood: 18, known: 1),
            reference: ReferenceIntakes.intake(for: "iron", group: pregnant))
        XCTAssertEqual(iron.status, .belowReference)
    }

    func testAPregnancyOrBreastfeedingGroupIsStoredAndReadBack() throws {
        let defaults = gapsSuite()
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)
        let pregnant = try XCTUnwrap(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years31To50))
        preferences.setReferenceGroup(pregnant)
        XCTAssertEqual(defaults.string(forKey: "display.reference.group"), "female.years31To50.pregnancy")
        XCTAssertEqual(UserDefaultsDisplayPreferences(defaults: defaults).referenceGroup, pregnant)
        // An adult row keeps the two-part form it was stored in before.
        preferences.setReferenceGroup(ReferenceGroup(sex: .female, ageBand: .years31To50))
        XCTAssertEqual(defaults.string(forKey: "display.reference.group"), "female.years31To50")
    }

    func testTheInMemoryStoreClearsTheGroupOnReset() {
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        preferences.resetToDefaults()
        XCTAssertNil(preferences.referenceGroup)
    }
}
