import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeThisAddsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testThisAddsScalesWithTheAmount() async throws {
        let product = LookedUpProduct(barcode: "4006381333931", name: "Example oats", brand: nil,
            basis: .per100g, nutrients: ["energyKcal": .known(380, .kcal), "protein": .known(13, .g)])
        let model = AddIntakeViewModel(store: try makeStore(), now: now, lookup: PreviewLookup(product: product))
        model.barcode = product.barcode
        await model.lookUpBarcode()
        model.amountText = "50"
        XCTAssertEqual(model.thisAdds.first?.key, "energyKcal")
        XCTAssertEqual(model.thisAdds.first { $0.key == "protein" }?.text, "6.5 g")
        model.amountText = "100"
        XCTAssertEqual(model.thisAdds.first { $0.key == "protein" }?.value, .known(13, .g))
        model.amountText = "invalid"
        XCTAssertTrue(model.thisAdds.isEmpty)
    }

    func testThisAddsIsEmptyWhenNothingIsStated() async throws {
        let product = LookedUpProduct(barcode: "4006381333931", name: "Example oats", brand: nil,
            basis: .per100g, nutrients: [:])
        let model = AddIntakeViewModel(store: try makeStore(), now: now, lookup: PreviewLookup(product: product))
        model.barcode = product.barcode
        await model.lookUpBarcode()
        model.amountText = "50"
        XCTAssertFalse(model.hasPrefilledValues)
        XCTAssertTrue(model.thisAdds.isEmpty)
        XCTAssertTrue(model.statesNoNutrients)
    }

    func testBoundOnlyProductStillShowsItsValues() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-bound", productID: "example-oats",
            name: "Example oats", labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .belowReportingThreshold(.g)]))
        model.amountText = "50"
        model.unit = .g
        XCTAssertTrue(model.hasPrefilledValues)
        let protein = try XCTUnwrap(model.thisAdds.first { $0.key == "protein" })
        XCTAssertEqual(protein.text, "Less than the label reports (g)")
    }

    /// A compound the label states only as a bound is still one of the label's own rows, so it is
    /// listed with the other compounds rather than dropped because it has no exact amount.
    func testBoundOnlyCompoundIsListedWithTheLabelsOwnRows() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-compound-bound", productID: "example-oats",
            name: "Example oats", labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["example-compound": .belowReportingThreshold(.mg), "example-absent": .unknown]))
        XCTAssertTrue(model.hasPrefilledValues)
        XCTAssertEqual(model.additionalLabelNutrients, ["example-compound"])
    }

    func testNotApplicableSurvivesAnAmountThatCannotBeScaled() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-no-basis", productID: "example-oats",
            name: "Example oats", labelBasis: "per serving", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(13, .g), "sodium": .notApplicable]))
        model.amountText = "40"
        model.unit = .g
        let sodium = try XCTUnwrap(model.thisAdds.first { $0.key == "sodium" })
        XCTAssertEqual(sodium.value, .notApplicable)
        XCTAssertFalse(sodium.cannotScale)
        XCTAssertEqual(sodium.text, "Does not apply")
        let protein = try XCTUnwrap(model.thisAdds.first { $0.key == "protein" })
        XCTAssertTrue(protein.cannotScale)
    }

    func testThisAddsIncludesPotassium() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyStoredProduct(ProductDefinition(snapshotID: "example-potassium", productID: "example-oats",
            name: "Example oats", labelBasis: "per 100 g", catalogOrigin: "example", catalogVersion: "1",
            nutrients: ["potassium": .known(400, .mg)]))
        model.amountText = "50"
        let line = try XCTUnwrap(model.thisAdds.first { $0.key == "potassium" })
        XCTAssertEqual(line.displayName, "Potassium")
        XCTAssertEqual(line.value, .known(200, .mg))
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-protein", productID: "example-oats",
            name: "", labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(13, .g)]))
        XCTAssertFalse(model.thisAdds.contains { $0.key == "potassium" })
    }

    /// A standard nutrient the product does not state is not a line in the preview, so only the stated
    /// protein is listed.
    func testThisAddsLeavesOutUnstatedStandardNutrients() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-protein-only", productID: "example-oats",
            name: "Example oats", labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(13, .g)]))
        model.amountText = "50"
        model.unit = .g
        XCTAssertEqual(model.thisAdds.map(\.key), ["protein"])
    }

    /// Stated energy leads the stated protein, and a "does not apply" sodium is still listed because the
    /// product said something about it.
    func testThisAddsKeepsStatedEnergyFirstAndNotApplicableSodium() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-energy-protein", productID: "example-oats",
            name: "Example oats", labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(13, .g), "energyKcal": .known(380, .kcal), "sodium": .notApplicable]))
        model.amountText = "50"
        model.unit = .g
        XCTAssertEqual(model.thisAdds.map(\.key), ["energyKcal", "protein", "sodium"])
        XCTAssertEqual(model.thisAdds.first { $0.key == "sodium" }?.value, .notApplicable)
    }

    /// A household measure inside the serving's brackets scales from its gram weight: 60 g of a bar
    /// stated as "1 bar (30 g)" is two servings, so 10 g of protein per serving is 20 g.
    func testHouseholdServingTextScalesTheStoredProduct() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyStoredProduct(ProductDefinition(snapshotID: "example-bar", productID: "example-bar",
            name: "Example bar", labelBasis: "per serving (1 bar (30 g))", catalogOrigin: "example", catalogVersion: "1",
            nutrients: ["protein": .known(10, .g)]))
        model.amountText = "60"
        model.unit = .g
        XCTAssertEqual(model.thisAdds.first { $0.key == "protein" }?.value, .known(20, .g))
    }

    func testLabelScanKeepsTheLibraryName() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        let product = ProductDefinition(snapshotID: "example-library", productID: "example-oats",
            name: "Example oats", brand: "Example brand", labelBasis: "per 100 g",
            catalogOrigin: "example", catalogVersion: "1", nutrients: ["protein": .known(13, .g)])
        model.applyStoredProduct(product)
        XCTAssertEqual(model.productSnapshot(), product)
        model.applyLabelProduct(ProductDefinition(snapshotID: "example-label", productID: "example-oats",
            name: "", labelBasis: "per 100 g", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(14, .g)]))
        XCTAssertEqual(model.name, "Example oats")
        XCTAssertEqual(model.brand, "Example brand")
    }

    func testThisAddsIsUnknownForAnUnresolvableBasis() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        for basis in ["per serving", "per serving (30 g)"] {
            model.applyLabelProduct(ProductDefinition(snapshotID: "example-label", productID: "example-oats",
                name: "Example oats", labelBasis: basis, catalogOrigin: "label", catalogVersion: "1",
                nutrients: ["protein": .known(13, .g)]))
            model.amountText = basis == "per serving" ? "40" : "60"
            if basis == "per serving" {
                XCTAssertTrue(model.thisAdds.allSatisfy { $0.value == .unknown })
                let stated = try XCTUnwrap(model.thisAdds.first { $0.key == "protein" })
                XCTAssertEqual(stated.text, "Can't be worked out for this amount")
                XCTAssertEqual(model.thisAdds.map(\.key), ["protein"])
            } else {
                XCTAssertEqual(model.thisAdds.first { $0.key == "protein" }?.value, .known(26, .g))
                XCTAssertEqual(model.servingHint, "1 serving = 30 g")
            }
        }
    }

    func testStoredProductShowsLibraryValuesAndMatchesSavedMetricAmount() throws {
        let model = AddIntakeViewModel(store: try makeStore(), now: now)
        model.applyStoredProduct(ProductDefinition(snapshotID: "example-stored", productID: "example-oats",
            name: "Example oats", labelBasis: "per 100 g", catalogOrigin: "example", catalogVersion: "1",
            nutrients: ["energy": .known(380, .kcal), "protein": .known(13, .g), "dha": .known(2, .mg)],
            nutrientDisplayNames: ["dha": "DHA"]))
        model.amountText = "1"
        model.unit = .oz
        XCTAssertEqual(model.sourceLine, "From your Library")
        XCTAssertNil(model.attributionTitle)
        XCTAssertEqual(model.thisAdds.first?.value, .known(Decimal(string: "107.728187875")!, .kcal))
        XCTAssertEqual(model.additionalLabelNutrients, ["dha"])
        XCTAssertEqual(model.displayName(forAdditional: "dha"), "DHA")
    }

    func testEditedStoredProductsDeriveDistinctSnapshots() throws {
        let store = try makeStore()
        var ids: [String] = []
        for number in 1...2 {
            let model = AddIntakeViewModel(store: store, now: now)
            model.applyStoredProduct(ProductDefinition(snapshotID: "example-stored-\(number)", productID: "example-\(number)",
                name: "Example oats", labelBasis: "per 100 g", catalogOrigin: "example", catalogVersion: "1",
                nutrients: ["protein": .known(13, .g)]))
            model.name = "Edited oats"
            model.amountText = "50"
            XCTAssertTrue(model.save(now: now))
            ids.append(try XCTUnwrap(model.productSnapshot()).snapshotID)
        }
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(try store.activeIntakes().count, 2)
    }

    func testRecipeThroughAddKeepsTheVersionSnapshot() throws {
        let store = try makeStore()
        let recipe = uiSampleVersion()
        let model = try AddHomeViewModel(store: store).makeDetails(recipe: recipe, now: now)
        XCTAssertTrue(model.save(now: now))
        let intake = try XCTUnwrap(store.activeIntakes().first)
        let revision = try XCTUnwrap(store.revisions(of: intake.id).first)
        XCTAssertEqual(revision.productSnapshotID, RecipeLogger.snapshotID(recipeID: recipe.recipeID, number: recipe.number))
    }
}

private struct PreviewLookup: BarcodeProductLookup {
    let product: LookedUpProduct
    func lookUp(barcode: String) async -> BarcodeLookupResult { .found(product) }
}
