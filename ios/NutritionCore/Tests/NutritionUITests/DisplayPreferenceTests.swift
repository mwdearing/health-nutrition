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
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?
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
        // amount the button writes. Below ten ounces the converted figure carries two fraction digits,
        // so 250 mL reads as 8.45 fl oz rather than 8.5.
        XCTAssertEqual(model.quickWaterLabel, "Add 8.45 fl oz water")
        XCTAssertEqual(model.quickWaterAccessibilityLabel, "Add 8.45 fluid ounces of water")

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

/// How a stored amount is read under a unit system.
final class AmountDisplayPreferenceTests: XCTestCase {
    private func text(_ amount: Decimal, _ unit: MeasureUnit, _ system: UnitSystem) -> String {
        AmountDisplay.display(amount, unit: unit, system: system).text
    }

    /// Metric shows what is stored, so a small amount is not scaled away into a different unit: 10 mg
    /// reads "10 mg", never a fraction of a gram.
    func testMetricShowsTheStoredUnitUnchangedForEveryUnit() {
        XCTAssertEqual(text(Decimal(10), .mg, .metric), "10 mg")
        XCTAssertEqual(text(Decimal(10), .mcg, .metric), "10 mcg")
        XCTAssertEqual(text(Decimal(0.5), .g, .metric), "0.5 g")
        XCTAssertEqual(text(Decimal(40), .kcal, .metric), "40 kcal")
        XCTAssertEqual(text(Decimal(2), .serving, .metric), "2 serving")
        XCTAssertEqual(text(Decimal(400), .iu, .metric), "400 IU")
        for unit in UnitRegistry.all {
            XCTAssertEqual(AmountDisplay.displayUnit(for: unit, system: .metric), unit, unit.symbol)
        }
    }

    /// US customary converts only the base-scale mass and volume units, and leaves milligrams and
    /// micrograms alone: nobody measures a kitchen ingredient in thousandths of an ounce.
    func testUSCustomaryConvertsOnlyBaseScaleMassAndVolume() {
        XCTAssertEqual(text(Decimal(500), .g, .usCustomary), "17.6 oz")
        XCTAssertEqual(text(Decimal(1), .kg, .usCustomary), "35.3 oz")
        XCTAssertEqual(text(Decimal(300), .mL, .usCustomary), "10.1 fl oz")
        XCTAssertEqual(text(Decimal(2), .L, .usCustomary), "67.6 fl oz")
        XCTAssertEqual(text(Decimal(10), .mg, .usCustomary), "10 mg")
        XCTAssertEqual(text(Decimal(10), .mcg, .usCustomary), "10 mcg")
        XCTAssertEqual(text(Decimal(40), .kcal, .usCustomary), "40 kcal")
        XCTAssertEqual(text(Decimal(2), .tablet, .usCustomary), "2 tablet")
        XCTAssertEqual(text(Decimal(400), .iu, .usCustomary), "400 IU")
    }

    /// The converted figure carries enough digits to be read: one at or above ten, two above one, and
    /// enough below one that 0.5 g is not rounded away to nothing.
    func testConvertedPrecisionKeepsSmallAmountsReadable() {
        XCTAssertEqual(text(Decimal(string: "0.5")!, .g, .usCustomary), "0.0176 oz")
        XCTAssertEqual(text(Decimal(string: "0.05")!, .L, .usCustomary), "1.69 fl oz")
        // Below one the digits are enough to carry the figure: 20 g is 0.7055 oz, not 0.7 and not 0.
        XCTAssertEqual(text(Decimal(20), .g, .usCustomary), "0.7055 oz")
        XCTAssertEqual(text(Decimal(10), .g, .usCustomary), "0.3527 oz")
        XCTAssertEqual(AmountDisplay.fractionDigits(for: Decimal(17)), AmountDisplay.largeFractionDigits)
        XCTAssertEqual(AmountDisplay.fractionDigits(for: Decimal(string: "1.5")!), AmountDisplay.mediumFractionDigits)
        XCTAssertEqual(
            AmountDisplay.fractionDigits(for: Decimal(string: "0.0176")!), AmountDisplay.smallFractionDigits)
        // A figure that lands on a round number is not padded out with zeros.
        XCTAssertEqual(text(Decimal(1000), .g, .usCustomary), "35.3 oz")
    }

