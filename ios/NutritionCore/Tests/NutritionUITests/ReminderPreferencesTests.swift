import Foundation
import XCTest
@testable import NutritionUI

/// A defaults domain of this test's own, removed on teardown, so nothing here touches
/// `UserDefaults.standard`. The name is unique per call.
private func makeReminderSuite(_ label: String, _ teardown: XCTestCase) -> UserDefaults {
    let name = "healthnutrition.tests.reminder.\(label).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        preconditionFailure("the test defaults suite \(name) could not be created")
    }
    defaults.removePersistentDomain(forName: name)
    teardown.addTeardownBlock {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
    return defaults
}

/// The daily reminder's stored settings: off and 20:00 until changed, under the display prefix, and
/// removed by the display reset that Erase all data runs.
final class ReminderPreferencesTests: XCTestCase {
    func testDefaultsAreOffAtTwentyHundredInDefaultsAndMemory() throws {
        let suite = makeReminderSuite("defaults", self)
        let stored = UserDefaultsDisplayPreferences(defaults: suite)
        XCTAssertFalse(stored.isReminderOn)
        XCTAssertEqual(stored.reminderTime, ReminderTime(hour: 20, minute: 0))

        let memory: ReminderPreferences = InMemoryDisplayPreferences()
        XCTAssertFalse(memory.isReminderOn)
        XCTAssertEqual(memory.reminderTime, ReminderTime(hour: 20, minute: 0))
    }

    func testReminderKeysCarryTheDisplayPrefixAndTheTimeAsText() throws {
        let suite = makeReminderSuite("keys", self)
        let preferences = UserDefaultsDisplayPreferences(defaults: suite)

        preferences.setReminderOn(true)
        preferences.setReminderTime(ReminderTime(hour: 7, minute: 5))

        XCTAssertTrue(suite.bool(forKey: "display.reminder.on"))
        XCTAssertEqual(suite.string(forKey: "display.reminder.time"), "07:05")

        let reopened = UserDefaultsDisplayPreferences(defaults: suite)
        XCTAssertTrue(reopened.isReminderOn)
        XCTAssertEqual(reopened.reminderTime, ReminderTime(hour: 7, minute: 5))
    }

    func testResetToDefaultsRemovesBothReminderKeys() throws {
        let suite = makeReminderSuite("reset", self)
        let preferences = UserDefaultsDisplayPreferences(defaults: suite)
        preferences.setReminderOn(true)
        preferences.setReminderTime(ReminderTime(hour: 7, minute: 30))

        preferences.resetToDefaults()

        let leftover = suite.dictionaryRepresentation().keys.filter { $0.hasPrefix("display.reminder") }
        XCTAssertEqual(leftover.sorted(), [])
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertEqual(preferences.reminderTime, ReminderTime(hour: 20, minute: 0))
    }

    func testInMemoryResetToDefaultsClearsTheReminder() throws {
        let memory = InMemoryDisplayPreferences()
        memory.setReminderOn(true)
        memory.setReminderTime(ReminderTime(hour: 7, minute: 30))

        memory.resetToDefaults()

        XCTAssertFalse(memory.isReminderOn)
        XCTAssertEqual(memory.reminderTime, ReminderTime(hour: 20, minute: 0))
    }

    func testReminderTimeClampsToTheClockRange() throws {
        XCTAssertEqual(ReminderTime(hour: 25, minute: 75), ReminderTime(hour: 23, minute: 59))
        XCTAssertEqual(ReminderTime(hour: -3, minute: -1), ReminderTime(hour: 0, minute: 0))
        XCTAssertEqual(ReminderTime(hour: 23, minute: 59), ReminderTime(hour: 23, minute: 59))
        XCTAssertEqual(ReminderTime.standard, ReminderTime(hour: 20, minute: 0))
    }
}
