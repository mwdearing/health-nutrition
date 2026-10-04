import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// The panels below are synthetic: they were written for these tests and name no real product or
/// brand. They are the lines a capture session would hand over, one row per line.
@MainActor
final class LabelCaptureViewModelTests: XCTestCase {
    /// A clean panel with one flagged row: the sodium printed a letter `O` where a zero belongs, so
    /// the parser corrected it and asks the user about it.
    private var panelWithFlaggedRow: [String] {
        [
            "Nutrition Facts",
            "Synthetic Soup, invented for tests",
            "Serving size 1 cup (240mL)",
            "Amount per serving",
            "Calories 180",
            "Total Fat 4g 6%",
            "Sodium 18O mg 8%",
            "Total Carbohydrate 24g 8%",
            "  Total Sugars 6g",
            "Protein 8g 16%",
        ]
    }

    private func makeModel() -> LabelCaptureViewModel {
        LabelCaptureViewModel()
    }

    // MARK: Flagged rows

    func testFlaggedRowBlocksApplyUntilItIsConfirmed() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        let sodium = model.row(for: .sodium)
        XCTAssertEqual(sodium?.value, .known(Decimal(180), .mg))
        XCTAssertTrue(sodium?.needsConfirmation == true)
        XCTAssertEqual(model.pendingCount, 1)
        // The flagged value is on screen, so nothing is saved on the parser's word alone.
        XCTAssertFalse(model.canApply)
        XCTAssertNil(model.makeProduct())

        model.confirm(.sodium)

        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertTrue(model.canApply)
        XCTAssertNotNil(model.makeProduct())
    }

    func testCorrectionReplacesAFlaggedValue() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        // Text the amount parser does not accept changes nothing, and says why.
        XCTAssertFalse(model.correct(key: .sodium, text: "18O"))
        XCTAssertNotNil(model.correctionError)
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(180), .mg))
        XCTAssertFalse(model.canApply)

        XCTAssertTrue(model.correct(key: .sodium, text: "185"))
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(185), .mg))
        XCTAssertEqual(model.row(for: .sodium)?.status, .corrected)
        XCTAssertTrue(model.canApply)
    }

    func testFlaggedServingSizeBlocksApplyUntilItIsConfirmed() {
        let model = makeModel()
        model.load(lines: [
            "Serving size 1 cup (24O mL)",
            "Calories 120",
            "Protein 3g",
        ])

        XCTAssertTrue(model.servingNeedsReview)
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertFalse(model.canApply)

        model.confirmServing()

        XCTAssertFalse(model.servingNeedsReview)
        XCTAssertTrue(model.canApply)
    }

    // MARK: The product

    func testUnknownRowsStayUnknownInTheProduct() throws {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)

        // The panel says nothing about potassium, so that row stays unknown on screen...
        XCTAssertEqual(model.row(for: .potassium)?.value, .unknown)
        XCTAssertEqual(model.row(for: .potassium)?.status, .read)

        // ...and the product leaves it out rather than turning it into a zero: reading it back gives
        // unknown, which is a different state from a stated zero.
        let product = try XCTUnwrap(model.makeProduct())
        XCTAssertNil(product.nutrients["potassium"])
        XCTAssertEqual(product.value(for: "potassium"), .unknown)
        XCTAssertEqual(product.value(for: "fat"), .known(Decimal(4), .g))
    }

    func testServingSizeIsCarriedIntoTheProduct() throws {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)

        XCTAssertEqual(model.servingText, "1 cup (240mL)")
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(240), unit: .mL))

        let product = try XCTUnwrap(model.makeProduct())
        XCTAssertEqual(product.labelBasis, "per serving (240 mL)")
        XCTAssertEqual(product.catalogOrigin, "label_capture")
        // A panel states no code, so the snapshot carries none rather than an invented one.
        XCTAssertNil(product.barcode)
    }

    func testProductWithoutAStatedMeasureKeepsThePrintedServingText() {
        let model = makeModel()
        model.load(lines: ["Serving size 1 large biscuit", "Calories 90", "Fat 3g"])

        let product = model.makeProduct()
        XCTAssertEqual(product?.labelBasis, "per serving (1 large biscuit)")
        XCTAssertNil(model.servingQuantity)
    }

    // MARK: Unreadable panels

    func testUnreadablePanelSaysSoAndOffersRetake() {
        let model = makeModel()
        model.load(lines: ["Synthetic Brand, invented for tests", "Best before 2027"])

        XCTAssertTrue(model.isUnreadable)
        XCTAssertFalse(model.canApply)
        XCTAssertNil(model.makeProduct())
        let message = model.statusMessage ?? ""
        XCTAssertTrue(
            message.lowercased().contains("panel"), "the user is told the panel could not be read: \(message)")
        XCTAssertTrue(model.canRetake)
    }

    func testRetakeDropsThePanelThatWasNotSaved() {
        let model = makeModel()
        model.load(lines: ["Synthetic Brand, invented for tests"])
        XCTAssertTrue(model.isUnreadable)

        model.retake()

        XCTAssertFalse(model.isUnreadable)
        XCTAssertFalse(model.hasPanel)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.statusMessage)
    }

    // MARK: Filling the intake form

    func testApplyingTheProductFillsTheAddIntakeForm() throws {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)
        let product = try XCTUnwrap(model.makeProduct())

        let intake = try makeIntakeModel()
        intake.applyLabelProduct(product)

        // The name is left for the user, the way a barcode lookup that states no name leaves it.
        XCTAssertEqual(intake.name, "")
        XCTAssertEqual(intake.prefilledNutrients["fat"], .known(Decimal(4), .g))
        XCTAssertEqual(intake.prefilledNutrients["sodium"], .known(Decimal(180), .mg))
        XCTAssertEqual(intake.prefilledNutrients["potassium"], .unknown)
        XCTAssertNotNil(intake.labelValues)

        // The snapshot is written on save, with the origin the capture recorded.
        intake.name = "Synthetic Soup"
        let snapshot = intake.productSnapshot()
        XCTAssertEqual(snapshot?.catalogOrigin, "label_capture")
        XCTAssertEqual(snapshot?.labelBasis, "per serving (240 mL)")
        XCTAssertEqual(snapshot?.name, "Synthetic Soup")
        XCTAssertEqual(snapshot?.value(for: "calories"), .known(Decimal(180), .kcal))
    }

    func testALaterBarcodeInvalidatesTheCapturedValues() throws {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)

        let intake = try makeIntakeModel()
        intake.applyLabelProduct(try XCTUnwrap(model.makeProduct()))
        XCTAssertNotNil(intake.labelValues)

        intake.setScannedBarcode("4006381333931")

        XCTAssertNil(intake.labelValues)
        XCTAssertTrue(intake.prefilledNutrients.isEmpty)
        XCTAssertNil(intake.serving)
        intake.name = "Synthetic Soup"
        XCTAssertNil(intake.productSnapshot())
    }

    // MARK: Support

    private func makeIntakeModel() throws -> AddIntakeViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AddIntakeViewModel(
            store: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC"
        )
    }
}
