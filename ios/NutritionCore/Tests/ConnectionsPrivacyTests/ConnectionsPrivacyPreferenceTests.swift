import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The **Units** section of the Connections and privacy screen: a unit-system picker and a quick-water
/// amount field, both writing through to the same preference store the other screens read.
@MainActor
final class ConnectionsPrivacyPreferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_705_313_700)

    /// A defaults domain of this test's own. The name is unique per test, so nothing here touches
    /// `UserDefaults.standard` and no two tests can see each other's values.
    private func makeSuite(_ label: String) -> UserDefaults {
        let name = "healthnutrition.tests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)
        defaults?.removePersistentDomain(forName: name)
        addTeardownBlock { defaults?.removePersistentDomain(forName: name) }
        return defaults!
    }

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// The picker starts on what is stored, offers both systems, and a change is written through at
    /// once rather than when the screen goes away.
    func testUnitSystemPreferenceIsOfferedAndWrittenThroughOnChange() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("unit-system"))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)

        XCTAssertEqual(model.unitSystem, .metric)
        XCTAssertEqual(model.unitSystems, [.metric, .usCustomary])
        XCTAssertEqual(model.unitSystems.map(ConnectionsPrivacyViewModel.label(for:)), ["Metric (g, mL)", "US customary (oz, fl oz)"])

        model.unitSystem = .usCustomary
        XCTAssertEqual(preferences.unitSystem, .usCustomary)
        // A second screen built over the same store sees it immediately.
        let second = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)
        XCTAssertEqual(second.unitSystem, .usCustomary)
    }

    /// A valid amount is stored exactly and the error is cleared; an amount above zero is all it takes.
    func testQuickWaterPreferenceAcceptsAnAmountAboveZeroAndClearsTheError() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("quick-water"))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)
        XCTAssertEqual(model.quickWaterText, "250")

        model.quickWaterText = "400.5"
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertNil(model.quickWaterError)
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(string: "400.5")!)
        XCTAssertEqual(model.quickWaterText, "400.5")

        model.quickWaterText = "600"
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertEqual(model.quickWaterMilliliters, Decimal(600))
    }

    /// An amount that is not above zero, or is not a number at all, is refused with a message and
    /// leaves the stored value alone.
    func testQuickWaterPreferenceRefusesAnAmountThatIsNotAboveZero() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("quick-water-bad"))
        preferences.setQuickWaterMilliliters(Decimal(300))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)

        for text in ["", "0", "-5", "abc", "1,5", "1e3", "12mL", "."] {
            model.quickWaterText = text
            XCTAssertFalse(model.saveQuickWaterAmount(), text)
            XCTAssertEqual(model.quickWaterError, ConnectionsPrivacyViewModel.quickWaterInvalidMessage, text)
            XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(300), text)
        }
    }

    /// The amount shown on the settings screen follows the unit system, so a US reader sees what the
    /// Today button will say.
    func testQuickWaterPreferenceIsShownInTheChosenUnitSystem() throws {
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(300))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)
        XCTAssertEqual(model.quickWaterDisplay.text, "300 mL")

        model.unitSystem = .usCustomary
        XCTAssertEqual(model.quickWaterDisplay.text, "10.1 fl oz")
    }

    /// A stored preference is read back into the screen, so reopening it shows what was saved.
    func testStoredQuickWaterPreferenceIsReadBackIntoTheScreen() throws {
        let defaults = makeSuite("quick-water-reload")
        let first = UserDefaultsDisplayPreferences(defaults: defaults)
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: first)
        model.quickWaterText = "750"
        XCTAssertTrue(model.saveQuickWaterAmount())

        let reopened = ConnectionsPrivacyViewModel(
            store: try makeStore(), preferences: UserDefaultsDisplayPreferences(defaults: defaults))
        XCTAssertEqual(reopened.quickWaterText, "750")
        XCTAssertEqual(reopened.quickWaterMilliliters, Decimal(750))
    }

    /// With nothing injected, the screen still works: an in-memory preference holds the defaults.
    func testTheScreenWorksWithoutAPreferencesStore() throws {
        let model = ConnectionsPrivacyViewModel(store: try makeStore())
        XCTAssertEqual(model.unitSystem, .metric)
        XCTAssertEqual(model.quickWaterText, "250")
        model.quickWaterText = "350"
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertEqual(model.quickWaterMilliliters, Decimal(350))
    }

    /// Erase all data promises to remove everything this app stores on the device, and a unit system
    /// and a glass size are stored values like any other: both keys are removed from the defaults
    /// domain, not overwritten, and the screen is put back to what a fresh install shows.
    func testEraseAllDataRemovesTheStoredUnitPreferencesAndResetsTheScreen() throws {
        let defaults = makeSuite("erase-units")
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)
        let store = try makeStore()
        let model = ConnectionsPrivacyViewModel(store: store, erasers: [store], preferences: preferences)
        model.unitSystem = .usCustomary
        model.quickWaterText = "600"
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertEqual(preferences.unitSystem, .usCustomary)
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(600))

        XCTAssertTrue(model.eraseAllData())

        // The keys themselves are gone, so nothing of this app's is left in the domain.
        let unitKey = UserDefaultsDisplayPreferences.keyPrefix + "unitSystem"
        let waterKey = UserDefaultsDisplayPreferences.keyPrefix + "quickWaterMilliliters"
        XCTAssertNil(defaults.object(forKey: unitKey))
        XCTAssertNil(defaults.object(forKey: waterKey))
        XCTAssertEqual(preferences.unitSystem, DisplayPreferenceDefaults.unitSystem)
        XCTAssertEqual(preferences.quickWaterMilliliters, DisplayPreferenceDefaults.quickWaterMilliliters)
        // The screen shows the defaults rather than the settings that were just erased.
        XCTAssertEqual(model.unitSystem, .metric)
        XCTAssertEqual(model.quickWaterText, "250")
        XCTAssertNil(model.quickWaterError)
        // A screen built after the erase reads the same defaults, not the erased settings.
        let reopened = ConnectionsPrivacyViewModel(
            store: store, erasers: [store], preferences: UserDefaultsDisplayPreferences(defaults: defaults))
        XCTAssertEqual(reopened.unitSystem, .metric)
        XCTAssertEqual(reopened.quickWaterText, "250")
    }

    /// The in-memory implementation clears the same way, so the two cannot disagree about what an
    /// erase leaves behind.
    func testEraseAllDataClearsTheInMemoryPreferencesToo() throws {
        let preferences = InMemoryDisplayPreferences(
            unitSystem: .usCustomary, quickWaterMilliliters: Decimal(600))
        let store = try makeStore()
        let model = ConnectionsPrivacyViewModel(store: store, erasers: [store], preferences: preferences)
        model.quickWaterText = "750"
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(750))

        XCTAssertTrue(model.eraseAllData())

        XCTAssertEqual(preferences.unitSystem, DisplayPreferenceDefaults.unitSystem)
        XCTAssertEqual(preferences.quickWaterMilliliters, DisplayPreferenceDefaults.quickWaterMilliliters)
        XCTAssertEqual(model.unitSystem, .metric)
        XCTAssertEqual(model.quickWaterText, "250")
    }
}