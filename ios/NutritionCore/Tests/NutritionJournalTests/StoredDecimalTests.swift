import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// A 128-bit `Decimal` holds 39 significant digits when they start low, one more than the journal's decimal
/// text reads back. A value scaled by a factor that does not terminate can land there: (709.7647095 +
/// 236.5882365) / 710 of 1 g is 1.33289147323943661971830985915492957746 g, and a third of 40 kcal is
/// 13.3333333333333333333333333333333333332 kcal. The journal keeps what it writes readable.
final class StoredDecimalTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let first = "4d0f6a52-1c3b-4e7a-9b21-0c6d5e8f7a10"
    private let second = "7b2e9c41-5d6a-4f38-8e10-2a9c4b7d6e21"
    /// 39 significant digits, as a 128-bit `Decimal` holds them.
    private let thirtyNine = "1.33289147323943661971830985915492957746"
    /// The same value at 38 significant digits, rounded half away from zero.
    private let thirtyEight = "1.3328914732394366197183098591549295775"

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func drink(carbohydrate: Decimal) -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-drink", productID: "product-drink", name: "Electrolyte drink",
            labelBasis: "per serving", catalogOrigin: "test", catalogVersion: "1",
            nutrients: [
                "carbohydrate": .known(carbohydrate, .g),
                "sodium": .known(dec("39.986744197183098591549295774647887323"), .mg),
            ])
    }

    private func log(_ journal: SwiftDataJournalStore, _ product: ProductDefinition, id: String) throws {
        try journal.create(
            Intake(id: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "drink", name: "Electrolyte drink", amount: 1, unit: .serving)],
            product: product, now: when)
    }

    // MARK: The shape

    func testThirtyNineDigitsIsOneMoreThanTheTextReadsBack() {
        let value = dec(thirtyNine)
        XCTAssertEqual(DecimalText.encode(value), thirtyNine)
        XCTAssertNil(DecimalText.decode(DecimalText.encode(value)))
    }

    func testStorableRoundsOnlyAValueTheTextCannotReadBack() {
        XCTAssertEqual(StoredDecimal.storable(dec(thirtyNine)), dec(thirtyEight))
        XCTAssertNotNil(DecimalText.decode(DecimalText.encode(StoredDecimal.storable(dec(thirtyNine)))))
        let long = dec("39.986744197183098591549295774647887323")
        XCTAssertEqual(StoredDecimal.storable(long), long)
        XCTAssertEqual(StoredDecimal.storable(dec("5.2")), dec("5.2"))
        XCTAssertEqual(StoredDecimal.storable(0), 0)
        XCTAssertEqual(
            StoredDecimal.storable(dec("13.3333333333333333333333333333333333332")),
            dec("13.333333333333333333333333333333333333"))
    }

    /// At the top of `Decimal`'s range there is no room to round: the value is kept as it is, never turned
    /// into a zero, and a stored row holding it stays refused.
    func testAValueAtTheTopOfTheRangeIsNeverRoundedToZero() {
        let text = "340282366920938463463374607431768211455" + String(repeating: "0", count: 127)
        let top = dec(text)
        XCTAssertEqual(DecimalText.encode(top), text)
        XCTAssertEqual(StoredDecimal.storable(top), top)
        XCTAssertNil(StoredDecimal.readBack(text))
        XCTAssertNil(
            SwiftDataJournalStore.decodeNutrients(
                #"[{"id":"carbohydrate","state":"known","unitSymbol":"g","valueText":"\#(text)"}]"#)["carbohydrate"])
    }

    // MARK: The store

    /// A snapshot holding such a value reads back with it, rather than without it.
    func testASnapshotWithAThirtyNineDigitValueReadsItBack() throws {
        let journal = try makeJournal()
        try log(journal, drink(carbohydrate: dec(thirtyNine)), id: first)
        let read = try XCTUnwrap(try journal.product(snapshotID: "snapshot-drink"))
        XCTAssertEqual(read.value(for: "carbohydrate"), .known(dec(thirtyEight), .g))
        XCTAssertEqual(read.value(for: "sodium"), .known(dec("39.986744197183098591549295774647887323"), .mg))
    }

    /// Logging the same product again names the same snapshot, which is not a conflict.
    func testLoggingTheSameSnapshotAgainIsNotAConflict() throws {
        let journal = try makeJournal()
        try log(journal, drink(carbohydrate: dec(thirtyNine)), id: first)
        XCTAssertNoThrow(try log(journal, drink(carbohydrate: dec(thirtyNine)), id: second))
        XCTAssertEqual(try journal.activeIntakes().count, 2)
    }

    /// A row written before the journal kept its values readable holds every digit as text. It reads back
    /// rounded the same way, while text this app never writes stays refused.
    func testARowWrittenWithEveryDigitReadsBackRounded() {
        func stored(_ text: String) -> NutrientValue? {
            SwiftDataJournalStore.decodeNutrients(
                #"[{"id":"carbohydrate","state":"known","unitSymbol":"g","valueText":"\#(text)"}]"#)["carbohydrate"]
        }
        XCTAssertEqual(stored(thirtyNine), .known(dec(thirtyEight), .g))
        XCTAssertEqual(stored("5.2"), .known(dec("5.2"), .g))
        XCTAssertNil(stored("1.2.3"))
        XCTAssertNil(stored("1234567890123456789012345678901234567891"))
    }

    // MARK: A recipe

    /// A third of a 40 kcal recipe is a 39-digit serving. Logging it twice reads the value back both times
    /// under the version's one snapshot id.
    func testARecipeServingThatDoesNotDivideEvenlyReadsBackUnderOneSnapshot() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [sampleIngredient("oat-flour", amount: "40", perUnit: energyPerUnit("1"))],
            yield: .servings(3))
        for id in [first, second] {
            try RecipeLogger.logPortion(
                store: journal, version: version, portion: 1, now: when, id: id, timeZoneIdentifier: "UTC")
            XCTAssertEqual(try journal.revisions(of: id)[0].productSnapshotID, "recipe:recipe-1:v1")
        }
        let product = try XCTUnwrap(try journal.product(snapshotID: "recipe:recipe-1:v1"))
        XCTAssertEqual(product.value(for: "energy"), .known(dec("13.333333333333333333333333333333333333"), .kcal))
    }
}
