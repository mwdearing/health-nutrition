import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A journal store that only has to answer what Today asks of it. Quick-add writes nothing here: the
/// amount is read back from the store after a real write in `TodayTests`.
private final class RecordingStore: JournalStore, @unchecked Sendable {
    struct Unsupported: Error {}

    var failNextSaveForTesting = false
    var intakes: [Intake] = []
    var components: [String: [IntakeComponent]] = [:]
    private let makeID: () -> String

    init(makeID: @escaping () -> String) {
        self.makeID = makeID
    }

    func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision {
        self.intakes.append(intake)
        self.components[intake.id] = components
        return IntakeRevision(
            intakeID: intake.id, number: 1, components: components, productSnapshotID: nil,
            changeReason: "created", createdAt: now)
    }

    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String, now: Date
    ) throws -> IntakeRevision { throw Unsupported() }
    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { intakes }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        guard let stored = components[intakeID] else { return [] }
        return [
            IntakeRevision(
                intakeID: intakeID, number: 1, components: stored, productSnapshotID: nil,
                changeReason: "created", createdAt: Date(timeIntervalSince1970: 0))
        ]
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { nil }
    func activeIntakesFromBackground() async throws -> [Intake] { intakes }
    func close() {}
}

/// A defaults domain of this test's own, so nothing here reads or writes `UserDefaults.standard`.
/// Every suite name is unique per test, so two tests cannot see each other's values.
private func makeSuite(_ label: String) -> UserDefaults {
    let name = "healthnutrition.tests.\(label).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        return UserDefaults(suiteName: "healthnutrition.tests.\(label).fallback.\(UUID().uuidString)")!
    }
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
final class DisplayPreferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A view model built over `preferences`, so a preference written to the store and a view model
    /// rebuilt over the same store can be compared.
    private func makeModel(_ preferences: DisplayPreferences) -> TodayViewModel {
        TodayViewModel(
            store: RecordingStore(makeID: { "intake" }), timeZoneIdentifier: "UTC",
            preferences: preferences)
    }

    // MARK: - The preference drives what is offered and what is shown

    /// A stored US customary preference reaches both surfaces: the units Add intake offers and the
    /// amount Today displays.
    func testUnitSystemPreferenceChoosesOfferedUnitsAndDisplayedAmount() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("units-customary"))
        preferences.setUnitSystem(.usCustomary)
        let model = makeModel(preferences)

        XCTAssertEqual(model.unitSystem, .usCustomary)
        XCTAssertEqual(model.quickWaterMilliliters, Decimal(250))
        // Both button strings come from the same model properties, so neither can drift from the
        // amount the button writes.
        XCTAssertEqual(model.quickWaterLabel, "Add 8.5 fl oz water")
        XCTAssertEqual(model.quickWaterAccessibilityLabel, "Add 8.5 fluid ounces of water")

        let add = AddIntakeViewModel(
            store: RecordingStore(makeID: { "intake" }), now: now, timeZoneIdentifier: "UTC",
            preferences: preferences)
        XCTAssertEqual(Array(add.units.prefix(2)), [.oz, .flOz])
        XCTAssertEqual(Set(add.units), Set(UnitRegistry.all))
    }

    /// A rebuilt view model over the same store reads the stored preference, so the setting survives
    /// leaving the screen that set it.
    func testUnitSystemPreferenceIsReadAgainByARebuiltViewModel() throws {
        let defaults = makeSuite("units-rebuild")
        let first = UserDefaultsDisplayPreferences(defaults: defaults)
        first.setUnitSystem(.usCustomary)

        let rebuilt = makeModel(UserDefaultsDisplayPreferences(defaults: defaults))
        XCTAssertEqual(rebuilt.unitSystem, .usCustomary)
        XCTAssertTrue(rebuilt.quickWaterLabel.contains("fl oz"))
    }

    /// With nothing stored, the app is metric and the quick glass is 250 mL, exactly as before.
    func testDefaultsAreMetricAndTwoHundredAndFiftyMillilitres() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("units-default"))
        XCTAssertEqual(preferences.unitSystem, .metric)
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(250))

        let model = makeModel(preferences)
        XCTAssertEqual(model.quickWaterLabel, "Add 250 mL water")
        XCTAssertEqual(model.quickWaterAccessibilityLabel, "Add 250 millilitres of water")

        let add = AddIntakeViewModel(
            store: RecordingStore(makeID: { "intake" }), now: now, timeZoneIdentifier: "UTC",
            preferences: preferences)
        XCTAssertEqual(add.units, UnitRegistry.all)
        XCTAssertEqual(Array(add.units.prefix(2)), [.g, .mg])
    }

    /// The two implementations have to behave the same way, or the app and its tests would be talking
    /// about different preferences.
    func testInMemoryAndUserDefaultsImplementationsAgree() throws {
        let stored = UserDefaultsDisplayPreferences(defaults: makeSuite("units-agree"))
        let memory = InMemoryDisplayPreferences()

        for preferences in [stored as DisplayPreferencesWriting, memory as DisplayPreferencesWriting] {
            preferences.setUnitSystem(.usCustomary)
            preferences.setQuickWaterMilliliters(Decimal(300))
            XCTAssertEqual(preferences.unitSystem, .usCustomary)
            XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(300))
            // An amount that is not above zero can never be stored, whichever implementation it is.
            preferences.setQuickWaterMilliliters(0)
            XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(300))
            preferences.setQuickWaterMilliliters(Decimal.nan)
            XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(300))
        }
    }

    /// A stored amount is written exactly, and a metric store reads back the number that was written.
    func testQuickWaterAmountIsStoredAsAnExactDecimal() throws {
        let preferences = UserDefaultsDisplayPreferences(defaults: makeSuite("units-exact"))
        preferences.setQuickWaterMilliliters(Decimal(string: "333.5")!)
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(string: "333.5")!)
    }
}

