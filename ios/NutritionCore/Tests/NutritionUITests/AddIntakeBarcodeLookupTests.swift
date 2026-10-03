import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Returns canned results and records every barcode it was asked about, so a test can tell that an
/// invalid barcode never reached the lookup at all.
private final class FakeBarcodeLookup: BarcodeProductLookup, @unchecked Sendable {
    private let result: BarcodeLookupResult
    private(set) var requestedBarcodes: [String] = []

    init(result: BarcodeLookupResult) {
        self.result = result
    }

    func lookUp(barcode: String) async -> BarcodeLookupResult {
        requestedBarcodes.append(barcode)
        return result
    }
}

@MainActor
final class AddIntakeBarcodeLookupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// 13 digits with a correct check digit.
    private let validBarcode = "4006381333931"

    /// These tests never save, so the store is only there to satisfy the view model; a real store on
    /// a temporary file keeps the double honest if a test ever does save.
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

    private func oatMilk() -> LookedUpProduct {
        LookedUpProduct(
            barcode: validBarcode,
            name: "Oat drink",
            brand: "Example Foods",
            basis: .per100ml,
            nutrients: [
                LookedUpProduct.energyKcal: .known(Decimal(45), .kcal),
                LookedUpProduct.protein: .known(Decimal(string: "1.0")!, .g),
                LookedUpProduct.carbohydrates: .known(Decimal(string: "6.5")!, .g),
                // No sugar, fat, fiber, sodium or salt given: those stay unknown.
            ]
        )
    }

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

    func testRateLimitedShowsTryLaterMessage() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .rateLimited))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupState, .rateLimited)
        XCTAssertEqual(model.lookupMessage, "Too many lookups just now. Try again in a minute.")
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
    }

    func testFailedShowsFailureMessage() async throws {
        let model = try makeModel(FakeBarcodeLookup(result: .failed("offline")))
        model.barcode = validBarcode

        await model.lookUpBarcode()

        XCTAssertEqual(model.lookupState, .failed("offline"))
        XCTAssertEqual(model.lookupMessage, "The lookup did not finish. Try again in a moment.")
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
    }

    func testInvalidBarcodeMakesNoLookupCall() async throws {
        let lookup = FakeBarcodeLookup(result: .found(oatMilk()))
        let model = try makeModel(lookup)

        for text in ["", "   ", "123", "12345678901234", "400638133393x", "4 006381 333931"] {
            model.barcode = text
            await model.lookUpBarcode()
            XCTAssertEqual(model.lookupState, .invalidBarcode, text)
            XCTAssertEqual(
                model.lookupMessage, "A barcode has 8, 12 or 13 digits. Nothing was looked up.", text)
        }
        XCTAssertTrue(lookup.requestedBarcodes.isEmpty)
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
    }

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

    func testBarcodeIsTrimmedBeforeTheLookup() async throws {
        let lookup = FakeBarcodeLookup(result: .found(oatMilk()))
        let model = try makeModel(lookup)
        model.barcode = "  \(validBarcode) "

        await model.lookUpBarcode()

        XCTAssertEqual(lookup.requestedBarcodes, [validBarcode])
        XCTAssertEqual(model.barcode, validBarcode)
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
