import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Answers with a product built for whatever barcode it was asked about, so a test can look a code
/// up, scan a different one, and look that one up too.
private final class EchoBarcodeLookup: BarcodeProductLookup, @unchecked Sendable {
    private let resultForBarcode: (String) -> BarcodeLookupResult

    init(resultForBarcode: @escaping (String) -> BarcodeLookupResult) {
        self.resultForBarcode = resultForBarcode
    }

    func lookUp(barcode: String) async -> BarcodeLookupResult { resultForBarcode(barcode) }
}

/// A scanned code is a new code, and every value on the form has to belong to it. A scan that only
/// wrote the field would keep the previous product's name, nutrients and snapshot, so the save that
/// follows would store one product's values under another product's barcode.
///
/// Every barcode below is invented, with the check digit computed from the digits before it.
@MainActor
final class ScannedBarcodeLookupStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let scanned = "200987654320"

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

    private let attribution = ProductAttribution(
        source: "example-catalog", text: "Nutrition facts from Example Foods, under CC BY-SA.",
        url: "https://example.invalid/foods")

    private func product(barcode: String) -> LookedUpProduct {
        LookedUpProduct(
            barcode: barcode,
            name: "Oat drink",
            brand: "Example Foods",
            basis: .perServing,
            nutrients: [
                LookedUpProduct.energyKcal: .known(Decimal(45), .kcal),
                LookedUpProduct.protein: .known(Decimal(1), .g),
            ],
            attribution: attribution,
            serving: ServingDefinition(quantity: Decimal(30), unit: .g, text: "30 g"),
            version: "2024-05-01"
        )
    }

    /// A looked-up product fills the form. Everything the source gave is on it.
    private func makeLookedUpForm() async throws -> AddIntakeViewModel {
        let first = "2001234567893"
        let model = try makeModel(EchoBarcodeLookup { barcode in .found(self.product(barcode: barcode)) })
        model.barcode = first
        await model.lookUpBarcode()
        return model
    }

    /// Scanning a different code takes the previous product's values, its attribution and its
    /// snapshot off the form, exactly as a lookup that finds nothing does.
    func testScanOfANewCodeClearsTheLookedUpProduct() async throws {
        let model = try await makeLookedUpForm()
        XCTAssertNotNil(model.lookedUp)

        model.setScannedBarcode(scanned)

        XCTAssertEqual(model.barcode, scanned)
        XCTAssertNil(model.lookedUp)
        XCTAssertNil(model.lookupBasis)
        XCTAssertNil(model.serving)
        XCTAssertNil(model.attribution)
        XCTAssertTrue(model.prefilledNutrients.isEmpty)
        XCTAssertEqual(model.name, "")
        XCTAssertEqual(model.brand, "")
        XCTAssertEqual(model.lookupState, .idle)
    }

    /// The message of the lookup that filled the form goes with it: it would otherwise claim the
    /// form was filled in from a barcode that is no longer on screen.
    func testScanOfANewCodeClearsTheLookupMessage() async throws {
        let model = try await makeLookedUpForm()
        XCTAssertNotNil(model.lookupMessage)

        model.setScannedBarcode(scanned)

        XCTAssertNil(model.lookupMessage)
    }

    /// A name or brand the user typed over the looked-up one is theirs, and a scan leaves it alone.
    func testScanKeepsFieldsTheUserEdited() async throws {
        let model = try await makeLookedUpForm()
        model.name = "My own name"

        model.setScannedBarcode(scanned)

        XCTAssertEqual(model.name, "My own name")
        XCTAssertNil(model.lookedUp)
    }

    /// Scanning the code already on the field changes nothing, so a user who rescans the same package
    /// keeps the values that code filled in.
    func testScanOfTheSameCodeKeepsTheLookedUpProduct() async throws {
        let model = try await makeLookedUpForm()
        let code = model.barcode

        model.setScannedBarcode(code)

        XCTAssertEqual(model.barcode, code)
        XCTAssertNotNil(model.lookedUp)
        XCTAssertEqual(model.name, "Oat drink")
    }

    /// Whitespace around a scanned code is trimmed, as it is for a typed one, and the trimmed code is
    /// what the form then holds.
    func testScanTrimsWhitespace() async throws {
        let model = try await makeLookedUpForm()

        model.setScannedBarcode("  \(scanned)\n")

        XCTAssertEqual(model.barcode, scanned)
        XCTAssertNil(model.lookedUp)
    }

    /// The scanned code is a real barcode, so the user can look it up straight away, and the form
    /// then holds that product's values.
    func testScannedCodeCanBeLookedUp() async throws {
        let model = try await makeLookedUpForm()

        model.setScannedBarcode(scanned)
        await model.lookUpBarcode()

        XCTAssertEqual(model.barcode, scanned)
        XCTAssertEqual(model.lookedUp?.barcode, scanned)
        XCTAssertEqual(model.name, "Oat drink")
    }
}
