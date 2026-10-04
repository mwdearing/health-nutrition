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

    /// A panel row may state zero, and a Nutrition Facts panel states it often, so a correction to zero
    /// is a real answer rather than a mistake. The intake amount parser is the wrong rule here: it
    /// refuses zero because an intake of nothing is not an entry.
    func testCorrectionAcceptsZero() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        XCTAssertTrue(model.correct(key: .sodium, text: "0"))
        XCTAssertNil(model.correctionError)
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(0), .mg))
        XCTAssertEqual(model.row(for: .sodium)?.status, .corrected)
        XCTAssertTrue(model.canApply)
        // A stated zero is stored as a zero, not dropped as if the panel had said nothing.
        XCTAssertEqual(model.makeProduct()?.value(for: "sodium"), .known(Decimal(0), .mg))
    }

    func testCorrectionAcceptsZeroWithTheUnitsUnitName() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        XCTAssertTrue(model.correct(key: .sodium, text: "0 mg"))
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(0), .mg))

        // The same row in the unit it usually carries: a correction may state its own unit.
        XCTAssertTrue(model.correct(key: .fat, text: "0 g"))
        XCTAssertEqual(model.row(for: .fat)?.value, .known(Decimal(0), .g))
    }

    func testCorrectionRefusesNegativeAndUnreadableAmounts() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        for text in ["-1", "1.2.3", "18O", "", "abc", "1,5"] {
            XCTAssertFalse(model.correct(key: .sodium, text: text), "refused: \(text)")
        }
        XCTAssertNotNil(model.correctionError)
        // Nothing was changed by any of them, so the row still waits for the user.
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(180), .mg))
        XCTAssertFalse(model.canApply)
    }

    /// Recognition can read one valid number as another valid one, and then the parser has no reason
    /// to flag anything. The user can see the wrong value, so the user has to be able to replace it
    /// without the parser having asked.
    func testCorrectionOfAnUnflaggedKnownRowReplacesItsValue() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)

        let fat = model.row(for: .fat)
        XCTAssertEqual(fat?.value, .known(Decimal(4), .g))
        XCTAssertFalse(fat?.isFlagged == true)
        XCTAssertTrue(fat?.canBeCorrected == true)

        XCTAssertTrue(model.correct(key: .fat, text: "7"))

        XCTAssertEqual(model.row(for: .fat)?.value, .known(Decimal(7), .g))
        XCTAssertEqual(model.row(for: .fat)?.status, .corrected)
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.makeProduct()?.value(for: "fat"), .known(Decimal(7), .g))
    }

    /// A row the panel says nothing about has no value to correct, so it is left out of the correction
    /// controls rather than offered an amount field the user cannot fill in meaningfully.
    func testUnknownRowOffersNoCorrection() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        let potassium = model.row(for: .potassium)
        XCTAssertEqual(potassium?.value, .unknown)
        XCTAssertFalse(potassium?.canBeCorrected == true)
    }

    /// A bound is a limit, not an amount, so it is not a number the user can correct; it is read or
    /// not read, and the panel's own words stand.
    func testCorrectionKeepsTheUnitsThePanelPrinted() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        // Text with no unit keeps the unit the panel printed: a correction never moves a value.
        XCTAssertTrue(model.correct(key: .sodium, text: "150"))
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(150), .mg))

        // Text that names the same unit is read the same way.
        XCTAssertTrue(model.correct(key: .sodium, text: "150 mg"))
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(150), .mg))
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

    /// A panel can be read except for its serving-size line, which leaves every amount ambiguous: one
    /// serving might be 30 g or 250 mL or one item, and nothing downstream can scale the values. So the
    /// screen asks for the serving size rather than storing a bare "per serving".
    func testCaptureWithoutAServingSizeCannotBeAppliedUntilOneIsEntered() {
        let model = makeModel()
        model.load(lines: ["Calories 180", "Total Fat 4g", "Protein 8g"])

        XCTAssertFalse(model.isUnreadable, "the rows were read, so this is not an unreadable panel")
        XCTAssertTrue(model.servingIsMissing)
        XCTAssertFalse(model.canApply)
        XCTAssertNil(model.makeProduct())
        XCTAssertEqual(model.pendingCount, 1)

        XCTAssertTrue(model.enterServingSize(text: "30 g"))

        XCTAssertFalse(model.servingIsMissing)
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(30), unit: .g))
        XCTAssertTrue(model.canApply)
        // The values stay per serving, now with the serving spelled out.
        XCTAssertEqual(model.makeProduct()?.labelBasis, "per serving (30 g)")
    }

    func testEnteringAServingSizeWantsAnAmountWithItsUnit() {
        let model = makeModel()
        model.load(lines: ["Calories 180", "Total Fat 4g"])

        for text in ["", "a biscuit", "30", "0 g", "30 zz"] {
            XCTAssertFalse(model.enterServingSize(text: text), "refused: \(text)")
            XCTAssertNotNil(model.servingSizeError)
            XCTAssertTrue(model.servingIsMissing)
        }

        XCTAssertTrue(model.enterServingSize(text: "240 mL"))
        XCTAssertNil(model.servingSizeError)
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(240), unit: .mL))
    }

    /// A serving size the panel printed is the user's to confirm, not to retype: it was read, so it is
    /// shown as printed and only asked about when the parser corrected it.
    func testAStatedServingSizeIsNotAskedForAgain() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        XCTAssertFalse(model.servingIsMissing)
        XCTAssertEqual(model.servingText, "1 cup (240mL)")
        XCTAssertFalse(model.enterServingSize(text: "anything"))
    }

    // MARK: Correcting the serving size

    /// A serving size the panel printed is read, not fixed: the user has to be able to replace it the
    /// same way they replace a nutrient row, because the printed line is as easy to misread.
    func testServingSizeCanBeCorrectedAfterItWasRead() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)

        XCTAssertTrue(model.servingCanBeCorrected)
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(240), unit: .mL))

        XCTAssertTrue(model.correctServingSize(text: "30 g"))

        XCTAssertEqual(model.servingText, "30 g")
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(30), unit: .g))
        XCTAssertFalse(model.servingIsMissing)
        // Correcting the serving size is an answer like any other: it does not put the panel back to
        // asking, and it does not block the values.
        XCTAssertTrue(model.isServingConfirmed)
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.makeProduct()?.labelBasis, "per serving (30 g)")
    }

    func testCorrectingAServingSizeWantsAnAmountWithItsUnit() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        for text in ["", "a biscuit", "30", "0 g", "30 zz"] {
            XCTAssertFalse(model.correctServingSize(text: text), "refused: \(text)")
            XCTAssertNotNil(model.servingSizeError)
            // The printed serving size is still what the values are scaled by.
            XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(240), unit: .mL))
        }

        // An accepted correction puts the message away: it belonged to the text that was refused.
        XCTAssertTrue(model.correctServingSize(text: "30 g"))
        XCTAssertNil(model.servingSizeError)
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(30), unit: .g))
    }

    /// A panel that stated no serving size has nothing to correct; it has something to be told, which is
    /// the entry field the screen shows for it.
    func testAServingSizeThatWasNeverStatedIsEnteredRatherThanCorrected() {
        let model = makeModel()
        model.load(lines: ["Calories 180", "Total Fat 4g"])

        XCTAssertFalse(model.servingCanBeCorrected)
        XCTAssertFalse(model.correctServingSize(text: "30 g"))
        XCTAssertTrue(model.servingIsMissing)
    }

    // MARK: Correction units

    /// A correction may restate the amount in another unit of the same kind, so mg for a row printed in
    /// mg and g for the same row both read. It may not move a nutrient into a dimension nothing can
    /// interpret, because the value would then be silently dropped downstream.
    func testCorrectionAcceptsAnotherUnitOfTheSameDimension() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        XCTAssertTrue(model.correct(key: .sodium, text: "0.18 g"))
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(string: "0.18")!, .g))

        // The Calories row carries no unit of its own, so its usual unit supplies the dimension.
        XCTAssertTrue(model.correct(key: .calories, text: "180 kcal"))
        XCTAssertEqual(model.row(for: .calories)?.value, .known(Decimal(180), .kcal))
    }

    /// The dimension a correction is checked against is the nutrient's own, not whatever the capture read:
    /// the printed unit is sometimes the reason a row was flagged in the first place.
    func testCorrectionIsCheckedAgainstTheExpectedDimensionNotTheOneRead() {
        XCTAssertEqual(LabelCaptureViewModel.expectedDimension(for: .sodium), .mass)
        XCTAssertEqual(LabelCaptureViewModel.expectedDimension(for: .calories), .energy)
        XCTAssertEqual(LabelCaptureViewModel.expectedDimension(for: .fat), .mass)

        // A fat row printed in milligrams, which is flagged as an unexpected unit for fat. Correcting it
        // to grams is the same dimension and is allowed; correcting it to calories is not.
        let model = makeModel()
        model.load(lines: ["Total Fat 120mg"])
        XCTAssertEqual(model.row(for: .fat)?.value, .known(Decimal(120), .mg))

        XCTAssertTrue(model.correct(key: .fat, text: "8 g"))
        XCTAssertEqual(model.row(for: .fat)?.value, .known(Decimal(8), .g))

        XCTAssertFalse(model.correct(key: .fat, text: "8 kcal"))
        XCTAssertNotNil(model.correctionError)
        XCTAssertEqual(model.row(for: .fat)?.value, .known(Decimal(8), .g))
    }

    func testCorrectionRefusesAUnitFromAnotherDimension() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)

        // A volume for a mass, and a mass for the energy row.
        XCTAssertFalse(model.correct(key: .sodium, text: "1 L"))
        XCTAssertNotNil(model.correctionError)
        XCTAssertFalse(model.correct(key: .calories, text: "5 g"))
        XCTAssertNotNil(model.correctionError)
        // A count is no better a fit for a nutrient.
        XCTAssertFalse(model.correct(key: .protein, text: "2 tablets"))
        XCTAssertNotNil(model.correctionError)

        // Nothing was changed: the values are the ones the panel stated.
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(180), .mg))
        XCTAssertEqual(model.row(for: .calories)?.value, .known(Decimal(180), .kcal))
        XCTAssertEqual(model.row(for: .protein)?.value, .known(Decimal(8), .g))
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
        // Under the key the journal uses for the panel's Calories row, which is the same key the
        // barcode path stores, not the row's printed name.
        XCTAssertEqual(snapshot?.value(for: LookedUpProduct.energyKcal), .known(Decimal(180), .kcal))
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

    /// Starting a lookup says the user is replacing whatever this form already had, so the captured
    /// panel goes before the request is even sent. Otherwise Save is still enabled while the request is
    /// in flight and would store the panel the user has just decided to replace.
    func testStartingABarcodeLookupInvalidatesTheCapturedValuesBeforeTheReply() async throws {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)
        model.confirm(.sodium)

        let lookup = GatedBarcodeLookup(result: .found(barcodeProduct))
        let intake = try makeIntakeModel(lookup)
        intake.applyLabelProduct(try XCTUnwrap(model.makeProduct()))
        intake.name = "Synthetic Soup"
        // A valid code is needed, or the lookup stops at the shape check and never starts.
        intake.barcode = try XCTUnwrap(barcodeProduct.barcode)
        XCTAssertNotNil(intake.labelValues)

        let task = Task { await intake.lookUpBarcode() }
        for _ in 0..<1000 where lookup.requestedBarcodes.isEmpty { await Task.yield() }
        XCTAssertEqual(lookup.requestedBarcodes.count, 1, "the lookup was started")

        // The reply has not arrived and the captured values are already gone, so Save cannot store them.
        XCTAssertNil(intake.labelValues)
        XCTAssertTrue(intake.prefilledNutrients.isEmpty)
        XCTAssertNil(intake.serving)
        XCTAssertNil(intake.productSnapshot())

        lookup.answer()
        await task.value
        XCTAssertNotNil(intake.lookedUp)
    }

    /// An error from one row must not follow the user to the next: the message belongs to the correction
    /// that was refused, so cancelling it or starting another one puts it away.
    func testCancellingACorrectionClearsTheStaleError() {
        let model = makeModel()
        model.load(lines: panelWithFlaggedRow)

        XCTAssertFalse(model.correct(key: .sodium, text: "18O"))
        XCTAssertNotNil(model.correctionError)

        model.clearCorrectionError()
        XCTAssertNil(model.correctionError)
        // Putting the error away says nothing about the value, which still waits for the user.
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(180), .mg))
        XCTAssertFalse(model.canApply)
    }

    // MARK: Support

    /// A barcode product with values of its own, so a lookup that answers can be told apart from a
    /// captured panel.
    private var barcodeProduct: LookedUpProduct {
        LookedUpProduct(
            barcode: "4006381333931", name: nil, brand: nil, basis: .per100g,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(400), .kcal)])
    }

    private func makeIntakeModel(_ lookup: BarcodeProductLookup? = nil) throws -> AddIntakeViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AddIntakeViewModel(
            store: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC",
            lookup: lookup
        )
    }
}

/// Holds a reply until the test answers it, so a test can look at the form while a request is in flight.
private final class GatedBarcodeLookup: BarcodeProductLookup, @unchecked Sendable {
    private let result: BarcodeLookupResult
    private var continuation: CheckedContinuation<BarcodeLookupResult, Never>?
    private(set) var requestedBarcodes: [String] = []

    init(result: BarcodeLookupResult) {
        self.result = result
    }

    func lookUp(barcode: String) async -> BarcodeLookupResult {
        requestedBarcodes.append(barcode)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func answer() {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