    /// An amount so small the shown unit cannot name it says so, rather than reading as zero.
    func testAnAmountBelowTheSmallestShownFigureIsNotShownAsZero() {
        let shown = AmountDisplay.display(Decimal(string: "0.001")!, unit: .g, system: .usCustomary)
        XCTAssertTrue(shown.isBelowSmallest)
        XCTAssertEqual(shown.text, "< 0.0001 oz")
        // A stored zero is zero, and stays zero.
        let zero = AmountDisplay.display(Decimal(0), unit: .g, system: .usCustomary)
        XCTAssertFalse(zero.isBelowSmallest)
        XCTAssertEqual(zero.text, "0 oz")
    }

    /// An amount that is not a number is shown as stored, never as a converted figure.
    func testAnUnknownAmountIsShownAsStoredAndNeverConverted() {
        XCTAssertEqual(text(Decimal.nan, .g, .usCustomary), "NaN g")
        XCTAssertEqual(AmountDisplay.display(Decimal.nan, unit: .g, system: .usCustomary).unit, .g)
    }
}

/// The entry detail line that reads an amount in the reader's unit.
@MainActor
final class EntryDetailDisplayPreferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func model(_ preferences: DisplayPreferences, amount: Decimal, unit: MeasureUnit = .g) throws
        -> EntryDetailViewModel
    {
        let store = RecordingStore(makeID: { "intake" })
        try store.create(
            Intake(id: "intake", category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: amount, unit: unit)],
            product: nil, now: now)
        let model = EntryDetailViewModel(
            store: store, intakeID: "intake", timeZoneIdentifier: "UTC", preferences: preferences)
        model.load(now: now)
        return model
    }

    /// An amount stored as unknown has no figure to convert, so the converted line is hidden rather
    /// than shown as "NaN oz".
    func testAnUnknownAmountHidesTheConvertedLine() throws {
        let model = try model(InMemoryDisplayPreferences(unitSystem: .usCustomary), amount: Decimal.nan)
        XCTAssertEqual(model.components.first?.amountText, "unknown")
        XCTAssertNil(model.convertedText(for: "oats"))
    }

    /// The converted line follows the draft in the text field, so it never sits there showing the
    /// value that was loaded while a different one is being typed.
    func testTheConvertedLineIsRecomputedFromTheDraft() throws {
        let model = try model(InMemoryDisplayPreferences(unitSystem: .usCustomary), amount: Decimal(40))
        XCTAssertEqual(model.convertedText(for: "oats"), "1.41 oz")
        model.drafts["oats"] = "500"
        XCTAssertEqual(model.convertedText(for: "oats"), "17.6 oz")
        // A draft that is not yet a number has nothing to read.
        model.drafts["oats"] = ""
        XCTAssertNil(model.convertedText(for: "oats"))
        model.drafts["oats"] = "abc"
        XCTAssertNil(model.convertedText(for: "oats"))
    }
}

/// Ounces are an input and a display unit; what is stored is metric.
@MainActor
final class AddIntakeOuncePreferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func stored(_ amountText: String, _ unit: MeasureUnit) throws -> IntakeComponent {
        let store = RecordingStore(makeID: { "intake" })
        let model = AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC", makeID: { "intake" },
            preferences: InMemoryDisplayPreferences(unitSystem: .usCustomary))
        model.name = "Rolled oats"
        model.amountText = amountText
        model.unit = unit
        XCTAssertTrue(model.save(now: now))
        return try XCTUnwrap(store.revisions(of: "intake").first?.components.first)
    }

    /// One ounce entered is stored as the exact number of grams it stands for, so storage, the export
    /// and the relay encoder never see an ounce.
    func testAnOunceEnteredInAddIntakeIsStoredAsExactGrams() throws {
        let ounces = try stored("1", .oz)
        XCTAssertEqual(ounces.unit, .g)
        XCTAssertEqual(ounces.amount, Decimal(string: "28.349523125")!)

        let quarter = try stored("0.25", .oz)
        XCTAssertEqual(quarter.unit, .g)
        XCTAssertEqual(quarter.amount, Decimal(string: "7.08738078125")!)
    }

    /// A fluid ounce entered is stored as the exact number of millilitres it stands for.
    func testAFluidOunceEnteredInAddIntakeIsStoredAsExactMillilitres() throws {
        let component = try stored("2", .flOz)
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(component.amount, Decimal(string: "59.147059125")!)
    }

    /// Every other unit is stored as entered: the conversion is only for the two ounces.
    func testMetricUnitsAreStoredUnchanged() throws {
        for (text, unit) in [("250", MeasureUnit.mL), ("40", .g), ("10", .mg), ("120", .kcal)] {
            let component = try stored(text, unit)
            XCTAssertEqual(component.unit, unit, unit.symbol)
            XCTAssertEqual(component.amount, Decimal(string: text)!, unit.symbol)
        }
    }
}