/// The quick-water amount, end to end: the stored value is what gets written and what both labels say.
@MainActor
final class QuickWaterPreferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testQuickWaterPreferenceAmountIsWhatTheButtonAddsAndSays() throws {
        let store = RecordingStore(makeID: { "water-1" })
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(300))
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC", preferences: preferences)

        XCTAssertEqual(model.quickWaterLabel, "Add 300 mL water")
        XCTAssertEqual(model.quickWaterAccessibilityLabel, "Add 300 millilitres of water")

        let handle = try XCTUnwrap(model.quickAddWater(now: now))
        XCTAssertEqual(handle.intakeID, "water-1")
        let component = try XCTUnwrap(store.revisions(of: "water-1").first?.components.first)
        XCTAssertEqual(component.amount, Decimal(300))
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(model.waterTotalMilliliters, Decimal(300))
    }

    /// Under US customary the stored amount is still millilitres and the label follows the preference.
    func testQuickWaterPreferenceUnderUSCustomarySaysFluidOuncesAndStoresMillilitres() throws {
        let store = RecordingStore(makeID: { "water-1" })
        let preferences = InMemoryDisplayPreferences(
            unitSystem: .usCustomary, quickWaterMilliliters: Decimal(300))
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC", preferences: preferences)

        XCTAssertEqual(model.quickWaterLabel, "Add 10.1 fl oz water")
        XCTAssertEqual(model.quickWaterAccessibilityLabel, "Add 10.1 fluid ounces of water")
        _ = model.quickAddWater(now: now)
        let component = try XCTUnwrap(store.revisions(of: "water-1").first?.components.first)
        // Storage and export stay metric: what is written is the configured millilitre amount.
        XCTAssertEqual(component.amount, Decimal(300))
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(model.waterTotalDisplay.text, "10.1 fl oz")
    }

    /// A preference changed after the model was built is used by the next tap, not by the next launch.
    func testQuickWaterPreferenceChangedAfterBuildIsUsedByTheNextTap() throws {
        let store = RecordingStore(makeID: { "water-1" })
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(250))
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC", preferences: preferences)
        XCTAssertEqual(model.quickWaterLabel, "Add 250 mL water")

        preferences.setQuickWaterMilliliters(Decimal(500))
        XCTAssertEqual(model.quickWaterLabel, "Add 500 mL water")
        _ = model.quickAddWater(now: now)
        let component = try XCTUnwrap(store.revisions(of: "water-1").first?.components.first)
        XCTAssertEqual(component.amount, Decimal(500))
    }
}