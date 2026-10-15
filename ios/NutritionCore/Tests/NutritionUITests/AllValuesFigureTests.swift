import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionJournal
@testable import NutritionProviders
@testable import NutritionUI

/// All values lists a product's own figures. A figure a label printed is shown exactly as printed; one that
/// carries more fraction digits than any label prints was worked out, and reads the way Today reads a total.
/// Two such figures reach All values: repeating a multi-food entry stores values already scaled to what it
/// logged, and a source can send a figure it computed itself, such as sodium worked out from salt.
@MainActor
final class AllValuesFigureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    // MARK: A repeated multi-food entry

    /// 24 fl oz and 8 fl oz of a drink whose label states a 710 mL serving, repeated: the form offers the two
    /// as one serving, with every value scaled to 946.352946 / 710 of the label's. Saving stores those values
    /// as the new entry's snapshot, so the entry's All values reads them too.
    func testARepeatedMultiFoodEntryListsItsValuesRounded() throws {
        let store = try makeStore()
        let bottle = ProductDefinition(
            snapshotID: "snapshot-bottle", productID: "product-bottle", name: "Electrolyte drink",
            labelBasis: "per serving (710 mL)", catalogOrigin: "test", catalogVersion: "1",
            nutrients: [
                "energy": .known(10, .kcal), "carbohydrate": .known(1, .g), "sodium": .known(30, .mg),
                "potassium": .unknown,
            ])
        let components = [24, 8].map { ounces -> IntakeComponent in
            let stored = AddIntakeViewModel.storedMetric(amount: Decimal(ounces), unit: .flOz)
            return IntakeComponent(
                componentID: "drink-\(ounces)", name: "Electrolyte drink", amount: stored.amount, unit: stored.unit)
        }
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: components, product: bottle, now: now)
        let template = RepeatTemplate(
            displayName: "Electrolyte drink", category: "food", components: components,
            productSnapshotID: bottle.snapshotID)

        let details = try AddHomeViewModel(store: store).makeDetails(prefill: template, now: now)
        guard case .known(let sodium, _) = details.prefilledValue(for: "sodium") else {
            return XCTFail("the repeat states no sodium")
        }
        XCTAssertNotEqual(DisplayRounding.rounded(sodium, fractionDigits: 10), sodium, "the value is the long quotient")
        XCTAssertEqual(AddIntakeView.text(for: details.prefilledValue(for: "sodium")), "40 mg")
        XCTAssertEqual(AddIntakeView.text(for: details.prefilledValue(for: "carbohydrate")), "1.3 g")
        XCTAssertEqual(AddIntakeView.text(for: details.prefilledValue(for: "energy")), "13 kcal")

        let existing = Set(try store.activeIntakes().map(\.id))
        XCTAssertTrue(details.save(now: now))
        let intake = try XCTUnwrap(store.activeIntakes().first { !existing.contains($0.id) })
        let revision = try XCTUnwrap(store.revisions(of: intake.id).first)
        let snapshotID = try XCTUnwrap(revision.productSnapshotID)
        let saved = try XCTUnwrap(try store.product(snapshotID: snapshotID))
        XCTAssertEqual(saved.value(for: "sodium"), details.prefilledValue(for: "sodium"), "the stored value is unchanged")
        // Only sodium is read back here: the scaled carbohydrate and energy carry 39 significant digits, which
        // the store writes but cannot read back (#380).
        let rows = EntryDetailViewModel.allValues(of: saved)
        XCTAssertEqual(rows.first { $0.key == "sodium" }?.amountText, "40 mg")
    }

    // MARK: A figure a source worked out

    /// Open Food Facts states sodium it worked out from salt with every digit of a binary float. The figure
    /// is read exactly, and All values lists it rounded, while the figures the source states plainly are
    /// listed as stated.
    func testAProviderFigureWithFloatDigitsIsListedRounded() async throws {
        let json = """
        {"code":"2000000000015","status":"success","result":{"id":"product_found"},
         "product":{"code":"2000000000015","product_name":"Sample Crackers","nutrition_data_per":"100g",
          "nutriments":{"proteins_100g":7.5,"salt_100g":0.1,"sodium_100g":0.0393700787401575,
                        "fat_100g":"0.000125"}}}
        """
        let client = OpenFoodFactsClient(
            environment: .production, transport: FixedResponse(body: Data(json.utf8)), appVersion: "1.0.0",
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, monotonic: { 5_000 })
        guard case .found(let product) = await client.lookup(barcode: "2000000000015") else {
            return XCTFail("the fixture is a found product")
        }
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.sodium], .known(decimal("0.0393700787401575"), .g))

        XCTAssertEqual(AddIntakeView.text(for: product.nutrients[OpenFoodFactsProduct.sodium]), "0.04 g")
        XCTAssertEqual(AddIntakeView.text(for: product.nutrients[OpenFoodFactsProduct.salt]), "0.1 g")
        XCTAssertEqual(AddIntakeView.text(for: product.nutrients[OpenFoodFactsProduct.protein]), "7.5 g")
        XCTAssertEqual(AddIntakeView.text(for: product.nutrients[OpenFoodFactsProduct.fat]), "0.000125 g")
        XCTAssertEqual(
            LookedUpProduct.shownText(product.nutrients[OpenFoodFactsProduct.sodium] ?? .unknown), "0.04 g")
    }

    // MARK: The rule

    /// Six fraction digits is as many as a stated figure carries; one more and the figure was worked out.
    func testSixFractionDigitsSeparateAStatedFigureFromAWorkedOutOne() {
        XCTAssertEqual(AmountDisplay.stated(decimal("1.25"), unit: .g).text, "1.25 g")
        XCTAssertEqual(AmountDisplay.stated(decimal("0.000123"), unit: .g).text, "0.000123 g")
        XCTAssertEqual(AmountDisplay.stated(decimal("107.728187875"), unit: .kcal).text, "108 kcal")
        XCTAssertEqual(AmountDisplay.stated(decimal("0.0000004"), unit: .mg).text, "< 0.01 mg")
        XCTAssertEqual(AmountDisplay.stated(0, unit: .mg).text, "0 mg")
    }

    /// The words stored with an entry, which snapshot ids are hashed from, keep every digit.
    func testTheStoredWordsKeepEveryDigit() {
        let long = decimal("39.986744197183098591549295774647887324")
        XCTAssertEqual(LookedUpProduct.describe(.known(long, .mg)), "39.986744197183098591549295774647887324 mg")
        XCTAssertEqual(LookedUpProduct.shownText(.known(long, .mg)), "40 mg")
    }
}

/// Answers every request with one body, so a lookup reads a fixture instead of the network.
private struct FixedResponse: OpenFoodFactsTransport {
    let body: Data

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
