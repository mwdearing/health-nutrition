import Foundation
import NutritionDomain
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
        XCTAssertEqual(model.unitSystems.map(ConnectionsPrivacyViewModel.label(for:)), ["Metric (g, mL)", "US (oz, fl oz)"])

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

    /// The field is read in the preferred unit, so typing 12 under the US system means twelve fluid
    /// ounces and not twelve millilitres. What is stored stays millilitres, so the entry the Today
    /// button writes is the same water either way.
    func testQuickWaterFieldIsEnteredInThePreferredUnit() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("quick-water-us"))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)

        XCTAssertEqual(model.quickWaterUnit, .mL)
        XCTAssertEqual(model.quickWaterUnitSymbol, "mL")
        XCTAssertEqual(model.quickWaterFieldLabel, "Quick-add water amount in mL")

        model.unitSystem = .usCustomary

        XCTAssertEqual(model.quickWaterUnit, .flOz)
        XCTAssertEqual(model.quickWaterUnitSymbol, "fl oz")
        XCTAssertEqual(model.quickWaterFieldLabel, "Quick-add water amount in fl oz")

        model.quickWaterText = "12"
        XCTAssertTrue(model.saveQuickWaterAmount())
        // One fluid ounce is exactly 29.5735295625 mL, so the stored figure is exact.
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(string: "354.88235475", locale: AmountParser.locale))
        XCTAssertNil(model.quickWaterError)
        // And it reads back as the twelve fluid ounces that were typed.
        XCTAssertEqual(model.quickWaterDisplay.text, "12 fl oz")
        XCTAssertEqual(model.quickWaterText, "12")
    }

    /// The helper line says what the typed figure is in the other unit, so a glass entered in one system
    /// is never a mystery in the other. It is the conversion, not a restatement of the field.
    func testQuickWaterUnitHelperShowsTheEquivalentInTheOtherUnit() throws {
        let preferences = InMemoryDisplayPreferences(
            unitSystem: .usCustomary, quickWaterMilliliters: Decimal(354.88235475))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)

        XCTAssertEqual(model.quickWaterEquivalenceText, "= 355 mL")
        XCTAssertEqual(model.quickWaterEquivalenceAccessibilityLabel, "= 355 millilitres")

        // Under metric the same line speaks in the other system's unit.
        model.unitSystem = .metric
        XCTAssertEqual(model.quickWaterEquivalenceText, "= 12 fl oz")
    }

    /// Switching the unit system restates a typed amount rather than leaving it to be read as a
    /// different measure: the same glass, in the unit the field is now labelled in.
    func testQuickWaterUnitConversionFollowsTheUnitSystemChange() throws {
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(250))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)
        XCTAssertEqual(model.quickWaterText, "250")

        model.unitSystem = .usCustomary
        XCTAssertEqual(model.quickWaterText, "8.45")
        // Saving without touching the field stores the same glass of water, not 8.45 mL. The figure goes
        // through the digits the field can show, so what is stored is what 8.45 fl oz stands for and not
        // exactly the 250 mL it started as: 250 mL is 8.4535... fl oz, and the field carries two digits.
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertEqual(
            preferences.quickWaterMilliliters,
            Decimal(string: "249.896324803125", locale: AmountParser.locale))
        XCTAssertNotEqual(preferences.quickWaterMilliliters, Decimal(string: "8.45", locale: AmountParser.locale))
        // Close enough to the original glass to be that glass, at the precision the field shows.
        XCTAssertEqual(
            DisplayRounding.rounded(preferences.quickWaterMilliliters, fractionDigits: 0), Decimal(250))

        // And back under metric the field states that stored figure rather than the 250 it began as,
        // because the round trip went through a rounded figure and rounding is not undone by switching.
        model.unitSystem = .metric
        XCTAssertEqual(
            AmountParser.parse(model.quickWaterText), preferences.quickWaterMilliliters,
            "the field states the stored millilitres, not the 250 mL the round trip started from")
        XCTAssertNotEqual(model.quickWaterText, "250")
    }

    /// The helper line answers for the figure in the field, not for the one last saved: a glass typed
    /// in fluid ounces says what it is in millilitres straight away, before Save is tapped at all.
    /// Reading the stored value instead would leave the line describing the previous glass while the
    /// field showed a different one.
    func testQuickWaterEquivalenceFollowsTheTypedDraftBeforeItIsSaved() throws {
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(250))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)
        model.unitSystem = .usCustomary

        model.quickWaterText = "10"

        // Ten fluid ounces is 295.735295625 mL, read as whole millilitres. Nothing is stored yet.
        XCTAssertEqual(model.quickWaterEquivalenceText, "= 296 mL")
        XCTAssertEqual(model.quickWaterEquivalenceAccessibilityLabel, "= 296 millilitres")
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(250))
    }

    /// Metric shows the millilitres that are stored, so the field states them at the digits they were
    /// entered with. The ounce display's rounding belongs to a converted figure, and applying it to an
    /// unconverted one would restate 400.55 mL as 400.6 in the field the person is still editing.
    func testQuickWaterDraftKeepsTheMillilitresAsTypedUnderMetric() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("quick-water-metric"))
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)

        model.quickWaterText = "400.55"
        XCTAssertTrue(model.saveQuickWaterAmount())

        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(string: "400.55", locale: AmountParser.locale))
        XCTAssertEqual(model.quickWaterText, "400.55")
    }

    /// An amount that is not a number is left alone when the system changes: there is nothing to convert,
    /// and the field's own error is what says so.
    func testQuickWaterUnitConversionLeavesAnUnusableEntryAlone() throws {
        let preferences = InMemoryDisplayPreferences()
        let model = ConnectionsPrivacyViewModel(store: try makeStore(), preferences: preferences)

        model.quickWaterText = "abc"
        model.unitSystem = .usCustomary

        XCTAssertEqual(model.quickWaterText, "abc")
        XCTAssertEqual(model.quickWaterFieldLabel, "Quick-add water amount in fl oz")
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
        // Six hundred fluid ounces, which is what the field reads in under the US system, stored as the
        // millilitres they stand for.
        model.quickWaterText = "600"
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertEqual(preferences.unitSystem, .usCustomary)
        XCTAssertEqual(
            preferences.quickWaterMilliliters,
            Decimal(string: "17744.1177375", locale: AmountParser.locale))

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
        // The screen opens in the US system it was given, so the field reads fluid ounces and the
        // stored millilitres are what those ounces stand for.
        model.quickWaterText = "750"
        XCTAssertTrue(model.saveQuickWaterAmount())
        XCTAssertEqual(
            preferences.quickWaterMilliliters,
            Decimal(string: "22180.147171875", locale: AmountParser.locale))

        XCTAssertTrue(model.eraseAllData())

        XCTAssertEqual(preferences.unitSystem, DisplayPreferenceDefaults.unitSystem)
        XCTAssertEqual(preferences.quickWaterMilliliters, DisplayPreferenceDefaults.quickWaterMilliliters)
        XCTAssertEqual(model.unitSystem, .metric)
        XCTAssertEqual(model.quickWaterText, "250")
    }
}