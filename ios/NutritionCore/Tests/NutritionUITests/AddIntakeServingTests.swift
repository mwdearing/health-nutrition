import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeServingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeModel(countDecimalSeparator: String? = Locale.current.decimalSeparator) throws -> AddIntakeViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        return AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC", lookup: nil,
            preferences: InMemoryDisplayPreferences(unitSystem: .usCustomary),
            countDecimalSeparator: countDecimalSeparator)
    }

    /// A per-100 g product with a 2 oz serving and 200 kcal per 100 g.
    private func picked(serving: ServingDefinition?) -> LookedUpProduct {
        LookedUpProduct(
            barcode: "", name: "Rice cake", brand: nil, basis: .per100g,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(200), .kcal)],
            attribution: nil, serving: serving, version: nil)
    }

    func testPickOpensOnOneServingInTheSourceUnit() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        XCTAssertEqual(model.servingCount, "1")
        XCTAssertEqual(model.amountText, "2")
        XCTAssertEqual(model.unit, .oz)
    }

    func testServingCountSetsTheAmount() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.setServingCount("3")
        XCTAssertEqual(model.amountText, "6")
        XCTAssertEqual(model.unit, .oz)
    }

    func testTypingAnAmountClearsTheCount() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.amountText = "5"
        XCTAssertEqual(model.servingCount, "")
    }

    func testNoServingWeightLeavesTheAmountAlone() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: nil))
        XCTAssertEqual(model.amountText, "")
        XCTAssertEqual(model.servingCount, "")
    }

    func testPreviewScalesPer100GramValuesToTheAmount() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 100, unit: .g)))
        model.amountText = "50"
        model.unit = .g
        XCTAssertEqual(model.amountPreview?.kcal, Decimal(100))
        XCTAssertNil(model.amountPreview?.protein, "a nutrient the source did not give is unknown")
    }

    func testThisAddsShowsImportedValuesBeforeAnAmountExists() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: nil))
        model.amountText = ""
        let lines = model.thisAdds
        XCTAssertTrue(lines.contains { $0.key == LookedUpProduct.energyKcal && !$0.cannotScale })
        XCTAssertFalse(lines.contains { $0.cannotScale }, "an empty amount never reads as can't be worked out")
    }

    func testOunceAmountScalesThroughGrams() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        let energy = model.thisAdds.first { $0.key == LookedUpProduct.energyKcal }
        XCTAssertNotNil(energy)
        XCTAssertEqual(energy?.cannotScale, false)
    }

    /// The store accepts only a lowercase UUID as an intake id.
    private static let intakeID = "00000000-0000-4000-8000-000000000001"

    /// Saves the model's current form and returns the one stored component, read back from the store.
    private func savedComponent(
        _ configure: (AddIntakeViewModel) -> Void, system: UnitSystem = .usCustomary
    ) throws -> IntakeComponent {
        let store = try makeStore()
        let model = AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC", makeID: { Self.intakeID }, lookup: nil,
            preferences: InMemoryDisplayPreferences(unitSystem: system))
        configure(model)
        XCTAssertTrue(model.save(now: now))
        return try XCTUnwrap(store.revisions(of: Self.intakeID).first?.components.first)
    }

    func testAnOunceServingLeftAsOpenedIsStoredAsExactGrams() throws {
        let component = try savedComponent { $0.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz))) }
        XCTAssertEqual(component.unit, .g)
        XCTAssertEqual(component.amount, Decimal(string: "56.69904625")!)
    }

    func testAnOunceServingCountIsStoredAsExactGrams() throws {
        let component = try savedComponent {
            $0.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
            $0.setServingCount("3")
        }
        XCTAssertEqual(component.unit, .g)
        XCTAssertEqual(component.amount, Decimal(string: "170.09713875")!)
    }

    func testACommittedServingCountIsStoredAsGrams() throws {
        let component = try savedComponent {
            $0.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
            $0.setServingCount("3.")
            $0.commitServingCount()
        }
        XCTAssertEqual(component.unit, .g)
        XCTAssertEqual(component.amount, Decimal(string: "170.09713875")!)
    }

    /// A serving carried in grams, as the USDA search builds it, saves as exactly those grams under either system.
    func testAGramServingIsStoredAsExactlyThoseGramsUnderBothSystems() throws {
        for system in [UnitSystem.usCustomary, .metric] {
            let one = try savedComponent(
                { $0.applyLookedUp(picked(serving: ServingDefinition(quantity: 30, unit: .g))) }, system: system)
            XCTAssertEqual(one.unit, .g)
            XCTAssertEqual(one.amount, Decimal(30))
            let two = try savedComponent({
                $0.applyLookedUp(picked(serving: ServingDefinition(quantity: 30, unit: .g)))
                $0.setServingCount("2")
            }, system: system)
            XCTAssertEqual(two.unit, .g)
            XCTAssertEqual(two.amount, Decimal(60))
        }
    }

    func testAGramServingOpensRoundedInOunces() throws {
        let model = try makeModel()
        let serving = ServingDefinition(quantity: Decimal(30), unit: .g)
        model.applyLookedUp(picked(serving: serving))
        XCTAssertEqual(model.amountText, "1.06")
        XCTAssertEqual(model.unit, .oz)
        model.setServingCount("2")
        XCTAssertEqual(model.amountText, "2.12")
    }

    func testServingPreviewRowsAreRoundedLikeThisAdds() throws {
        let model = try makeModel()
        let product = LookedUpProduct(
            barcode: "", name: "Rice cake", brand: nil, basis: .per100g,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(389), .kcal)],
            attribution: nil, serving: ServingDefinition(quantity: 30, unit: .g), version: nil)
        model.applyLookedUp(product)
        let preview = try XCTUnwrap(model.amountPreview)
        let calories = AmountPreview.rowText(preview.kcal, unit: "")
        XCTAssertFalse(calories.contains("."), calories)
        XCTAssertEqual(AmountPreview.rowText(nil, unit: "g"), "Unknown")
        XCTAssertEqual(AmountPreview.rowText(Decimal(string: "12.3456789")!, unit: "g"), "12.3 g")
    }

    func testTinyPreviewFiguresReadAsABoundNotZero() {
        XCTAssertEqual(AmountPreview.rowText(Decimal(string: "0.4")!, unit: ""), "< 1")
        XCTAssertEqual(AmountPreview.rowText(Decimal(string: "0.004")!, unit: "g"), "< 0.01 g")
        XCTAssertEqual(AmountPreview.rowText(0, unit: "g"), "0 g")
    }

    /// A 1 g serving opens as "0.0353" oz; the preview still scales the exact gram, not the rounded ounces.
    func testPreviewScalesTheExactServingNotTheRoundedField() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 1, unit: .g)))
        XCTAssertEqual(model.amountText, "0.0353")
        XCTAssertEqual(model.amountPreview?.grams, Decimal(1))
        XCTAssertEqual(model.amountPreview?.kcal, Decimal(2))
        model.amountText = "0.0353"
        XCTAssertNotEqual(model.amountPreview?.grams, Decimal(1), "a typed figure is scaled as typed")
    }

    func testServingLabelRoundsAConvertedQuantityOnlyOnScreen() {
        let quotient = Decimal(30) / Decimal(string: "28.349523125")!
        let serving = ServingDefinition(quantity: quotient, unit: .oz, text: nil)
        XCTAssertEqual(serving.shownLabel, "1.06 oz")
        XCTAssertEqual(serving.label, "\(quotient) oz", "the stored label keeps the exact quantity")
    }

    /// The stored label basis names the exact serving, so one serving scales to exactly the stated values.
    func testPerServingLabelBasisKeepsTheExactServing() {
        let product = LookedUpProduct(
            barcode: "", name: "Rice cake", brand: nil, basis: .perServing,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(80), .kcal)],
            attribution: nil, serving: ServingDefinition(quantity: Decimal(string: "10.25")!, unit: .g), version: nil)
        XCTAssertEqual(product.labelBasis, "per serving (10.25 g)")
    }

    func testPerHundredGramPickOffersOnlyMassUnits() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        XCTAssertFalse(model.unitOptions.contains(.serving), "a count cannot be totalled against per 100 g")
        XCTAssertTrue(model.unitOptions.contains(.oz))
        XCTAssertTrue(model.unitOptions.contains(.g))
    }

    func testPickOpensOnOneServingInGramsUnderMetric() throws {
        let model = AddIntakeViewModel(
            store: try makeStore(), now: now, timeZoneIdentifier: "UTC", lookup: nil,
            preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        XCTAssertEqual(model.unit, .g)
        XCTAssertEqual(model.servingCount, "1")
        // Two ounces is 56.7 grams: the stored mass is the same, shown in the metric unit.
        let shown = try XCTUnwrap(AmountParser.parse(model.amountText))
        XCTAssertLessThan(abs(shown - Decimal(string: "56.7")!), Decimal(string: "0.01")!)
    }

    func testClearedAmountShowsANoticeUntilAnAmountIsTyped() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: nil))
        model.unit = .serving
        model.amountText = "2"
        model.applyLookedUp(picked(serving: nil))
        XCTAssertEqual(model.amountText, "")
        XCTAssertEqual(model.unitNotice, "Amount cleared. This food can't be measured in serving.")
        model.amountText = "abc"
        XCTAssertNotNil(model.unitNotice, "text that is not an amount does not clear the notice")
        model.amountText = "100"
        XCTAssertNil(model.unitNotice)
        model.invalidateLookup()
        XCTAssertNil(model.unitNotice)
    }

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testDraftCountsLeaveTheAmountAlone() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.setServingCount("3")
        XCTAssertEqual(model.amountText, "6")
        for draft in ["0", "0.", "0.0", ""] {
            model.setServingCount(draft)
            XCTAssertEqual(model.amountText, "6", "a draft count '\(draft)' leaves the amount alone")
        }
        model.setServingCount("0.5")
        XCTAssertEqual(model.amountText, "1")
    }

    func testCommittedZeroClearsTheAmount() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.setServingCount("0.")
        model.commitServingCount()
        XCTAssertEqual(model.amountText, "")
    }

    func testCommitKeepsAnAmountTypedWithoutTheServingsField() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.amountText = "75"
        model.commitServingCount()
        XCTAssertEqual(model.amountText, "75")
    }

    func testCommaDecimalCountIsReadAsAFraction() {
        XCTAssertEqual(AmountParser.parseTyped("0,5", decimalSeparator: ","), Decimal(string: "0.5"))
        XCTAssertNil(AmountParser.parseTyped("0,", decimalSeparator: ","))
        XCTAssertNil(AmountParser.parseTyped("0.0", decimalSeparator: ","))
    }

    func testEmptiedServingsFieldClearsTheAmountItSet() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.setServingCount("3")
        model.setServingCount("")
        model.commitServingCount()
        XCTAssertEqual(model.amountText, "")
    }

    func testTypedAmountSurvivesAnEmptiedServingsField() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.amountText = "75"
        model.setServingCount("")
        model.commitServingCount()
        XCTAssertEqual(model.amountText, "75")
    }

    func testCommaLocaleDraftCountLeavesTheAmountAlone() throws {
        let model = try makeModel(countDecimalSeparator: ",")
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.setServingCount("3")
        XCTAssertEqual(model.amountText, "6")
        model.setServingCount("0,")
        XCTAssertEqual(model.amountText, "6", "a comma-locale draft '0,' leaves the amount alone")
        model.setServingCount("0,5")
        XCTAssertEqual(model.amountText, "1")
    }

    func testCommaLocaleCommittedZeroClearsTheAmount() throws {
        let model = try makeModel(countDecimalSeparator: ",")
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.setServingCount("3")
        model.setServingCount("0,")
        model.commitServingCount()
        XCTAssertEqual(model.amountText, "")
    }

    func testCommittedTrailingPointCountSettlesTheAmount() throws {
        let model = try makeModel()
        model.applyLookedUp(picked(serving: ServingDefinition(quantity: 2, unit: .oz)))
        model.setServingCount("3")
        XCTAssertEqual(model.amountText, "6")
        model.setServingCount("1.")
        model.commitServingCount()
        XCTAssertEqual(model.amountText, "2")
    }

    private struct StubPortions: HouseholdPortionLookup {
        let grams: [MeasureUnit: Decimal]
        func listedPortions(fdcId: Int) async -> [MeasureUnit: Decimal] { grams }
    }

    private func makePortionModel(_ grams: [MeasureUnit: Decimal]) throws -> AddIntakeViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        return AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC", lookup: nil,
            preferences: InMemoryDisplayPreferences(unitSystem: .usCustomary),
            portionLookup: StubPortions(grams: grams))
    }

    /// A USDA-style pick: per 100 g, with the source's fdcId so its listed measures can be asked for.
    private func usdaPick() -> LookedUpProduct {
        LookedUpProduct(
            barcode: "", name: "Cooked rice", brand: nil, basis: .per100g,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(200), .kcal)],
            attribution: nil, serving: nil, version: nil, sourceID: "1")
    }

    func testListedCupTotalsThroughItsGramWeight() async throws {
        let model = try makePortionModel([.cup: 150])
        model.applyLookedUp(usdaPick())
        await model.loadListedPortions()
        XCTAssertTrue(model.unitOptions.contains(.cup), "a listed cup is offered")
        model.unit = .cup
        model.amountText = "1"
        let energy = model.thisAdds.first { $0.key == LookedUpProduct.energyKcal }
        // One cup is 150 g, so 200 kcal per 100 g is 300 kcal.
        XCTAssertEqual(energy?.value, .known(300, .kcal))
    }

    func testUnlistedCupIsNotOffered() async throws {
        let model = try makePortionModel([:])
        model.applyLookedUp(usdaPick())
        await model.loadListedPortions()
        XCTAssertFalse(model.unitOptions.contains(.cup), "a food that lists no cup gets no cup")
        XCTAssertFalse(model.unitOptions.contains(.teaspoon))
    }

    func testPerHundredMillilitrePickConvertsCupExactlyToMillilitres() throws {
        let model = try makePortionModel([:])
        model.applyLookedUp(LookedUpProduct(
            barcode: "", name: "Oat drink", brand: nil, basis: .per100ml,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(45), .kcal)],
            attribution: nil, serving: nil, version: nil, sourceID: nil))
        model.unit = .cup
        model.amountText = "1"
        let energy = model.thisAdds.first { $0.key == LookedUpProduct.energyKcal }
        // One US cup is 236.5882365 mL, so 45 kcal per 100 mL is about 106.4647 kcal.
        let shown = try XCTUnwrap(energy).value
        guard case .known(let kcal, _) = shown else { return XCTFail("energy should total") }
        XCTAssertLessThan(abs(kcal - Decimal(string: "106.4647")!), Decimal(string: "0.001")!)
    }

    func testFailedPortionRequestHidesMeasuresAndGramsStillLog() async throws {
        let model = try makePortionModel([:])
        model.applyLookedUp(usdaPick())
        await model.loadListedPortions()
        XCTAssertFalse(model.unitOptions.contains(.cup))
        XCTAssertFalse(model.unitOptions.contains(.tablespoon))
        model.unit = .g
        model.amountText = "100"
        let energy = model.thisAdds.first { $0.key == LookedUpProduct.energyKcal }
        XCTAssertEqual(energy?.value, .known(200, .kcal), "grams log normally with no measures listed")
    }

    func testDensityNoteWaitsForTheListedMeasures() async throws {
        let model = try makePortionModel([:])
        model.applyLookedUp(LookedUpProduct(
            barcode: "", name: "Zzz unlisted food", brand: nil, basis: .per100g,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(100), .kcal)],
            attribution: nil, serving: nil, version: nil, sourceID: "9"))
        model.fieldDidBegin(.amount)
        model.unit = .cup
        // While the food's measures are still being asked for, no density line is shown either way.
        XCTAssertNil(model.densityUnavailableNote, "the note waits until the listed measures have loaded")
        await model.loadListedPortions()
        // Once they have come back empty, the note says what is true for this food.
        XCTAssertEqual(model.densityUnavailableNote, "No typical density is known for this food, so it is saved in mL.")
    }
}

/// The Brand field stays while the person clears it, and the small copy fixes around the Add form.
@MainActor
final class AddIntakeBrandFieldTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeModel() throws -> AddIntakeViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AddIntakeViewModel(
            store: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            now: now, timeZoneIdentifier: "UTC", lookup: nil)
    }

    func testBrandFieldStaysWhileTheBrandIsCleared() throws {
        let model = try makeModel()
        XCTAssertFalse(model.showsBrandField, "a typed food has nowhere to keep a brand")
        model.applyLookedUp(LookedUpProduct(
            barcode: "", name: "Rice cake", brand: "Acme", basis: .per100g,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(200), .kcal)],
            attribution: nil, serving: nil, version: nil))
        XCTAssertEqual(model.brand, "Acme")
        XCTAssertTrue(model.showsBrandField)
        model.brand = ""
        XCTAssertTrue(model.showsBrandField, "clearing the text must not remove the field being typed in")
    }

    func testAmountErrorNamesNoPoint() throws {
        let model = try makeModel()
        model.amountText = "abc"
        XCTAssertEqual(model.amountError, "Enter an amount greater than zero, such as 150 or 2.5.")
    }
}
