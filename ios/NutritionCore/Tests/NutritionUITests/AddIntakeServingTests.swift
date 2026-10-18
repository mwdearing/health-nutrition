import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeServingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeModel() throws -> AddIntakeViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        return AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC", lookup: nil,
            preferences: InMemoryDisplayPreferences(unitSystem: .usCustomary))
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
}
