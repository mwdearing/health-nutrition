import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AddIntakeLabelServingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeModel(_ store: SwiftDataJournalStore) -> AddIntakeViewModel {
        AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC",
            preferences: InMemoryDisplayPreferences(unitSystem: .metric))
    }

    private func panel(basis: String) -> ProductDefinition {
        ProductDefinition(
            snapshotID: "example-label-\(basis.hashValue)", productID: "example-label", name: "Biscuit",
            labelBasis: basis, catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["energyKcal": .known(480, .kcal)])
    }

    /// A captured per-serving panel with a weight gives the Servings control its serving.
    func testCapturedServingWeightEnablesTheServingsCount() throws {
        let model = makeModel(try makeStore())
        model.applyLabelProduct(panel(basis: "per serving (30 g)"), fromLabelCapture: true)

        XCTAssertTrue(model.canCountServings)
        XCTAssertEqual(model.servingOption?.quantity, 30)
        XCTAssertEqual(model.servingOption?.unit, .g)
    }

    /// A serving given only as text has no weight, so no count is offered for it.
    func testCapturedServingTextWithoutWeightOffersNoCount() throws {
        let model = makeModel(try makeStore())
        model.applyLabelProduct(panel(basis: "per serving (1 large biscuit)"), fromLabelCapture: true)

        XCTAssertFalse(model.canCountServings)
    }

    /// A captured per-serving panel with a weight scales its nutrients to the amount typed, through the same
    /// factor the "This adds" lines and the save path use: 15 g of a 30 g serving is half the serving.
    func testCapturedServingPanelFeedsTheAmountPreview() throws {
        let model = makeModel(try makeStore())
        model.applyLabelProduct(panel(basis: "per serving (30 g)"), fromLabelCapture: true)
        model.amountText = "15"
        model.unit = .g

        XCTAssertEqual(model.amountPreview?.kcal, 240)
        XCTAssertEqual(model.amountPreview?.grams, 15)
    }

    /// Clearing the form drops the captured serving and basis, so the next entry starts clean.
    func testClearingTheFormDropsTheCapturedServingAndBasis() throws {
        let model = makeModel(try makeStore())
        model.applyLabelProduct(panel(basis: "per serving (30 g)"), fromLabelCapture: true)
        model.amountText = "15"
        model.unit = .g
        XCTAssertNotNil(model.amountPreview)
        model.invalidateLookup()

        XCTAssertNil(model.servingOption)
        XCTAssertFalse(model.canCountServings)
        XCTAssertNil(model.amountPreview)
    }

    /// An ounce amount is scaled through its stored gram quantity, the same as the saved amount.
    func testAnOunceAmountScalesThroughItsStoredGrams() throws {
        let model = makeModel(try makeStore())
        model.applyLabelProduct(panel(basis: "per serving (30 g)"), fromLabelCapture: true)
        model.amountText = "1"
        model.unit = .oz

        let kcal = try XCTUnwrap(model.amountPreview?.kcal)
        XCTAssertEqual(NSDecimalNumber(decimal: kcal).doubleValue, 453.59, accuracy: 0.01)
    }
}
