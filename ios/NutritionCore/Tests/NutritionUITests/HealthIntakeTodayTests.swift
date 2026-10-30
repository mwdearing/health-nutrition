import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Today with an empty journal and nutrition from other apps in Health: the lines show Health's amounts.
@MainActor
final class HealthIntakeTodayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// No journal entries at all and every Health read complete: both show Health's exact amounts.
    func testEmptyJournalShowsHealthEnergyAndProteinExactly() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.outsideIntake = .read(
            values: ["energy": 620, "protein": 48], readKeys: ["energy", "protein"])
        model.load(now: now)

        let energy = try XCTUnwrap(model.progress.first { $0.nutrient == "energy" })
        let protein = try XCTUnwrap(model.progress.first { $0.nutrient == "protein" })
        XCTAssertEqual(energy.amount, NutrientValue.known(620, HealthKitWritePlanner.mapping(for: "energy")!.unit))
        XCTAssertEqual(protein.amount, NutrientValue.known(48, HealthKitWritePlanner.mapping(for: "protein")!.unit))
        XCTAssertFalse(energy.isPartial)
        XCTAssertFalse(protein.isPartial)
    }

    /// Health's protein read was not complete, so protein reads as at least while energy stays exact.
    func testEmptyJournalWithPartialHealthReadIsAtLeastForThatNutrientOnly() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.outsideIntake = .read(values: ["energy": 620, "protein": 48], readKeys: ["energy"])
        model.load(now: now)

        let energy = try XCTUnwrap(model.progress.first { $0.nutrient == "energy" })
        let protein = try XCTUnwrap(model.progress.first { $0.nutrient == "protein" })
        XCTAssertFalse(energy.isPartial)
        XCTAssertTrue(protein.isPartial)
        XCTAssertEqual(protein.knownSum, NutrientValue.known(48, HealthKitWritePlanner.mapping(for: "protein")!.unit))
    }

    /// Changing only the Health side and loading again changes Today's lines.
    func testChangingOnlyTheHealthSideReloadsTheLines() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.load(now: now)
        // Before the Health side changes, the energy line is present and unknown, not partial.
        XCTAssertEqual(model.progress.first { $0.nutrient == "energy" }?.amount, .unknown)
        XCTAssertEqual(model.progress.first { $0.nutrient == "energy" }?.isPartial, false)

        model.outsideIntake = .read(values: ["energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertEqual(model.progress.first { $0.nutrient == "energy" }?.amount,
                       NutrientValue.known(620, HealthKitWritePlanner.mapping(for: "energy")!.unit))
    }

    // MARK: - Water other apps logged to Health

    /// Water another app logged to Health counts toward Today's water, the way its nutrients count toward their lines.
    func testWaterFromOtherAppsInHealthCountsTowardTodaysWater() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.outsideIntake = .read(values: ["water": 500], readKeys: ["water"])
        model.load(now: now)
        XCTAssertEqual(model.waterTotalMilliliters, 500)
    }

    /// Health's water is added to what the journal logged, not put in its place.
    func testHealthWaterIsAddedToTheJournalsWater() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        XCTAssertNotNil(model.quickAddWater(milliliters: 250, now: now))
        model.outsideIntake = .read(values: ["water": 500], readKeys: ["water"])
        model.load(now: now)
        XCTAssertEqual(model.waterTotalMilliliters, 750)
    }

    /// A water read that did not complete adds nothing, so Today's water stays the journal's.
    func testAnIncompleteHealthWaterReadAddsNothing() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        XCTAssertNotNil(model.quickAddWater(milliliters: 250, now: now))
        model.outsideIntake = .read(values: ["water": 500, "energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertEqual(model.waterTotalMilliliters, 250)
    }

    /// With a water goal, the water bar shows Health's water too, so the bar and the water figure agree.
    func testTheWaterBarCountsHealthWaterLikeTheWaterFigure() throws {
        let goals = InMemoryGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "water", target: 2000, unit: .mL))
        let model = TodayViewModel(store: try makeJournal(), goals: goals, timeZoneIdentifier: "UTC")
        XCTAssertNotNil(model.quickAddWater(milliliters: 250, now: now))
        model.outsideIntake = .read(values: ["water": 500], readKeys: ["water"])
        model.load(now: now)
        let bar = try XCTUnwrap(model.waterBar)
        XCTAssertEqual(bar.state, .progress)
        XCTAssertEqual(model.progress.first { $0.nutrient == "water" }?.amount, NutrientValue.known(750, .mL))
        // The water figure and the water line each add Health's water once: 250 logged plus 500 from Health is 750
        // on both, never 1,250 (the figure adding it twice) or 1,000 (the line counting the figure again).
        XCTAssertEqual(model.waterTotalMilliliters, 750)
    }

    /// With only Health water and none logged here, the water bar shows progress, not "Nothing logged yet".
    func testTheWaterBarShowsHealthOnlyWaterAsLogged() throws {
        let goals = InMemoryGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "water", target: 2000, unit: .mL))
        let model = TodayViewModel(store: try makeJournal(), goals: goals, timeZoneIdentifier: "UTC")
        model.outsideIntake = .read(values: ["water": 500], readKeys: ["water"])
        model.load(now: now)
        let bar = try XCTUnwrap(model.waterBar)
        XCTAssertEqual(bar.state, .progress)
        XCTAssertNotEqual(bar.valueText, "Nothing logged yet")
    }
}
