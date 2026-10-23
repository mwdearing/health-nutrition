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
}
