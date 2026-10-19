import NutritionDomain
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

private struct FixedFacts: NutrientFactsLookup {
    let values: [String: NutrientValue]
    var missingNutrients: Set<String> = []
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        missingNutrients.contains(nutrient) ? .unknown : values[component.componentID] ?? .unknown
    }
}

private final class ThrowingGoalStore: GoalStore, @unchecked Sendable {
    private struct Failure: Error {}
    func goals() throws -> [NutrientGoal] { throw Failure() }
    func goal(for nutrient: String) throws -> NutrientGoal? { throw Failure() }
    func setGoal(_ goal: NutrientGoal) throws { throw Failure() }
    func removeGoal(nutrient: String) throws { throw Failure() }
    func close() {}
}

/// Serves canned intakes so tests can hold stored values the real store would refuse to create.
private final class StubJournalStore: JournalStore, @unchecked Sendable {
    var failNextSaveForTesting = false
    let intakes: [Intake]
    let components: [String: [IntakeComponent]]

    init(intakes: [Intake], components: [String: [IntakeComponent]]) {
        self.intakes = intakes
        self.components = components
    }

    private struct Unsupported: Error {}

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        throw Unsupported()
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        throw Unsupported()
    }

    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil, unitRemovals: [String])throws -> IntakeRevision {
        throw Unsupported()
    }
    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    var failReadsForTesting = false
    func activeIntakes() throws -> [Intake] {
        if failReadsForTesting { throw Unsupported() }
        return intakes
    }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        [IntakeRevision(
            intakeID: intakeID, number: 1, components: components[intakeID] ?? [], productSnapshotID: nil,
            changeReason: "test", createdAt: Date(timeIntervalSince1970: 0))]
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { nil }
    func activeIntakesFromBackground() async throws -> [Intake] { intakes }
    func close() {}
}

