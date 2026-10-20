import Foundation
import NutritionUI
import XCTest

/// The app reloads Today from the activity card only when a figure Today reads has changed.
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
}
