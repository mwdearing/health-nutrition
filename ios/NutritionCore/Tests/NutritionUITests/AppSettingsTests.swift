import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeConnections(preferences: InMemoryDisplayPreferences = InMemoryDisplayPreferences()) throws -> ConnectionsPrivacyViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ConnectionsPrivacyViewModel(
            store: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            preferences: preferences)
    }

    func testSettingsGoalCountTracksZeroAndTwoGoals() throws {
        let goals = GoalsViewModel(store: InMemoryGoalStore())
        let model = AppSettingsViewModel(connections: try makeConnections(), goals: goals)
        model.load()
        XCTAssertEqual(model.goalsSetText, "None set")
        XCTAssertTrue(goals.setTarget("60", for: "protein"))
        XCTAssertTrue(goals.setTarget("2000", for: "water"))
        XCTAssertEqual(model.goalsSetText, "2 set")
    }

    func testQuickWaterSavesOnCommitAndRejectsInvalidText() throws {
        let preferences = InMemoryDisplayPreferences()
        let model = AppSettingsViewModel(connections: try makeConnections(preferences: preferences))
        XCTAssertEqual(model.quickWaterHelper, "= 8.45 fl oz")
        model.quickWaterText = "300"
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(250))
        XCTAssertTrue(model.commitQuickWater())
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(300))
        model.quickWaterText = "abc"
        XCTAssertFalse(model.commitQuickWater())
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(300))
        XCTAssertEqual(model.quickWaterError, ConnectionsPrivacyViewModel.quickWaterInvalidMessage)
        model.unitSystem = .usCustomary
        XCTAssertEqual(preferences.unitSystem, .usCustomary)
    }

    func testPlaceholderRowsAreDisabledWithIssueReferences() throws {
        let model = AppSettingsViewModel(connections: try makeConnections())
        XCTAssertEqual(model.placeholderRows.count, 5)
        for row in model.placeholderRows {
            XCTAssertFalse(row.isEnabled)
            XCTAssertFalse(row.issueReference.isEmpty)
        }
    }

    func testSettingsVersionUsesInjectedBundleValues() throws {
        let model = AppSettingsViewModel(
            connections: try makeConnections(), version: "0.1.0", build: "107")
        XCTAssertEqual(model.versionText, "0.1.0 (107)")
    }
}