@MainActor
final class TodayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func addFood(
        _ store: JournalStore, name: String, id: String, at date: Date, zone: String = "UTC",
        amount: Decimal = 40, unit: MeasureUnit = .g, category: String = "food"
    ) throws -> String {
        let intakeID = UUID().uuidString.lowercased()
        let intake = Intake(id: intakeID, category: category, occurredAt: date, timeZoneIdentifier: zone)
        try store.create(
            intake, components: [IntakeComponent(componentID: id, name: name, amount: amount, unit: unit)],
            product: nil, now: date)
        return intakeID
    }

    /// An intake recorded against a supplement, with only the nutrients its panel declares.
    private func addSupplement(
        _ store: JournalStore, name: String, id: String, at date: Date, zone: String = "UTC",
        nutrients: [String: NutrientValue] = [:]
    ) throws -> String {
        let intakeID = UUID().uuidString.lowercased()
        let intake = Intake(id: intakeID, category: "food", occurredAt: date, timeZoneIdentifier: zone)
        try store.create(
            intake, components: [IntakeComponent(componentID: id, name: name, amount: 1, unit: .tablet)],
            product: ProductDefinition(
                snapshotID: "snap-\(id)", productID: "label_capture", name: name,
                labelBasis: "per serving (1 tablet)", catalogOrigin: "label_capture", catalogVersion: "unknown",
                kind: .supplement, nutrients: nutrients),
            now: date)
        return intakeID
    }

    /// A failed journal read is never shown as an empty day or as zero water.
    func testAFailedReadIsNotAnEmptyDayAndWaterIsUnknown() throws {
        let store = StubJournalStore(intakes: [], components: [:])
        store.failReadsForTesting = true
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")

        model.load(now: now)

        XCTAssertEqual(model.errorMessage, "Could not read the journal.")
        XCTAssertFalse(model.showsEmptyState, "a failed read is not an empty day")
        XCTAssertTrue(model.waterIsUnknown, "a failed read has no water total to show")
        XCTAssertEqual(model.waterUnknownSpokenValue, "Water not available")
        XCTAssertTrue(model.showsTryAgain, "a failed read offers Try again")
    }

    /// Nothing built from a failed read is 0 or a full goal: the calorie summary, goal bars and water bar are all absent.
    func testAFailedReadShowsNoCalorieSummaryGoalBarsOrWaterBar() throws {
        let store = StubJournalStore(intakes: [], components: [:])
        store.failReadsForTesting = true
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")

        model.load(now: now)

        XCTAssertNil(model.calorieRemaining.remaining, "no Remaining: not 0 and not the whole goal")
        XCTAssertNil(model.calorieRemaining.food, "no Food figure from a failed read")
        XCTAssertNil(model.calorieRemaining.burned, "no Burned figure from a failed read")
        XCTAssertTrue(model.progress.isEmpty, "no ring or progress from a failed read")
        XCTAssertTrue(model.goalBars.isEmpty, "no goal bars from a failed read")
        XCTAssertNil(model.waterBar, "no water goal bar from a failed read")
        XCTAssertNil(model.waterTotalMilliliters, "a failed read has no water total, not 0")
        XCTAssertEqual(model.waterDisplayText, "–")
        XCTAssertEqual(model.waterCardAccessibilityValue, "Water not available")
    }

    /// A failed goals read is not a failed journal read: the water total stays known and the journal message shows only
    /// the goals text.
    func testAGoalsOnlyFailureKeepsWaterKnown() throws {
        let store = StubJournalStore(intakes: [], components: [:])
        let model = TodayViewModel(
            store: store, goals: ThrowingGoalStore(), timeZoneIdentifier: "UTC")

        model.load(now: now)

        XCTAssertFalse(model.waterIsUnknown, "a goals failure does not make the water total unknown")
        XCTAssertFalse(model.journalReadFailed)
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(0))
    }

    /// A model that has not read yet has no water total: it shows a dash and "Water not available", never 0 mL.
    func testAFreshModelShowsWaterUnknownNotZero() throws {
        let model = TodayViewModel(store: StubJournalStore(intakes: [], components: [:]), timeZoneIdentifier: "UTC")

        XCTAssertNil(model.waterTotalMilliliters)
        XCTAssertFalse(model.showsEmptyState, "no read yet is not an empty day")
        XCTAssertTrue(model.waterIsUnknown)
        XCTAssertEqual(model.waterDisplayText, "–")
        XCTAssertEqual(model.waterCardAccessibilityValue, "Water not available")
    }

    /// Try again reloads the same day: a read that now succeeds clears the error and shows the empty day.
    func testTryAgainAfterAFailedReadShowsAnEmptyDay() throws {
        let store = StubJournalStore(intakes: [], components: [:])
        store.failReadsForTesting = true
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertTrue(model.waterIsUnknown)

        XCTAssertTrue(model.showsTryAgain)

        store.failReadsForTesting = false
        model.load(now: now)

        XCTAssertFalse(model.showsTryAgain, "a successful reload removes Try again")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.showsEmptyState)
        XCTAssertFalse(model.waterIsUnknown)
    }

    /// A genuinely empty day, read successfully, is the empty state with zero water.
    func testAnEmptyDayIsTheEmptyStateWithZeroWater() throws {
        let model = TodayViewModel(store: StubJournalStore(intakes: [], components: [:]), timeZoneIdentifier: "UTC")

        model.load(now: now)

        XCTAssertTrue(model.showsEmptyState)
        XCTAssertFalse(model.waterIsUnknown)
        XCTAssertEqual(model.waterTotalMilliliters, 0)
    }

    func testQuickAddWaterCreatesOneIntakeAtRevisionOneAndQueuesOutbox() throws {
        let store = try makeStore()
        // The amount is read from the preference rather than a literal, so this pins the writing of one
        // intake and the configured amount together, not the number 250.
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(250))
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC", preferences: preferences)
        let amount = model.quickWaterMilliliters
        XCTAssertEqual(amount, Decimal(250))
        let handle = model.quickAddWater(now: now)
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.count, 1)
        XCTAssertEqual(intakes.first?.currentRevision, 1)
        XCTAssertEqual(intakes.first?.category, "water")
        XCTAssertEqual(handle?.intakeID, intakes.first?.id)
        let revisions = try store.revisions(of: intakes[0].id)
        XCTAssertEqual(revisions.first?.components.first?.amount, amount)
        XCTAssertEqual(revisions.first?.components.first?.unit, .mL)
        XCTAssertFalse(try store.pendingOutbox().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().allSatisfy { $0.kind == .upsert })
        XCTAssertEqual(model.waterTotalMilliliters, amount)
    }

    func testQuickAddWaterUsesGivenAmountOnce() throws {
        let store = try makeStore()
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.quickAddWater(milliliters: Decimal(string: "330.5")!, now: now)
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(string: "330.5")!)
    }

    func testRapidDeletesKeepUndoOnTheSecondAndRestoreOnlyIt() throws {
        let store = try makeStore()
        // The window is checked against the commit clock, so this test uses the real clock throughout.
        let stamp = Date()
        let first = try addFood(store, name: "Oats", id: "oats", at: stamp)
        let second = try addFood(store, name: "Eggs", id: "eggs", at: stamp)
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: stamp)
        XCTAssertTrue(model.deleteEntry(intakeID: first, now: stamp))
        let firstSequence = store.deleteSequence
        XCTAssertTrue(model.deleteEntry(intakeID: second, now: stamp))
        let secondSequence = store.deleteSequence
        // The commit hooks arrive late, after both deletes have been made.
        model.deleteCommitted(sequence: firstSequence)
        model.deleteCommitted(sequence: secondSequence)
        XCTAssertEqual(model.undo?.intakeID, second)
        XCTAssertTrue(model.undoLastQuickAdd(now: stamp))
        XCTAssertEqual(try store.activeIntakes().map(\.id), [second])
        // The first delete is still queued, so it reaches Health and the relay once its window ends.
        XCTAssertEqual(try store.pendingDeleteRowCountForTesting(intakeID: first), 2)
    }

    func testLateHookForAnEarlierForeignDeleteKeepsTheNewerTodayOffer() throws {
        let store = try makeStore()
        // The window is checked against the commit clock, so this test uses the real clock throughout.
        let stamp = Date()
        let foreign = try addFood(store, name: "Milk", id: "milk", at: stamp)
        let mine = try addFood(store, name: "Oats", id: "oats", at: stamp)
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: stamp)
        // Another screen deletes first, then Today deletes; the other screen's hook arrives after Today's offer.
        let foreignSequence = try store.deleteSequenced(intakeID: foreign, now: stamp)
        XCTAssertTrue(model.deleteEntry(intakeID: mine, now: stamp))
        model.deleteCommitted(sequence: foreignSequence)
        XCTAssertEqual(model.undo?.intakeID, mine)
        XCTAssertTrue(model.undoLastQuickAdd(now: stamp))
        XCTAssertEqual(try store.activeIntakes().map(\.id), [mine])
    }

    func testForeignDeleteCommittedAfterTodayDeleteTakesTheOfferAway() throws {
        let store = try makeStore()
        let stamp = Date()
        let foreign = try addFood(store, name: "Milk", id: "milk", at: stamp)
        let mine = try addFood(store, name: "Oats", id: "oats", at: stamp)
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: stamp)
        XCTAssertTrue(model.deleteEntry(intakeID: mine, now: stamp))
        // A delete on another screen commits after Today's, so it is the most recent change.
        let foreignSequence = try store.deleteSequenced(intakeID: foreign, now: stamp)
        model.deleteCommitted(sequence: foreignSequence)
        XCTAssertNil(model.undo)
    }

    func testQuickAddWaterInvalidAmountsWriteNothing() throws {
        let store = try makeStore()
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        for amount in [Decimal(0), Decimal(-250), Decimal.nan] {
            let handle = model.quickAddWater(milliliters: amount, now: now)
            XCTAssertNil(handle)
            XCTAssertNil(model.undo)
            XCTAssertEqual(model.errorMessage, "Enter a water amount above zero.")
            XCTAssertTrue(try store.activeIntakes().isEmpty)
            XCTAssertTrue(try store.pendingOutbox().isEmpty)
        }
    }

    func testQuickAddWaterInvalidThenPositiveFractionalAmountStoredExactly() throws {
        let store = try makeStore()
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        XCTAssertNil(model.quickAddWater(milliliters: 0, now: now))
        let handle = model.quickAddWater(milliliters: Decimal(string: "333.5")!, now: now)
        XCTAssertNotNil(handle)
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.count, 1)
        let revisions = try store.revisions(of: intakes[0].id)
        XCTAssertEqual(revisions.first?.components.first?.amount, Decimal(string: "333.5")!)
    }

    func testUndoDeletesTheQuickAddedIntakeAndQueuesDeleteOps() throws {
        let store = try makeStore()
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        let handle = try XCTUnwrap(model.quickAddWater(now: now))
        XCTAssertTrue(model.isUndoAvailable(now: now.addingTimeInterval(5)))
        XCTAssertTrue(model.undoLastQuickAdd(now: now.addingTimeInterval(5)))
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().contains { $0.kind == .delete && $0.intakeID == handle.intakeID })
        XCTAssertEqual(try store.revisions(of: handle.intakeID).count, 1)
        XCTAssertEqual(model.waterTotalMilliliters, 0)
        XCTAssertNil(model.undo)
    }

    func testUndoExpiresAfterTenSeconds() throws {
        let store = try makeStore()
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.quickAddWater(now: now)
        XCTAssertFalse(model.isUndoAvailable(now: now.addingTimeInterval(10)))
        XCTAssertFalse(model.undoLastQuickAdd(now: now.addingTimeInterval(11)))
        XCTAssertEqual(try store.activeIntakes().count, 1)
    }

    func testInvalidAmountGivesErrorAndWritesNothing() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        model.name = "Rolled oats"
        for text in ["", "abc", "0", "-3", "1,5,0", "1e3", "1.2.3", "12g", "."] {
            model.amountText = text
            XCTAssertFalse(model.save(now: now), text)
            XCTAssertNotNil(model.amountError, text)
        }
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().isEmpty)
    }

    func testAddIntakeWithBlankNameIsRejected() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        model.name = "   "
        model.amountText = "10"
        XCTAssertFalse(model.save(now: now))
        XCTAssertNotNil(model.nameError)
        XCTAssertTrue(try store.activeIntakes().isEmpty)
    }

    func testValidAddIntakeCreatesOneIntakeWithExactDecimal() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        model.name = "Rolled oats"
        model.amountText = " 40.25 "
        XCTAssertTrue(model.save(now: now))
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.count, 1)
        let component = try XCTUnwrap(store.revisions(of: intakes[0].id).first?.components.first)
        XCTAssertEqual(component.amount, Decimal(string: "40.25", locale: Locale(identifier: "en_US_POSIX"))!)
        XCTAssertEqual(component.componentID, "rolled-oats")
        XCTAssertEqual(component.unit, .g)
        XCTAssertNil(model.amountError)
    }

    /// The meal a person picks on the Add form is what the entry stores, as the label's own raw
    /// value rather than as the words a screen shows.
    func testMealPickedOnTheAddFormIsStoredAsItsRawValue() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        XCTAssertNil(model.meal, "a form nobody has touched states no meal")
        model.name = "Rolled oats"
        model.amountText = "40"
        model.meal = .dinner
        XCTAssertTrue(model.save(now: now))
        XCTAssertEqual(try store.activeIntakes().first?.meal, MealLabel.dinner.rawValue)
        XCTAssertEqual(try store.activeIntakes().first?.meal, "dinner")
    }

    /// No label chosen means no meal stored, whatever hour the entry was logged at: a label is the
    /// person's own answer and nothing is guessed for them.
    func testMealStaysNilWhenNoneIsPicked() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        model.name = "Rolled oats"
        model.amountText = "40"
        // 07:13 UTC: an hour most people would call breakfast, which is exactly why it must not
        // become the answer for them.
        model.occurredAt = Date(timeIntervalSince1970: 1_700_000_000 - 15 * 3600)
        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(try store.activeIntakes().first?.meal)
        XCTAssertNil(MealLabel.displayName(for: try store.activeIntakes().first?.meal))
    }

    func testTodayShowsOnlyTheLocalDayOfEachIntakeTimeZone() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Today UTC", id: "a", at: now.addingTimeInterval(-3600))
        _ = try addFood(store, name: "Yesterday UTC", id: "b", at: now.addingTimeInterval(-86_400))
        // 12 hours earlier is still the same UTC day, but a different day in Auckland (UTC+13).
        _ = try addFood(store, name: "Auckland yesterday", id: "c", at: now.addingTimeInterval(-43_200), zone: "Pacific/Auckland")
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.rows.map(\.title), ["Today UTC"])
    }

    func testWaterTotalIsExactDecimalAndSkipsUnknownUnits() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Water", id: "water", at: now, amount: Decimal(string: "0.1")!, unit: .L, category: "water")
        _ = try addFood(store, name: "Water", id: "water", at: now, amount: Decimal(string: "250.3")!, unit: .mL, category: "water")
        _ = try addFood(store, name: "Water", id: "water", at: now, amount: 2, unit: .tablet, category: "water")
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(string: "350.3")!)
        XCTAssertEqual(model.waterSkippedCount, 1)
    }

    func testWaterTotalAddsLitresAndMilliliters() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Water", id: "water", at: now, amount: 1, unit: .L, category: "water")
        _ = try addFood(store, name: "Water", id: "water", at: now, amount: 250, unit: .mL, category: "water")
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(1250))
    }

    func testWaterTotalSkipsInvalidAmounts() throws {
        var intakes: [Intake] = []
        var components: [String: [IntakeComponent]] = [:]
        let amounts: [(String, Decimal, MeasureUnit)] = [
            ("a", 0, .mL), ("b", -5, .mL), ("c", Decimal.nan, .mL), ("d", -1, .L), ("e", 100, .mL),
        ]
        for (id, amount, unit) in amounts {
            intakes.append(Intake(id: id, category: "water", occurredAt: now, timeZoneIdentifier: "UTC"))
            components[id] = [IntakeComponent(componentID: "water", name: "Water", amount: amount, unit: unit)]
        }
        let model = TodayViewModel(store: StubJournalStore(intakes: intakes, components: components), timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(100))
        XCTAssertEqual(model.waterSkippedCount, 4)
    }

    func testInvalidTimeZoneIntakeIsSkippedAndCounted() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Good", id: "good", at: now)
        _ = try addFood(store, name: "Bad zone", id: "bad", at: now, zone: "Not/AZone")
        _ = try addFood(store, name: "Bad water", id: "water", at: now, zone: "Nope", amount: 500, unit: .mL, category: "water")
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.rows.map(\.title), ["Good"])
        XCTAssertEqual(model.skippedIntakeCount, 2)
        XCTAssertEqual(model.waterTotalMilliliters, 0)
        XCTAssertEqual(model.coverage.first?.total, 1)
        model.load(now: now)
        XCTAssertEqual(model.skippedIntakeCount, 2)
    }

    func testCoverageCountsUnknownAsMissing() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Banana", id: "banana", at: now)
        _ = try addFood(store, name: "Oats", id: "oats", at: now)
        _ = try addFood(store, name: "Mystery", id: "mystery", at: now)
        let facts = FixedFacts(values: ["banana": .known(Decimal(400), .mg)])
        let model = TodayViewModel(store: store, lookup: facts, trackedNutrients: ["potassium"], timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.coverage.map(\.text), ["2 of 3 foods lack potassium"])
    }

    func testDefaultLookupMakesEveryFoodUnknown() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Banana", id: "banana", at: now)
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(
            model.coverage.map(\.nutrient), ["energy", "protein", "carbohydrate", "fat", "fiber", "sodium", "potassium"])
        XCTAssertEqual(model.coverage.first?.text, "1 of 1 foods lack energy")
    }

    /// Today's lookup reads the values the entry's product snapshot carries, so a logged recipe counts
    /// as one food that states its nutrients instead of one food per nutrient.
    func testSnapshotLookupResolvesTheNutrientsALoggedRecipeCarries() throws {
        let store = try makeStore()
        let version = RecipeVersion(
            recipeID: "recipe-1", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                    perUnit: [
                        "energy": .known(Decimal(360), .kcal), "protein": .known(Decimal(13), .g),
                        "carbohydrate": .known(Decimal(60), .g), "fat": .known(Decimal(7), .g),
                        "sodium": .known(Decimal(2), .mg), "potassium": .known(Decimal(300), .mg),
                        "fiber": .known(Decimal(10), .g),
                    ])
            ],
            yield: .servings(4), createdAt: now)
        try RecipeLogger.logPortion(
            store: store, version: version, portion: 1, now: now, id: UUID().uuidString.lowercased(),
            timeZoneIdentifier: "UTC", meal: nil)

        let model = TodayViewModel(
            store: store, lookup: SnapshotNutrientFacts(), timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.title, "Oat bake")
        for line in model.coverage {
            XCTAssertEqual(line.text, "0 of 1 foods lack \(line.nutrient)", line.text)
        }
    }

    /// An entry typed by hand has no snapshot, so its nutrients stay unknown rather than becoming zero.
    func testSnapshotLookupLeavesAnEntryWithoutASnapshotUnknown() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Banana", id: "banana", at: now)
        let model = TodayViewModel(
            store: store, lookup: SnapshotNutrientFacts(), trackedNutrients: ["potassium"],
            timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.coverage.first?.text, "1 of 1 foods lack potassium")
    }

    func testKnownZeroIsKnownNotMissingAndNotApplicableIsLeftOut() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Salt free", id: "zero", at: now)
        _ = try addFood(store, name: "Plain water gel", id: "na", at: now)
        let facts = FixedFacts(values: ["zero": .known(Decimal(0), .mg), "na": .notApplicable])
        let model = TodayViewModel(store: store, lookup: facts, trackedNutrients: ["sodium"], timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.coverage.first?.missing, 0)
        XCTAssertEqual(model.coverage.first?.total, 1)
        XCTAssertEqual(model.coverage.first?.text, "0 of 1 foods lack sodium")
    }

    /// A supplement is left out of the count of the day's foods, on both sides of it: a multivitamin
    /// states no fibre and no potassium because that is what a supplement is, and counting it would tell
    /// the reader their day is short of nutrients nobody was ever going to get from it. Its totals still
    /// count, so what it does state is not thrown away.
    func testASupplementIsLeftOutOfCoverageButStillCountsTowardTotals() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Oats", id: "oats", at: now)
        _ = try addSupplement(
            store, name: "Sample daily multi", id: "multi", at: now,
            nutrients: ["potassium": .known(Decimal(50), .mg)])
        let facts = FixedFacts(
            values: ["oats": .known(Decimal(250), .mg)], missingNutrients: ["fiber", "fibre"])

        let model = TodayViewModel(
            store: store, lookup: facts, trackedNutrients: ["potassium", "fiber"], timeZoneIdentifier: "UTC")
        model.load(now: now)

        XCTAssertEqual(model.coverage.map(\.text), ["0 of 1 foods lack potassium", "1 of 1 foods lack fiber"])
        // Being left out of the count of foods is not being left out of the day: the totals still add up
        // what the day did state, and what the supplement did not state stays unknown, not a zero.
        XCTAssertEqual(
            model.progress.first { $0.nutrient == "potassium" }?.amount, .known(Decimal(300), .mg))
        XCTAssertEqual(
            model.progress.first { $0.nutrient == "fiber" }?.amount, .unknown,
            "nothing in the day stated fibre, and the supplement did not make that a zero")
    }

    /// A day holding nothing but supplements has no food in it to report coverage about, and "0 of 0
    /// foods lack fibre" says nothing about anybody's day, so no line is published for it.
    func testADayOfOnlySupplementsPublishesNoCoverageLine() throws {
        let store = try makeStore()
        _ = try addSupplement(store, name: "Sample daily multi", id: "multi", at: now)
        let model = TodayViewModel(
            store: store, trackedNutrients: ["potassium", "fiber"], timeZoneIdentifier: "UTC")

        model.load(now: now)

        XCTAssertTrue(model.coverage.isEmpty)
        XCTAssertEqual(model.rows.first?.kind, .supplement, "the entry is still listed, and says what it is")
    }

    /// An entry with no product snapshot has no kind to state, and is counted as the food it was always
    /// recorded as — otherwise adding a supplement would quietly shorten the day for everybody else.
    func testAnEntryWithoutASnapshotIsCountedAsAFood() throws {
        let store = try makeStore()
        _ = try addFood(store, name: "Oats", id: "oats", at: now)
        _ = try addFood(store, name: "Banana", id: "banana", at: now)

        let model = TodayViewModel(
            store: store, trackedNutrients: ["potassium"], timeZoneIdentifier: "UTC")
        model.load(now: now)

        XCTAssertEqual(model.coverage.first?.text, "2 of 2 foods lack potassium")
    }

    func testDeletedIntakesAreHidden() throws {
        let store = try makeStore()
        let id = try addFood(store, name: "Gone", id: "gone", at: now)
        _ = try addFood(store, name: "Kept", id: "kept", at: now)
        try store.delete(intakeID: id, now: now)
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.rows.map(\.title), ["Kept"])
        XCTAssertEqual(model.coverage.first?.total, 1)
    }

    func testCoverageLineMakeDirect() {
        let line = CoverageLine.make(nutrient: "fiber", values: [.unknown, .known(Decimal(1), .g), .belowReportingThreshold(.g)])
        XCTAssertEqual(line.text, "1 of 3 foods lack fiber")
        XCTAssertFalse(line.isComplete)
    }
}
