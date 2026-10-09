import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Logging a water amount typed in the "Other amount" row of the water card.
@MainActor
final class TodayOtherWaterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeModel(
        _ store: SwiftDataJournalStore, system: UnitSystem = .metric
    ) -> TodayViewModel {
        let preferences = InMemoryDisplayPreferences(unitSystem: system, quickWaterMilliliters: Decimal(250))
        return TodayViewModel(store: store, timeZoneIdentifier: "UTC", preferences: preferences)
    }

    func testOtherWaterMetricLogsTheTypedMillilitres() throws {
        let store = try makeStore()
        let model = makeModel(store, system: .metric)
        let handle = model.addWater(typed: "400", now: now)
        XCTAssertNotNil(handle)
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.count, 1)
        XCTAssertEqual(intakes.first?.category, "water")
        XCTAssertEqual(handle?.intakeID, intakes.first?.id)
        let component = try XCTUnwrap(try store.revisions(of: intakes[0].id).first?.components.first)
        XCTAssertEqual(component.amount, Decimal(400))
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(400))
        XCTAssertNil(model.errorMessage)
    }

    func testOtherWaterUsConvertsFluidOuncesExactly() throws {
        let store = try makeStore()
        let model = makeModel(store, system: .usCustomary)
        let handle = model.addWater(typed: "12", now: now)
        XCTAssertNotNil(handle)
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.count, 1)
        let component = try XCTUnwrap(try store.revisions(of: intakes[0].id).first?.components.first)
        // 12 fl oz at the exact factor of 29.5735295625 mL per fl oz is 354.88235475 mL, stored as millilitres.
        XCTAssertEqual(component.amount, Decimal(string: "354.88235475")!)
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(component.amount, Decimal(12) * Decimal(string: "29.5735295625")!)
    }

    func testOtherWaterReadsATypedComma() throws {
        // addWater reads the region's separator, so the end-to-end expectation follows the region the
        // tests run in, the same rule the parser's own comma tests state with an explicit separator.
        XCTAssertEqual(AmountParser.parseTyped("2,5", decimalSeparator: ","), Decimal(string: "2.5"))
        XCTAssertNil(AmountParser.parseTyped("2,5", decimalSeparator: "."))

        let store = try makeStore()
        let model = makeModel(store, system: .metric)
        let handle = model.addWater(typed: "2,5", now: now)
        if AmountParser.parseTyped("2,5") != nil {
            XCTAssertNotNil(handle)
            let intakes = try store.activeIntakes()
            XCTAssertEqual(intakes.count, 1)
            let component = try XCTUnwrap(try store.revisions(of: intakes[0].id).first?.components.first)
            XCTAssertEqual(component.amount, Decimal(string: "2.5")!)
        } else {
            XCTAssertNil(handle)
            XCTAssertTrue(try store.activeIntakes().isEmpty)
            XCTAssertEqual(model.errorMessage, "Enter a water amount above zero.")
        }
    }

    func testOtherWaterRefusesZeroNegativeAndUnreadableText() throws {
        let store = try makeStore()
        let model = makeModel(store, system: .metric)
        for text in ["0", "0.0", "-5", "abc", "", "   ", "1.2.3"] {
            let handle = model.addWater(typed: text, now: now)
            XCTAssertNil(handle, "typed \"\(text)\"")
            XCTAssertNil(model.undo, "typed \"\(text)\"")
            XCTAssertEqual(model.errorMessage, "Enter a water amount above zero.", "typed \"\(text)\"")
            XCTAssertTrue(try store.activeIntakes().isEmpty, "typed \"\(text)\"")
            XCTAssertTrue(try store.pendingOutbox().isEmpty, "typed \"\(text)\"")
        }
        XCTAssertEqual(model.waterTotalMilliliters, 0)
    }

    func testOtherWaterCanBeUndoneLikeTheQuickButton() throws {
        let store = try makeStore()
        let model = makeModel(store, system: .metric)
        let handle = try XCTUnwrap(model.addWater(typed: "330", now: now))
        XCTAssertTrue(model.isUndoAvailable(now: now.addingTimeInterval(5)))
        XCTAssertEqual(handle.expiresAt, now.addingTimeInterval(10))
        XCTAssertTrue(model.undoLastQuickAdd(now: now.addingTimeInterval(5)))
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().contains { $0.kind == .delete && $0.intakeID == handle.intakeID })
        XCTAssertEqual(model.waterTotalMilliliters, 0)
        XCTAssertNil(model.undo)
    }

    func testOtherWaterUndoExpiresAfterTheWindow() throws {
        let store = try makeStore()
        let model = makeModel(store, system: .metric)
        _ = try XCTUnwrap(model.addWater(typed: "330", now: now))
        XCTAssertFalse(model.isUndoAvailable(now: now.addingTimeInterval(11)))
        XCTAssertFalse(model.undoLastQuickAdd(now: now.addingTimeInterval(11)))
        XCTAssertEqual(model.waterTotalMilliliters, 330)
    }

    func testOtherWaterFieldLabelNamesTheUnit() throws {
        let store = try makeStore()
        let metric = makeModel(store, system: .metric)
        XCTAssertEqual(metric.otherWaterUnitSymbol, "mL")
        XCTAssertEqual(metric.otherWaterFieldLabel, "Water amount in mL")

        let us = makeModel(store, system: .usCustomary)
        XCTAssertEqual(us.otherWaterUnitSymbol, "fl oz")
        XCTAssertEqual(us.otherWaterFieldLabel, "Water amount in fl oz")
    }
}
