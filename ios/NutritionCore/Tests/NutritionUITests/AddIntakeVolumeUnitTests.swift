import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Cups, tablespoons and teaspoons in Add intake. They are typed as input and never stored: a volume
/// becomes milliliters, or grams from a typical density when the food is one the catalog names and the
/// label is by mass or absent.
@MainActor
final class AddIntakeVolumeUnitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeModel(_ store: SwiftDataJournalStore, system: UnitSystem = .usCustomary) -> AddIntakeViewModel {
        AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC",
            preferences: InMemoryDisplayPreferences(unitSystem: system))
    }

    /// Saves the form and returns the one component it stored.
    private func save(_ model: AddIntakeViewModel, in store: SwiftDataJournalStore) throws -> IntakeComponent {
        XCTAssertTrue(model.save(now: now))
        let intake = try XCTUnwrap(try store.activeIntakes().first)
        return try XCTUnwrap(try store.revisions(of: intake.id).first?.components.first)
    }

    func testOneCupOfAnUnknownFoodIsSavedAsExactMilliliters() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.name = "Example soup"
        model.amountText = "1"
        model.unit = .cup

        let component = try save(model, in: store)
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(component.amount, decimal("236.5882365"))
    }

    /// The catalog gives 120 g a cup for all-purpose flour, so two cups are 240 g, and the form says so
    /// with the one sentence and the attribution the catalog requires.
    func testTwoCupsOfAllPurposeFlourAreSavedAsCatalogGrams() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.name = "All-Purpose Flour"
        model.amountText = "2"
        model.unit = .cup

        XCTAssertEqual(model.volumeToMass?.grams, decimal("240"))
        XCTAssertEqual(model.volumeToMass?.ingredientName, "All-Purpose Flour")
        XCTAssertEqual(model.densityNote, "About 240 g, using a typical density for All-Purpose Flour.")
        XCTAssertNil(model.densityUnavailableNote)

        let component = try save(model, in: store)
        XCTAssertEqual(component.unit, .g)
        XCTAssertEqual(component.amount, decimal("240"))
    }

    /// Honey is 340 g a cup, so one tablespoon is 21.25 g and one teaspoon is 7.083333 g to six digits.
    func testHoneyByTheTablespoonAndTheTeaspoonUsesTheCatalogDensity() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.name = "Honey"
        model.amountText = "1"
        model.unit = .tablespoon
        XCTAssertEqual(try save(model, in: store).amount, decimal("21.25"))

        let teaspoonStore = try makeStore()
        let teaspoon = makeModel(teaspoonStore)
        teaspoon.name = "Honey"
        teaspoon.amountText = "1"
        teaspoon.unit = .teaspoon
        let component = try save(teaspoon, in: teaspoonStore)
        XCTAssertEqual(component.unit, .g)
        XCTAssertEqual(component.amount, decimal("7.083333"))
    }

    /// "Walnuts" names two rows and "Example soup" names none, so neither is guessed at: the volume is
    /// kept in milliliters and the form says no typical density is known.
    func testAnAmbiguousOrUnknownNameWithACupIsSavedInMilliliters() throws {
        let note = "No typical density is known for this food, so it is saved in mL."
        for name in ["Walnuts", "Example soup"] {
            let store = try makeStore()
            let model = makeModel(store)
            model.name = name
            model.amountText = "1"
            model.unit = .cup
            XCTAssertNil(model.volumeToMass, name)
            XCTAssertNil(model.densityNote, name)
            XCTAssertEqual(model.densityUnavailableNote, note, name)

            let component = try save(model, in: store)
            XCTAssertEqual(component.unit, .mL, name)
            XCTAssertEqual(component.amount, decimal("236.5882365"), name)
        }
    }

    /// A product whose label is per 100 mL is a volume, so it is never turned into grams by a density,
    /// whatever its name says.
    func testALookedUpVolumeLabelStaysInMilliliters() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.applyLabelProduct(ProductDefinition(
            snapshotID: "example-honey-volume", productID: "example-honey", name: "Honey",
            labelBasis: "per 100 mL", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(1, .g)]))
        model.name = "Honey"
        model.amountText = "1"
        model.unit = .cup

        XCTAssertNil(model.volumeToMass)
        XCTAssertNil(model.densityNote)
        XCTAssertNil(model.densityUnavailableNote)
        let component = try save(model, in: store)
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(component.amount, decimal("236.5882365"))
    }

    /// A product labelled by mass is converted with the same catalog density a typed food uses.
    func testALookedUpMassLabelUsesTheCatalogDensity() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.applyLabelProduct(ProductDefinition(
            snapshotID: "example-honey-mass", productID: "example-honey", name: "Honey",
            labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(1, .g)]))
        model.name = "Honey"
        model.amountText = "1"
        model.unit = .tablespoon

        let component = try save(model, in: store)
        XCTAssertEqual(component.unit, .g)
        XCTAssertEqual(component.amount, decimal("21.25"))
    }

    /// The preview and the saved entry use the same grams, so a product the form scales by its label
    /// shows 24 g of protein for two cups of a flour that states 10 g per 100 g.
    func testThePreviewScalesByTheSameGramsThatAreSaved() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.applyLabelProduct(ProductDefinition(
            snapshotID: "example-flour", productID: "example-flour", name: "All-Purpose Flour",
            labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(10, .g)]))
        model.name = "All-Purpose Flour"
        model.amountText = "2"
        model.unit = .cup

        XCTAssertEqual(model.thisAdds.first { $0.key == "protein" }?.value, .known(24, .g))
        let component = try save(model, in: store)
        XCTAssertEqual(component.amount, decimal("240"))
    }

    /// The US picker puts its customary units first, with the three typed measures after the two
    /// ounces; metric offers the whole registry, which includes them.
    func testThePickerOffersTheVolumeMeasuresUnderUSAndMetric() throws {
        let store = try makeStore()
        let us = makeModel(store, system: .usCustomary)
        XCTAssertEqual(Array(us.units.prefix(5)), [.oz, .flOz, .cup, .tablespoon, .teaspoon])

        let metric = makeModel(store, system: .metric)
        XCTAssertEqual(Set(metric.units), Set(UnitRegistry.all))
        XCTAssertTrue(metric.units.contains(.cup))
        XCTAssertTrue(metric.units.contains(.tablespoon))
        XCTAssertTrue(metric.units.contains(.teaspoon))
    }

    /// The recipe editor and the goals screen exclude the typed measures as they exclude the ounces:
    /// water keeps fl oz, and nothing else in its menu is a typed measure.
    func testTheRecipeEditorAndGoalsOfferNoTypedVolumeMeasures() throws {
        let typed = ["cup", "tbsp", "tsp"]
        for symbol in typed {
            XCTAssertFalse(RecipeEditorViewModel.unitSymbols.contains(symbol), symbol)
        }
        for system in [UnitSystem.usCustomary, .metric] {
            let goals = GoalsViewModel(
                store: InMemoryGoalStore(), preferences: InMemoryDisplayPreferences(unitSystem: system))
            let water = goals.units(for: "water")
            XCTAssertTrue(water.contains(.flOz), String(describing: system))
            XCTAssertTrue(water.allSatisfy { $0.dimension == .volume }, String(describing: system))
            XCTAssertFalse(water.contains(.cup), String(describing: system))
            XCTAssertFalse(water.contains(.tablespoon), String(describing: system))
            XCTAssertFalse(water.contains(.teaspoon), String(describing: system))
        }
    }

    /// Spelled out for a screen reader, as the other volumes are, and never as a symbol.
    func testAmountDisplayNamesTheTypedMeasuresInWords() {
        XCTAssertEqual(AmountDisplay.spokenName(for: .cup), "cups")
        XCTAssertEqual(AmountDisplay.spokenName(for: .tablespoon), "tablespoons")
        XCTAssertEqual(AmountDisplay.spokenName(for: .teaspoon), "teaspoons")
    }

    /// Whatever unit and food are typed, nothing is stored in a typed measure: the component is grams or
    /// milliliters, the two units the journal, export and relay know.
    func testASavedEntryIsNeverStoredInATypedMeasure() throws {
        for unit in [MeasureUnit.cup, .tablespoon, .teaspoon] {
            for name in ["All-Purpose Flour", "Honey", "Walnuts", "Example soup"] {
                let store = try makeStore()
                let model = makeModel(store)
                model.name = name
                model.amountText = "2"
                model.unit = unit
                let component = try save(model, in: store)
                XCTAssertTrue([MeasureUnit.g, .mL].contains(component.unit), "\(name) \(unit.symbol)")
            }
        }
    }
}
