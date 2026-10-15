import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

/// Repeating a multi-food entry offers the whole combination as one serving of a snapshot whose values are
/// already scaled to what was logged. 24 fl oz and 8 fl oz of a drink stating its values per 710 mL scale
/// 1 g of carbohydrate to 1.33289147323943661971830985915492957746 g, 39 significant digits. The saved entry
/// has to read those values back, and repeating it again has to save.
@MainActor
final class RepeatReadBackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func template(in store: SwiftDataJournalStore) throws -> RepeatTemplate {
        let bottle = ProductDefinition(
            snapshotID: "snapshot-bottle", productID: "product-bottle", name: "Electrolyte drink",
            labelBasis: "per serving (710 mL)", catalogOrigin: "test", catalogVersion: "1",
            nutrients: [
                "energy": .known(10, .kcal), "carbohydrate": .known(1, .g), "sodium": .known(30, .mg),
            ])
        let components = [24, 8].map { ounces -> IntakeComponent in
            let stored = AddIntakeViewModel.storedMetric(amount: Decimal(ounces), unit: .flOz)
            return IntakeComponent(
                componentID: "drink-\(ounces)", name: "Electrolyte drink", amount: stored.amount, unit: stored.unit)
        }
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: components, product: bottle, now: now)
        return RepeatTemplate(
            displayName: "Electrolyte drink", category: "food", components: components,
            productSnapshotID: bottle.snapshotID)
    }

    /// Saves one repeat and returns the snapshot its entry reads back.
    private func saveRepeat(_ prefill: RepeatTemplate, in store: SwiftDataJournalStore) throws -> ProductDefinition? {
        let details = try AddHomeViewModel(store: store).makeDetails(prefill: prefill, now: now)
        let existing = Set(try store.activeIntakes().map(\.id))
        guard details.save(now: now) else { return nil }
        let intake = try XCTUnwrap(store.activeIntakes().first { !existing.contains($0.id) })
        let snapshotID = try XCTUnwrap(store.revisions(of: intake.id).first?.productSnapshotID)
        return try store.product(snapshotID: snapshotID)
    }

    func testARepeatedMultiFoodEntryReadsBackEveryValue() throws {
        let store = try makeStore()
        let saved = try XCTUnwrap(try saveRepeat(try template(in: store), in: store))
        for key in ["energy", "carbohydrate", "sodium"] {
            guard case .known(let amount, _) = saved.value(for: key) else {
                return XCTFail("\(key) did not read back")
            }
            XCTAssertNotNil(DecimalText.decode(DecimalText.encode(amount)), key)
        }
    }

    func testRepeatingTheSameCombinationAgainSaves() throws {
        let store = try makeStore()
        let prefill = try template(in: store)
        XCTAssertNotNil(try saveRepeat(prefill, in: store))
        XCTAssertNotNil(try saveRepeat(prefill, in: store), "the second save of the same repeat failed")
    }
}
