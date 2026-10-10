import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// A recipe portion logged through `RecipeLogger` reaches the HealthKit plan with the nutrient scaled to the
/// logged amount, the same amount the day totals use. The recipe below holds 80 g of synthetic protein in
/// total, so its value per one unit of the yield follows from the yield alone.
final class RecipeBasisDeliveryTests: XCTestCase {
    private let intakeID = "2f8c4a10-6b3d-4e7f-9a51-0c2d3e4f5a6b"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// 800 g of an ingredient carrying 0.1 g of protein per gram: 80 g in the whole batch.
    private func batch(yield: RecipeYield) -> RecipeVersion {
        sampleVersion(
            ingredients: [sampleIngredient("synthetic-flour", amount: "800", perUnit: ["protein": .known(dec("0.1"), .g)])],
            yield: yield)
    }

    /// Logs one portion and returns the protein the journal totals and the HealthKit plan carry for it.
    private func deliveredProtein(
        yield: RecipeYield, portion: Decimal, portionUnit: MeasureUnit?
    ) async throws -> (totals: NutrientValue?, planned: Decimal?) {
        let journal = try makeJournal()
        try RecipeLogger.logPortion(
            store: journal, version: batch(yield: yield), portion: portion, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil, portionUnit: portionUnit)
        let recorded = try await JournalSnapshotTotals(store: journal).totals(intakeID: intakeID, revision: 1)
        let plan = HealthKitWritePlanner.plan(
            intakeID: intakeID, revision: 1, occurredAt: when, totals: recorded)
        let sync = HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "protein")
        return (recorded["protein"], plan.first { $0.syncIdentifier == sync }?.amount)
    }

    func testRecipePortionsWithATotalYieldReachTheHealthKitPlanScaledToTheLoggedAmount() async throws {
        let cases: [(yield: RecipeYield, portion: Decimal, unit: MeasureUnit?, expected: Decimal)] = [
            // 200 g of an 800 g batch is a quarter of its 80 g of protein, in a 0.8 kg yield.
            (.total(Quantity(value: dec("0.8"), unit: .kg)), dec("200"), .g, dec("20")),
            // 250 mL of a 1 L batch is a quarter of 80 g, so the basis unit converts the amount.
            (.total(Quantity(value: dec("1"), unit: .L)), dec("250"), .mL, dec("20")),
            // 40 g of a 500 g batch is 40 / 500 of 80 g.
            (.total(Quantity(value: dec("500"), unit: .g)), dec("40"), .g, dec("6.4")),
            // A serving yield already resolved; it must not change.
            (.servings(4), dec("1"), nil, dec("20")),
        ]
        for item in cases {
            let delivered = try await deliveredProtein(yield: item.yield, portion: item.portion, portionUnit: item.unit)
            XCTAssertEqual(
                delivered.totals, .known(item.expected, .g),
                "the journal totals for \(RecipeLogger.basisText(item.yield))")
            XCTAssertEqual(
                delivered.planned, item.expected,
                "the HealthKit plan for \(RecipeLogger.basisText(item.yield))")
        }
    }

    /// A basis the journal cannot resolve states no protein at all: the day and Health say nothing rather than
    /// the whole batch or a guess.
    func testAnUnresolvedBasisStatesNoProteinInTheTotalsOrThePlan() async throws {
        let journal = try makeJournal()
        let product = ProductDefinition(
            snapshotID: "synthetic-unresolved", productID: "synthetic-product", name: "Synthetic product",
            labelBasis: "Per mL; yield 1 L", catalogOrigin: "recipe_calculated", catalogVersion: "1",
            nutrients: ["protein": .known(dec("80"), .g)])
        try journal.create(
            Intake(id: intakeID, category: "recipe", occurredAt: when, timeZoneIdentifier: "UTC", meal: nil),
            components: [IntakeComponent(componentID: "portion", name: "Synthetic product", amount: dec("250"), unit: .mL)],
            product: product, now: when)

        let recorded = try await JournalSnapshotTotals(store: journal).totals(intakeID: intakeID, revision: 1)
        XCTAssertNil(recorded["protein"])
        let plan = HealthKitWritePlanner.plan(intakeID: intakeID, revision: 1, occurredAt: when, totals: recorded)
        let sync = HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "protein")
        XCTAssertFalse(plan.contains { $0.syncIdentifier == sync })
    }
}
