import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// #805: a typed supplement's undeclared nutrient contributes nothing to coverage, as a snapshot-backed one does.
@MainActor
final class SupplementUndeclaredTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    func testATypedSupplementsUndeclaredNutrientContributesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "supplement", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummy", name: "Gummy", amount: Decimal(1), unit: .g)],
            product: nil, now: when)
        let intakes = try store.activeIntakes()
        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: UnknownNutrientFacts(), nutrients: ["vitaminC"])
        let total = try XCTUnwrap(totals.total(for: "vitaminC"))
        // Totals do not change: no value is added, so the total is still unknown, as it is today.
        guard case .unknown = total.value else { return XCTFail("the total must stay unknown, as it is today") }
        // Coverage changes: the undeclared nutrient no longer makes the day's coverage unknown.
        XCTAssertFalse(total.coverage.hasUnknown, "an undeclared nutrient of a typed supplement must not make coverage unknown")
    }

    /// A supplement whose snapshot cannot be read is not taken for a typed one: the snapshot may declare the
    /// nutrient, so coverage stays unknown rather than looking complete.
    func testASupplementWhoseSnapshotCannotBeReadKeepsCoverageUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        try inner.create(
            Intake(id: UUID().uuidString.lowercased(), category: "supplement", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "multi", name: "Daily multi", amount: 1, unit: .tablet)],
            product: ProductDefinition(
                snapshotID: "snap-multi", productID: "test", name: "Daily multi",
                labelBasis: "per serving (1 tablet)", catalogOrigin: "test", catalogVersion: "unknown",
                kind: .supplement, nutrients: ["vitaminC": .known(90, .mg)]),
            now: when)
        let store = SnapshotReadFailingStore(inner: inner)
        store.failsProducts = true
        let totals = try DailyTotalsBuilder.totals(
            for: try inner.activeIntakes(), store: store, lookup: SnapshotNutrientFacts(), nutrients: ["vitaminC"])
        let total = try XCTUnwrap(totals.total(for: "vitaminC"))
        XCTAssertTrue(total.coverage.hasUnknown, "a supplement whose snapshot cannot be read must keep coverage unknown")
    }
}
