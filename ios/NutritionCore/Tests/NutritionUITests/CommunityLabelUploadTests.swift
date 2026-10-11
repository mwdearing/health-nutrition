import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// Records every label the form submits, in order.
private actor RecordingSubmitter: CommunityLabelSubmitting {
    private(set) var received: [CommunityLabelSubmission] = []

    func submit(_ submission: CommunityLabelSubmission) async {
        received.append(submission)
    }
}

/// Holds its upload until the test releases it, so a test can show that saving does not wait for it.
private actor HeldSubmitter: CommunityLabelSubmitting {
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func submit(_ submission: CommunityLabelSubmission) async {
        if released { return }
        await withCheckedContinuation { gate = $0 }
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}

/// Answers a barcode with one product, so a test can fill the form from a lookup.
private final class FoundBarcodeLookup: BarcodeProductLookup, @unchecked Sendable {
    func lookUp(barcode: String) async -> BarcodeLookupResult {
        .found(LookedUpProduct(barcode: barcode, name: "Looked up bar", brand: nil, basis: .per100g, nutrients: [:]))
    }
}

@MainActor
final class CommunityLabelUploadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// 13 digits with a correct check digit.
    private let validBarcode = "4006381333931"
    /// The same digits with the check digit changed, so the shape check refuses it.
    private let invalidBarcode = "4006381333932"

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeModel(
        submitter: CommunityLabelSubmitting? = RecordingSubmitter(), sharing: Bool = true,
        lookup: BarcodeProductLookup? = nil
    ) throws -> AddIntakeViewModel {
        AddIntakeViewModel(
            store: try makeStore(), now: now, timeZoneIdentifier: "UTC", lookup: lookup,
            labelSubmitter: submitter, isSharingAllowed: { sharing })
    }

    /// A captured panel as the label capture hands it over: per serving, with the serving stated.
    private func panel(
        basis: String = "per serving (30 g)", nutrients: [String: NutrientValue]? = nil
    ) -> ProductDefinition {
        ProductDefinition(
            snapshotID: "label-test-panel", productID: "label_capture", name: "", labelBasis: basis,
            catalogOrigin: ProductOrigin.label_capture, catalogVersion: "unknown", kind: .food,
            nutrients: nutrients ?? fullPanel)
    }

    private var fullPanel: [String: NutrientValue] {
        [
            "energyKcal": .known(120, .kcal), "protein": .known(2, .g), "carbohydrates": .known(15, .g),
            "sugars": .known(6, .g), "fat": .known(3, .g), "saturatedFat": .known(1.5, .g),
            "fiber": .known(1, .g), "sodium": .known(0.2, .g), "salt": .known(0.5, .g),
        ]
    }

    /// Captures a panel into the form, names it and gives it a valid barcode, ready to save.
    private func captureAndFill(_ model: AddIntakeViewModel, product: ProductDefinition? = nil) {
        model.applyLabelProduct(product ?? panel(), fromLabelCapture: true)
        model.name = "Oat bar"
        model.barcode = validBarcode
        model.amountText = "1"
    }

    func testNothingIsSubmittedBeforeTheSave() throws {
        let model = try makeModel()
        captureAndFill(model)

        XCTAssertNil(model.uploadTask)
    }

    func testAPlainCapturedPanelIsSubmittedAfterTheSave() async throws {
        let submitter = RecordingSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model)

        XCTAssertTrue(model.save(now: now))
        await model.uploadTask?.value
        let sent = await submitter.received

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.barcode, validBarcode)
        XCTAssertEqual(sent.first?.basis, .perServing)
        XCTAssertEqual(sent.first?.servingText, "30 g")
        XCTAssertEqual(sent.first?.productName, "Oat bar")
        XCTAssertNil(sent.first?.brand)
    }

    func testPayloadHasOnlyTheValueFields() async throws {
        let submitter = RecordingSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model)

        XCTAssertTrue(model.save(now: now))
        await model.uploadTask?.value
        let sent = await submitter.received

        let labels = Mirror(reflecting: try XCTUnwrap(sent.first)).children.compactMap(\.label)
        XCTAssertEqual(labels, ["barcode", "basis", "servingText", "productName", "brand", "nutrients"])
    }

    func testNutrientsAreSentInCanonicalUnits() async throws {
        let submitter = RecordingSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model)

        XCTAssertTrue(model.save(now: now))
        await model.uploadTask?.value
        let nutrients = try XCTUnwrap(await submitter.received.first?.nutrients)

        XCTAssertEqual(nutrients["energyKcal"], 120)
        XCTAssertEqual(nutrients["sodium"], 200)
        XCTAssertEqual(nutrients["fat"], 3)
        XCTAssertEqual(nutrients.count, 9)
        XCTAssertTrue(Set(nutrients.keys).isSubset(of: Set(LookedUpProduct.standardKeys)))
    }

    func testTheAmountEatenDoesNotChangeWhatIsSent() async throws {
        let submitter = RecordingSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model)
        model.amountText = "250"

        XCTAssertTrue(model.save(now: now))
        await model.uploadTask?.value
        let sent = await submitter.received

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.nutrients["sodium"], 200)
        XCTAssertEqual(sent.first?.productName, "Oat bar")
    }

    func testBrandIsSentTrimmedAndTheNameToo() async throws {
        let submitter = RecordingSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model)
        model.name = "  Oat bar  "
        model.brand = "  Acme  "

        XCTAssertTrue(model.save(now: now))
        await model.uploadTask?.value
        let sent = await submitter.received.first

        XCTAssertEqual(sent?.productName, "Oat bar")
        XCTAssertEqual(sent?.brand, "Acme")
    }

    func testADrinkIsSubmitted() async throws {
        let submitter = RecordingSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model)
        model.kind = .drink

        XCTAssertTrue(model.save(now: now))
        await model.uploadTask?.value

        let count = await submitter.received.count
        XCTAssertEqual(count, 1)
    }

    func testASupplementIsNeverSubmitted() throws {
        let model = try makeModel()
        captureAndFill(model)
        model.kind = .supplement

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testAnInvalidBarcodeIsNeverSubmitted() throws {
        let model = try makeModel()
        captureAndFill(model)
        model.barcode = invalidBarcode

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testABlankNameSavesNothingAndSubmitsNothing() throws {
        let model = try makeModel()
        captureAndFill(model)
        model.name = "   "

        XCTAssertFalse(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testNothingIsSubmittedWhileSharingIsOff() throws {
        let model = try makeModel(sharing: false)
        captureAndFill(model)

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testAModelWithNoSubmitterSubmitsNothing() throws {
        let model = try makeModel(submitter: nil)
        captureAndFill(model)

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testALookedUpProductIsNeverSubmitted() async throws {
        let model = try makeModel(lookup: FoundBarcodeLookup())
        model.barcode = validBarcode
        await model.lookUpBarcode()
        model.name = "Looked up bar"
        model.amountText = "1"

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testALibraryProductIsNeverSubmitted() throws {
        let model = try makeModel()
        model.applyStoredProduct(panel())
        model.barcode = validBarcode
        model.amountText = "1"

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testAPanelReusedFromAnEntryWithoutTheCaptureFlagIsNeverSubmitted() throws {
        let model = try makeModel()
        model.applyLabelProduct(panel())
        model.name = "Oat bar"
        model.barcode = validBarcode
        model.amountText = "1"

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testFewerThanThreeKnownValuesAreNotSubmitted() throws {
        let model = try makeModel()
        captureAndFill(model, product: panel(nutrients: [
            "energyKcal": .known(120, .kcal), "fat": .known(3, .g),
            "sodium": .notApplicable, "salt": .belowReportingThreshold(.g), "protein": .unknown,
        ]))

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testExactlyThreeKnownValuesAreEnoughAndBoundsAreSkipped() async throws {
        let submitter = RecordingSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model, product: panel(nutrients: [
            "energyKcal": .known(120, .kcal), "fat": .known(3, .g), "sugars": .known(6, .g),
            "salt": .belowReportingThreshold(.g), "protein": .notApplicable,
        ]))

        XCTAssertTrue(model.save(now: now))
        await model.uploadTask?.value
        let nutrients = try XCTUnwrap(await submitter.received.first?.nutrients)

        XCTAssertEqual(nutrients.count, 3)
        XCTAssertNil(nutrients["salt"])
    }

    func testAPerServingLabelWithoutServingTextIsNotSubmitted() throws {
        let model = try makeModel()
        captureAndFill(model, product: panel(basis: "per serving"))

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testAnUnspecifiedBasisIsNotSubmitted() throws {
        let model = try makeModel()
        captureAndFill(model, product: panel(basis: "per 100 g or mL"))

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.uploadTask)
    }

    func testSavingDoesNotWaitForTheUpload() async throws {
        let submitter = HeldSubmitter()
        let model = try makeModel(submitter: submitter)
        captureAndFill(model)

        // The upload is still held here, and the save has already returned.
        XCTAssertTrue(model.save(now: now))
        XCTAssertNotNil(model.uploadTask)
        await submitter.release()
        await model.uploadTask?.value
    }

    func testAnUploadErrorNeverChangesTheSaveResult() throws {
        // The seam cannot throw: the app's adapter drops the error. A submitter that does nothing
        // stands for a failed upload, and the save still reports success.
        let model = try makeModel(submitter: RecordingSubmitter())
        captureAndFill(model)

        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.saveError)
    }
}
