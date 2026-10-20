import Foundation
import NutritionUI
import XCTest

/// The app reloads Today from the activity card only when a figure Today reads has changed.
@MainActor
final class TodayReloadGuardTests: XCTestCase {
    func testAnOutsideIntakeChangeAloneReloadsToday() {
        let readings = BodyActivityReadings(outsideNutrients: ["energy": 620], outsideRead: true, outsideReadKeys: ["energy"])
        XCTAssertTrue(TodayViewModel.needsReload(activeEnergyKcal: nil, outsideIntake: .notConnected, for: readings))
    }

    func testAnActiveEnergyChangeAloneReloadsToday() {
        let readings = BodyActivityReadings(activeEnergyKcal: 116)
        XCTAssertTrue(TodayViewModel.needsReload(activeEnergyKcal: nil, outsideIntake: .notConnected, for: readings))
    }

    func testUnchangedReadingsDoNotReloadToday() {
        let readings = BodyActivityReadings(activeEnergyKcal: 116, outsideNutrients: ["energy": 620], outsideRead: true, outsideReadKeys: ["energy"])
        let current = readings.outsideIntake
        XCTAssertFalse(TodayViewModel.needsReload(activeEnergyKcal: 116, outsideIntake: current, for: readings))
    }

    func testAChangeOnlyInWhichKeysWereReadReloadsToday() {
        // Same values, but the nutrient is now read: a known zero is not the same as unknown, so Today must reload.
        let readings = BodyActivityReadings(outsideNutrients: [:], outsideRead: true, outsideReadKeys: ["energy"])
        XCTAssertTrue(TodayViewModel.needsReload(activeEnergyKcal: nil, outsideIntake: .read(values: [:], readKeys: []), for: readings))
    }

    func testNoHealthReadAndNoEnergyChangeDoesNotReloadToday() {
        let readings = BodyActivityReadings()
        XCTAssertFalse(TodayViewModel.needsReload(activeEnergyKcal: nil, outsideIntake: .notConnected, for: readings))
    }

    func testAHealthDisconnectWhileTodayHoldsHealthReloadsToday() {
        // Health stopped being read (not connected now), while Today still holds a Health side: Today must reload.
        let readings = BodyActivityReadings()
        XCTAssertTrue(TodayViewModel.needsReload(
            activeEnergyKcal: nil, outsideIntake: .read(values: ["energy": 620], readKeys: ["energy"]), for: readings))
    }
}
