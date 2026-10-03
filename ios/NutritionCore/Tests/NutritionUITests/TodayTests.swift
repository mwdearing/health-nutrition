import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

private struct FixedFacts: NutrientFactsLookup {
    let values: [String: NutrientValue]
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        values[component.componentID] ?? .unknown
    }
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

    func testQuickAddWaterCreatesOneIntakeAtRevisionOneAndQueuesOutbox() throws {
        let store = try makeStore()
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        let handle = model.quickAddWater(now: now)
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.count, 1)
        XCTAssertEqual(intakes.first?.currentRevision, 1)
        XCTAssertEqual(intakes.first?.category, "water")
        XCTAssertEqual(handle?.intakeID, intakes.first?.id)
        let revisions = try store.revisions(of: intakes[0].id)
        XCTAssertEqual(revisions.first?.components.first?.amount, Decimal(250))
        XCTAssertEqual(revisions.first?.components.first?.unit, .mL)
        XCTAssertFalse(try store.pendingOutbox().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().allSatisfy { $0.kind == .upsert })
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(250))
    }

    func testQuickAddWaterUsesGivenAmountOnce() throws {
        let store = try makeStore()
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.quickAddWater(milliliters: Decimal(string: "330.5")!, now: now)
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(string: "330.5")!)
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
        for text in ["", "abc", "0", "-3", "1,5", "1e3", "1.2.3", "12g", "."] {
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
        XCTAssertEqual(model.coverage.map(\.nutrient), ["potassium", "sodium", "protein", "fiber"])
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
