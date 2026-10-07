import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Returns canned results and records every barcode it was asked about, so a test can tell that an
/// invalid barcode never reached the lookup at all.
private final class FakeBarcodeLookup: BarcodeProductLookup, @unchecked Sendable {
    private let result: BarcodeLookupResult
    private let resultForBarcode: ((String) -> BarcodeLookupResult)?
    private(set) var requestedBarcodes: [String] = []

    init(result: BarcodeLookupResult) {
        self.result = result
        self.resultForBarcode = nil
    }

    init(resultForBarcode: @escaping (String) -> BarcodeLookupResult) {
        self.result = .notFound
        self.resultForBarcode = resultForBarcode
    }

    func lookUp(barcode: String) async -> BarcodeLookupResult {
        requestedBarcodes.append(barcode)
        return resultForBarcode?(barcode) ?? result
    }
}

/// Holds a reply until the test answers it, so a test can change the form while a request is in
/// flight and then see whether the late reply is applied.
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

@MainActor
final class AddIntakeBarcodeLookupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// 13 digits with a correct check digit.
    private let validBarcode = "4006381333931"
    /// A second valid barcode, for asking what happens when the field changes mid-lookup.
    private let otherBarcode = "5000112637922"

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeModel(_ lookup: BarcodeProductLookup?) throws -> AddIntakeViewModel {
        AddIntakeViewModel(
            store: try makeStore(), now: now, timeZoneIdentifier: "UTC", lookup: lookup)
    }

    /// The attribution a source with licence obligations would supply. The UI shows whatever it is
    /// given and never names a source itself.
    private let attribution = ProductAttribution(
        source: "example-catalog", text: "Nutrition facts from Example Foods, under CC BY-SA.",
        url: "https://example.invalid/foods")

    private func oatMilk(barcode: String? = nil, basis: BarcodeLookupBasis = .per100ml)
        -> LookedUpProduct
    {
        LookedUpProduct(
            barcode: barcode ?? validBarcode,
            name: "Oat drink",
            brand: "Example Foods",
            basis: basis,
            nutrients: [
                LookedUpProduct.energyKcal: .known(Decimal(45), .kcal),
                LookedUpProduct.protein: .known(Decimal(string: "1.0")!, .g),
                LookedUpProduct.carbohydrates: .known(Decimal(string: "6.5")!, .g),
                // No sugar, fat, fiber, sodium or salt given: those stay unknown.
            ],
            attribution: attribution,
            serving: basis == .perServing
                ? ServingDefinition(quantity: Decimal(30), unit: .g, text: "30 g") : nil,
            version: "2024-05-01"
        )
    }

    // MARK: Prefilling

    func testFoundPrefillsNameBrandAndNutrients() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .found(oatMilk())))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.name, "Oat drink")
        XCTAssertEqual(model.brand, "Example Foods")
        XCTAssertEqual(model.lookupBasis, .per100ml)
        XCTAssertEqual(model.prefilledNutrients[LookedUpProduct.energyKcal], .known(Decimal(45), .kcal))
        XCTAssertEqual(model.prefilledNutrients[LookedUpProduct.protein], .known(Decimal(1), .g))
        XCTAssertEqual(model.lookupState, .found(oatMilk()))
        XCTAssertNotNil(model.lookupMessage)
        // The amount stays the user's to fill in; a lookup never guesses it.
        XCTAssertEqual(model.amountText, "")
    }

    func testFoundCarriesTheAttributionTextAndLink() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .found(oatMilk())))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        // Values from a licensed source are only allowed on screen next to its attribution, so both
        // the wording and the link travel with the result.
        XCTAssertEqual(model.attribution?.text, "Nutrition facts from Example Foods, under CC BY-SA.")
        XCTAssertEqual(model.attribution?.url, "https://example.invalid/foods")
        XCTAssertNotNil(URL(string: try XCTUnwrap(model.attribution).url))
    }

    func testPerServingResultShowsWhatOneServingIs() async throws {
        let model = try makeModel(
            FakeBarcodeLookup(result: .found(oatMilk(basis: .perServing))))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        // "per serving" on its own leaves the numbers ambiguous: a serving may be 30 g or 250 mL.
        XCTAssertEqual(model.serving?.label, "30 g")
        XCTAssertEqual(try XCTUnwrap(model.serving?.quantity), Decimal(30))
        XCTAssertEqual(model.lookupMessage, "Filled in from the barcode (per serving (30 g)). Check the amount, then save.")
    }

    func testTextOnlyServingDefinitionIsKeptAndLabelled() {
        // A source may give the size only as text, with no number to read.
        let biscuit = ServingDefinition(quantity: nil, unit: nil, text: "1 biscuit")
        XCTAssertEqual(biscuit.label, "1 biscuit")
        XCTAssertFalse(biscuit.isEmpty)
        // Nothing said at all is unusable rather than faked.
        XCTAssertTrue(ServingDefinition(quantity: nil, unit: nil, text: nil).isEmpty)
        XCTAssertTrue(ServingDefinition(quantity: nil, unit: nil, text: "   ").isEmpty)
        // The source's wording wins over a number, because it carries the unit.
        XCTAssertEqual(ServingDefinition(quantity: Decimal(250), unit: .mL, text: "250 ml").label, "250 ml")
        XCTAssertEqual(ServingDefinition(quantity: Decimal(30), unit: .g, text: nil).label, "30 g")
    }

    // MARK: Other outcomes

    func testNotFoundShowsNotFoundMessageAndPrefillsNothing() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .notFound))
        model.name = "Typed by hand"
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupState, .notFound)
        XCTAssertEqual(model.lookupMessage, "No product found for that barcode. Fill in the details yourself.")
        XCTAssertEqual(model.name, "Typed by hand")
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
    }

    func testRateLimitedUsesTheWaitTheSourceAskedFor() async throws {
        let model = try makeModel(
            FakeBarcodeLookup(result: .rateLimited(retryAfterSeconds: 30)))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupState, .rateLimited(retryAfterSeconds: 30))
        XCTAssertEqual(model.lookupMessage, "Too many lookups just now. Try again in 30 seconds.")
    }

    func testRateLimitedOverAMinuteSaysAboutThatManyMinutes() async throws {
        let model = try makeModel(
            FakeBarcodeLookup(result: .rateLimited(retryAfterSeconds: 180)))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupMessage, "Too many lookups just now. Try again in about 3 minutes.")
    }

    func testRateLimitedWithoutAnIntervalFallsBackToAMinute() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .rateLimited(retryAfterSeconds: nil)))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupMessage, "Too many lookups just now. Try again in a minute.")
    }

    func testFailedShowsFailureMessage() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .failed("offline")))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupState, .failed("offline"))
        XCTAssertEqual(model.lookupMessage, "The lookup did not finish. Try again in a moment.")
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
    }

    // MARK: Barcode validation

    func testInvalidBarcodeMakesNoLookupCall() async throws {
        let lookup = FakeBarcodeLookup(result: .found(oatMilk()))
        let model = try makeModel(lookup)

        for text in ["", "   ", "123", "12345678901234", "400638133393x", "4 006381 333931"] {
            model.barcode = text
            await model.lookUpBarcode()
            XCTAssertEqual(model.lookupState, .invalidBarcode, text)
            XCTAssertEqual(
                model.lookupMessage,
                "A barcode has 8, 12 or 13 digits and a correct check digit. Nothing was looked up.", text)
        }
        XCTAssertTrue(lookup.requestedBarcodes.isEmpty)
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
    }

    func testBarcodeWithABadCheckDigitMakesNoLookupCall() async throws {
        let lookup = FakeBarcodeLookup(result: .found(oatMilk()))
        let model = try makeModel(lookup)

        for text in ["4006381333932", "5000112637923", "5901234123458"] {
            model.barcode = text
            await model.lookUpBarcode()
            // The provider would reject these too, so no request is attempted and the user is told
            // the barcode is wrong rather than that something failed and to try again.
            XCTAssertEqual(model.lookupState, .invalidBarcode, text)
        }
        XCTAssertTrue(lookup.requestedBarcodes.isEmpty)
    }

    func testBarcodeIsTrimmedBeforeTheLookup() async throws {
        let lookup = FakeBarcodeLookup(result: .found(oatMilk()))
        let model = try makeModel(lookup)
        model.barcode = "  \(validBarcode) "

        await model.lookUpBarcode()

        XCTAssertEqual(lookup.requestedBarcodes, [validBarcode])
        XCTAssertEqual(model.barcode, validBarcode)
    }

    // MARK: Request identity

    func testReplyPaddedToThirteenDigitsIsAccepted() async throws {
        // A 12-digit UPC-A asked for as itself comes back as a GTIN-13 with a leading zero; that is
        // the same product, so the form must fill in rather than sit on its spinner for ever.
        let upc = "500011263796"
        XCTAssertTrue(BarcodeShape.isValid(upc))
        let model = try makeModel(
            FakeBarcodeLookup(result: .found(oatMilk(barcode: "0" + upc))))
        model.barcode = upc

        await model.lookUpBarcode()

        XCTAssertEqual(model.name, "Oat drink")
        XCTAssertEqual(model.lookupState, .found(oatMilk(barcode: "0" + upc)))
    }

    func testEquivalenceIgnoresLeadingZerosButNotDifferentCodes() {
        XCTAssertTrue(BarcodeShape.areEquivalent("500011263796", "0500011263796"))
        XCTAssertTrue(BarcodeShape.areEquivalent("4006381333931", "4006381333931"))
        XCTAssertFalse(BarcodeShape.areEquivalent("4006381333931", "5000112637922"))
    }

    func testNotFoundAfterAFoundLookupClearsTheEarlierProduct() async throws {
        let first = validBarcode
        let product = oatMilk()
        let lookup = FakeBarcodeLookup(resultForBarcode: { barcode in
            barcode == first ? .found(product) : .notFound
        })
        let store = try makeStore()
        let model = AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC", lookup: lookup)
        model.barcode = validBarcode
        await model.lookUpBarcode()
        XCTAssertNotNil(model.lookedUp)

        // The second barcode is not in the catalog. Nothing from the first may survive, or saving the
        // entry the user types now would attach the first product's barcode and snapshot to it.
        model.barcode = otherBarcode
        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupState, .notFound)
        XCTAssertNil(model.lookedUp)
        XCTAssertNil(model.lookupBasis)
        XCTAssertNil(model.serving)
        XCTAssertNil(model.attribution)
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
        XCTAssertEqual(model.name, "")
        XCTAssertEqual(model.brand, "")
        XCTAssertNil(model.productSnapshot())

        // What the user types now is saved without any product attached.
        model.name = "Something else"
        model.amountText = "30"
        XCTAssertTrue(model.save(now: now))
        let revision = try XCTUnwrap(
            try store.revisions(of: try XCTUnwrap(try store.activeIntakes().first).id).first)
        XCTAssertNil(revision.productSnapshotID)
    }

    func testFailedAndRateLimitedAlsoClearTheEarlierProduct() async throws {
        let first = validBarcode
        let product = oatMilk()
        for result in [BarcodeLookupResult.failed("offline"), .rateLimited(retryAfterSeconds: 30)] {
            let lookup = FakeBarcodeLookup(resultForBarcode: { barcode in
                barcode == first ? .found(product) : result
            })
            let model = try makeModel(lookup)
            model.barcode = validBarcode
            await model.lookUpBarcode()
            XCTAssertNotNil(model.lookedUp)

            model.barcode = otherBarcode
            await model.lookUpBarcode()

            XCTAssertNil(model.lookedUp, "\(result)")
            XCTAssertTrue(model.prefilledNutrients.isEmpty, "\(result)")
            XCTAssertNil(model.productSnapshot(), "\(result)")
        }
    }

    func testAnEditedFieldSurvivesAFailedLookup() async throws {
        let first = validBarcode
        let product = oatMilk()
        let lookup = FakeBarcodeLookup(resultForBarcode: { barcode in
            barcode == first ? .found(product) : .failed("offline")
        })
        let model = try makeModel(lookup)
        model.barcode = validBarcode
        await model.lookUpBarcode()

        // The user types over what the lookup filled in; that text is theirs, not the lookup's.
        model.name = "My own name"
        model.barcode = otherBarcode
        await model.lookUpBarcode()

        XCTAssertEqual(model.name, "My own name")
        XCTAssertNil(model.lookedUp)
    }

    func testReplyForADifferentBarcodeIsIgnored() async throws {
        // A source can answer with the code it filed the product under; that answer belongs to the
        // form for that code, not to the barcode now in the field.
        let model = try makeModel(
            FakeBarcodeLookup(result: .found(oatMilk(barcode: otherBarcode))))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.name, "")
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
        XCTAssertNotEqual(model.lookupState, .found(oatMilk(barcode: otherBarcode)))
    }

    func testLateReplyIsIgnoredAfterTheBarcodeChanged() async throws {
        let lookup = GatedBarcodeLookup(result: .found(oatMilk()))
        let model = try makeModel(lookup)
        model.barcode = validBarcode

        let task = Task { await model.lookUpBarcode() }
        for _ in 0..<1000 where lookup.requestedBarcodes.isEmpty { await Task.yield() }
        XCTAssertEqual(lookup.requestedBarcodes, [validBarcode])

        // The user edits the field while the request is in flight, then the reply arrives.
        model.barcode = otherBarcode
        lookup.answer()
        await task.value

        // The form must not show one barcode beside another product's name and nutrients.
        XCTAssertEqual(model.name, "")
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
    }

    // MARK: Saving

    func testSaveStoresTheLookedUpProduct() async throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC",
            lookup: FakeBarcodeLookup(result: .found(oatMilk())))
        model.barcode = validBarcode
        await model.lookUpBarcode()
        model.amountText = "250"
        model.unit = .mL

        XCTAssertTrue(model.save(now: now))

        let intake = try XCTUnwrap(try store.activeIntakes().first)
        let revision = try XCTUnwrap(try store.revisions(of: intake.id).first)
        let snapshotID = try XCTUnwrap(revision.productSnapshotID)
        let snapshot = try XCTUnwrap(try store.product(snapshotID: snapshotID))
        XCTAssertEqual(snapshot.barcode, validBarcode)
        XCTAssertEqual(snapshot.brand, "Example Foods")
        XCTAssertEqual(snapshot.labelBasis, "per 100 mL")
        XCTAssertEqual(snapshot.catalogOrigin, "example-catalog")
        XCTAssertEqual(snapshot.catalogVersion, "2024-05-01")
        XCTAssertEqual(revision.components.first?.name, "Oat drink")
        XCTAssertEqual(revision.components.first?.amount, Decimal(250))
        XCTAssertEqual(revision.components.first?.unit, .mL)
    }

    func testSaveStoresTheSameSnapshotIDForTheSameLookup() async throws {
        let product = oatMilk()
        XCTAssertEqual(
            product.snapshotIdentity(name: "Oat drink", brand: "Example Foods"),
            product.snapshotIdentity(name: "Oat drink", brand: "Example Foods"))
        // Changed values must not re-use one id for two different products.
        let changed = LookedUpProduct(
            barcode: product.barcode, name: product.name, brand: product.brand, basis: product.basis,
            nutrients: [LookedUpProduct.energyKcal: .known(Decimal(46), .kcal)],
            attribution: product.attribution, version: product.version)
        XCTAssertNotEqual(
            product.snapshotIdentity(name: "Oat drink", brand: "Example Foods"),
            changed.snapshotIdentity(name: "Oat drink", brand: "Example Foods"))
    }

    func testSnapshotIdentityCoversTheSavedNameAndBrand() {
        // The snapshot stores the name and brand the user settled on, so two saves of one product
        // under different names need two ids; otherwise the second save is refused as a conflict.
        let product = oatMilk()
        let base = product.snapshotIdentity(name: "Oat drink", brand: "Example Foods")
        XCTAssertNotEqual(base, product.snapshotIdentity(name: "Oat drink, 1 l", brand: "Example Foods"))
        XCTAssertNotEqual(base, product.snapshotIdentity(name: "Oat drink", brand: nil))
    }

    func testSavingTheSameProductTwiceUnderDifferentNamesSucceeds() async throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC",
            lookup: FakeBarcodeLookup(result: .found(oatMilk())))
        model.barcode = validBarcode
        await model.lookUpBarcode()
        model.amountText = "250"
        XCTAssertTrue(model.save(now: now))

        model.name = "Oat drink, one bottle"
        model.amountText = "1000"
        XCTAssertTrue(model.save(now: now))

        XCTAssertNil(model.saveError)
        XCTAssertEqual(try store.activeIntakes().count, 2)
    }

    func testSaveStoresTheEditedBrand() async throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(
            store: store, now: now, timeZoneIdentifier: "UTC",
            lookup: FakeBarcodeLookup(result: .found(oatMilk())))
        model.barcode = validBarcode
        await model.lookUpBarcode()
        // The user corrects the brand the source gave before saving.
        model.brand = "Example Foods (corrected)"
        model.amountText = "250"

        XCTAssertTrue(model.save(now: now))

        let snapshotID = try XCTUnwrap(
            try store.revisions(of: try XCTUnwrap(try store.activeIntakes().first).id).first?.productSnapshotID)
        XCTAssertEqual(try store.product(snapshotID: snapshotID)?.brand, "Example Foods (corrected)")
    }

    /// A tap of Save that refused an entry says so beside the Save button, not only at the field it
    /// names. On a long form the field is scrolled out of sight by the time someone reaches the button,
    /// and a refusal with nothing next to it reads as a button that does nothing at all.
    func testSaveBlockedMessageNamesTheFieldsNextToSave() throws {
        let model = try makeModel(nil)

        // Nothing filled in at all: both problems are named together, so fixing one and tapping Save
        // again does not meet the same silent refusal.
        XCTAssertFalse(model.save(now: now))
        XCTAssertNotNil(model.saveBlockedMessage)
        XCTAssertEqual(model.saveBlockedMessage, model.nameError)
        XCTAssertEqual(model.saveBlockedMessage, model.amountError)

        // One field fixed leaves the other named, and the fixed one is not repeated.
        model.name = "Rolled oats"
        XCTAssertFalse(model.save(now: now))
        XCTAssertEqual(model.saveBlockedMessage, model.amountError)
        XCTAssertNil(model.nameError)

        // A save that succeeds clears it, so a stale refusal never follows a good entry.
        model.amountText = "40"
        XCTAssertTrue(model.save(now: now))
        XCTAssertNil(model.saveBlockedMessage)
    }

    /// A product the catalog lists but states no nutrition facts for is one sentence rather than a
    /// column of unknowns: the lookup worked, there is simply nothing on the record, and scanning the
    /// label is what would fill the form in.
    func testProductThatStatesNoNutrientsIsExplainedInOneSentence() async throws {
        let bare = LookedUpProduct(
            barcode: validBarcode, name: "Sample Bar", brand: "Example Foods", basis: .per100g,
            nutrients: [:], attribution: attribution, version: "2024-05-01")
        let model = try makeModel(FakeBarcodeLookup(result: .found(bare)))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertTrue(model.statesNoNutrients)
        XCTAssertEqual(AddIntakeViewModel.noStatedNutrientsMessage,
                       "Open Food Facts lists this product but states no nutrition facts; scan the label instead.")
        // The attribution still travels with it, whatever the values turned out to be.
        XCTAssertEqual(model.attribution?.text, attribution.text)
        // And the entry can still be saved: the person knows what they ate.
        model.amountText = "40"
        XCTAssertTrue(model.save(now: now))
    }

    /// A product that states even one nutrient is shown as rows, not as the "states nothing" sentence.
    func testProductThatStatesAnyNutrientIsStillShownAsRows() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .found(oatMilk())))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertFalse(model.statesNoNutrients)
        XCTAssertEqual(
            model.prefilledNutrients[LookedUpProduct.energyKcal], .known(Decimal(45), .kcal))
    }

    /// Nothing but a failed or empty lookup carries no product, so neither state can claim the
    /// "states no nutrition facts" sentence: a lookup that found nothing is a different message.
    func testNoProductMeansNoStatedNutrientsSentence() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .notFound))
        XCTAssertFalse(model.statesNoNutrients)

        model.barcode = validBarcode
        await model.lookUpBarcode()

        XCTAssertFalse(model.statesNoNutrients)
        XCTAssertEqual(
            model.lookupMessage, "No product found for that barcode. Fill in the details yourself.")
    }

    func testHandTypedEntryStoresNoProduct() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        model.name = "Rolled oats"
        model.amountText = "40"

        XCTAssertTrue(model.save(now: now))

        let intake = try XCTUnwrap(try store.activeIntakes().first)
        let revision = try XCTUnwrap(try store.revisions(of: intake.id).first)
        XCTAssertNil(revision.productSnapshotID)
    }

    // MARK: Missing values and no lookup at all

    func testNutrientMissingFromTheResultStaysUnknownNotZero() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .found(oatMilk())))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        for key in [LookedUpProduct.sugars, LookedUpProduct.fat, LookedUpProduct.saturatedFat,
                    LookedUpProduct.fiber, LookedUpProduct.sodium, LookedUpProduct.salt]
        {
            XCTAssertEqual(model.prefilledNutrients[key], .unknown, key)
        }
    }

    func testWithoutAnInjectedLookupTheFormOffersNoBarcode() async throws {
        let model = try makeModel(nil)
        XCTAssertFalse(model.canLookUpBarcode)
        model.barcode = validBarcode
        await model.lookUpBarcode()
        XCTAssertEqual(model.lookupState, .idle)
        XCTAssertNil(model.lookupMessage)
    }
}
