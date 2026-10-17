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
        return AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC", lookup: nil)
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
        XCTAssertEqual(model.amountText, "2")
        XCTAssertEqual(model.unit, .oz)
        XCTAssertEqual(model.servingCount, "1")
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
}