/// The quick-water amount, end to end: the stored value is what gets written and what both labels say.
@MainActor
final class QuickWaterPreferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testQuickWaterPreferenceAmountIsWhatTheButtonAddsAndSays() throws {
        let store = RecordingStore(makeID: { "unused" })
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(300))
        // The id is the model's to make, so it is given to the model; the store double only records
        // what the model wrote. Reading the id back from the store, as the Today tests do, would pin
        // nothing about the preference these tests are about.
        let model = TodayViewModel(
            store: store, timeZoneIdentifier: "UTC", makeID: { "water-1" }, preferences: preferences)

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
        let store = RecordingStore(makeID: { "unused" })
        let preferences = InMemoryDisplayPreferences(
            unitSystem: .usCustomary, quickWaterMilliliters: Decimal(300))
        let model = TodayViewModel(
            store: store, timeZoneIdentifier: "UTC", makeID: { "water-1" }, preferences: preferences)

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
        let store = RecordingStore(makeID: { "unused" })
        let preferences = InMemoryDisplayPreferences(quickWaterMilliliters: Decimal(250))
        let model = TodayViewModel(
            store: store, timeZoneIdentifier: "UTC", makeID: { "water-1" }, preferences: preferences)
        XCTAssertEqual(model.quickWaterLabel, "Add 250 mL water")

        preferences.setQuickWaterMilliliters(Decimal(500))
        XCTAssertEqual(model.quickWaterLabel, "Add 500 mL water")
        _ = model.quickAddWater(now: now)
        let component = try XCTUnwrap(store.revisions(of: "water-1").first?.components.first)
        XCTAssertEqual(component.amount, Decimal(500))
    }

    /// The spoken strings are built from the same figures as the visible ones, so a volume too small
    /// for fluid ounces is spoken as less than that rather than as a zero that is not there.
    func testQuickWaterSpokenStringsHonourTheSmallestShownBound() throws {
        let store = RecordingStore(makeID: { "unused" })
        let preferences = InMemoryDisplayPreferences(
            unitSystem: .usCustomary, quickWaterMilliliters: Decimal(string: "0.001")!)
        let model = TodayViewModel(
            store: store, timeZoneIdentifier: "UTC", makeID: { "water-1" }, preferences: preferences)

        XCTAssertEqual(model.quickWaterDisplay.text, "< 0.0001 fl oz")
        XCTAssertEqual(model.quickWaterLabel, "Add < 0.0001 fl oz water")
        XCTAssertEqual(model.quickWaterAccessibilityLabel, "Add less than 0.0001 fluid ounces of water")

        XCTAssertNotNil(model.quickAddWater(now: now))
        XCTAssertEqual(model.waterTotalDisplay.text, "< 0.0001 fl oz")
        XCTAssertEqual(model.waterAccessibilityValue, "less than 0.0001 fluid ounces today")
        // What was written is still the exact stored amount: nothing was rounded on the way in.
        let component = try XCTUnwrap(store.revisions(of: "water-1").first?.components.first)
        XCTAssertEqual(component.amount, Decimal(string: "0.001")!)
        XCTAssertEqual(component.unit, .mL)
    }

    /// A volume that reads as a number is still spoken as that number.
    func testQuickWaterSpokenStringsStillUseTheFiguresThemselves() throws {
        let store = RecordingStore(makeID: { "unused" })
        let preferences = InMemoryDisplayPreferences(
            unitSystem: .usCustomary, quickWaterMilliliters: Decimal(300))
        let model = TodayViewModel(
            store: store, timeZoneIdentifier: "UTC", makeID: { "water-1" }, preferences: preferences)

        XCTAssertEqual(model.quickWaterAccessibilityLabel, "Add 10.1 fluid ounces of water")
        XCTAssertNotNil(model.quickAddWater(now: now))
        XCTAssertEqual(model.waterAccessibilityValue, "10.1 fluid ounces today")
    }
}