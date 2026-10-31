import Foundation
import XCTest
import NutritionDomain
import NutritionJournal
import NutritionProviders
@testable import NutritionUI

/// A product picked from the shared catalog is frozen into the entry that logs it (#87, NF-11): a later version of the
/// same catalog product never rewrites a logged entry, and the catalog's public product ID never becomes a local ID.
final class CatalogVersionFreezeTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func catalogProduct(id: UUID, revision: String, name: String) -> CommunityProduct {
        .init(
            productID: id, representativeRevision: revision,
            product: .custom(.init(name: name, kind: .food, basis: .perServing, facts: [])),
            source: .init(productID: id, representativeRevision: revision, attribution: "Community"),
            verification: .init(status: .sharedUnverified),
            support: .init(distinctAccounts: "1", verificationThreshold: "3"), missingFacts: true, alternatives: [])
    }

    /// The catalog's public ID stays in the product's source, for attribution, and is never the local product ID or
    /// the snapshot's product ID.
    func testTheCatalogsPublicIDNeverBecomesALocalID() throws {
        let catalogID = UUID()
        let revision = try CustomProductMapping.importedRevision(
            from: catalogProduct(id: catalogID, revision: "1", name: "Synthetic bar"))
        let snapshot = try CustomProductMapping.snapshot(for: revision)
        XCTAssertNotEqual(revision.localProductID, catalogID)
        XCTAssertNotEqual(revision.revisionID, catalogID)
        XCTAssertNotEqual(snapshot.productID, catalogID.uuidString)
        XCTAssertNotEqual(snapshot.snapshotID, catalogID.uuidString)
        XCTAssertEqual(snapshot.productID, revision.localProductID.uuidString)
    }

    #if canImport(SwiftData)
    /// An entry logged from version 1 of a catalog product keeps version 1's snapshot after version 2 is imported.
    func testALoggedEntryKeepsTheVersionItWasLoggedWithWhenTheCatalogUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        // Closed on every path, before the folder is removed by the teardown above.
        defer { store.close() }
        let catalogID = UUID()

        let first = try CustomProductMapping.importedRevision(
            from: catalogProduct(id: catalogID, revision: "1", name: "Synthetic bar"))
        let firstSnapshot = try CustomProductMapping.snapshot(for: first)
        let intakeID = UUID().uuidString.lowercased()
        let intake = ProductIntakeDraft(
            intake: Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "portion", name: "Portion", amount: 1, unit: .serving)],
            snapshot: firstSnapshot)
        try store.saveCustomProduct(CustomProductSave(revision: first, intake: intake), now: when)

        // The catalog publishes version 2 under the same public ID, and the person imports it.
        let second = try CustomProductMapping.importedRevision(
            from: catalogProduct(id: catalogID, revision: "2", name: "Synthetic bar, new recipe"))
        try store.saveCustomProduct(CustomProductSave(revision: second), now: when.addingTimeInterval(60))
        let secondSnapshot = try CustomProductMapping.snapshot(for: second)

        XCTAssertNotEqual(secondSnapshot.snapshotID, firstSnapshot.snapshotID)
        XCTAssertNotEqual(intakeID, catalogID.uuidString.lowercased(), "the entry has its own ID")
        let revisions = try store.revisions(of: intakeID)
        XCTAssertEqual(revisions.map(\.productSnapshotID), [firstSnapshot.snapshotID], "the entry still names version 1")
        XCTAssertEqual(try store.product(snapshotID: firstSnapshot.snapshotID)?.name, "Synthetic bar")
    }
    #endif
}
