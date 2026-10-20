import Foundation
import NutritionJournal
import XCTest

@testable import NutritionUI

/// Burned in the calorie summary counts only when the person has switched on adding active energy to the goal.
@MainActor
final class CalorieSummaryBurnedSettingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testBurnedIsHiddenWhileTheSettingIsOff() throws {
        let preferences = InMemoryDisplayPreferences()
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC", preferences: preferences)
        model.activeEnergyKcal = 120
        model.load(now: now)
        XCTAssertNil(model.calorieRemaining.burned)
    }

    func testBurnedShowsOnceTheSettingIsOn() throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setAddsActiveEnergyToGoal(true)
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC", preferences: preferences)
        model.activeEnergyKcal = 120
        model.load(now: now)
        XCTAssertEqual(model.calorieRemaining.burned, 120)
    }
}
