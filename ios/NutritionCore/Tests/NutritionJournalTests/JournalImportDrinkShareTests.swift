import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The version 7 export carries a drink's water share, and an import reads it back. A version 6 document
/// that carries the share is refused, because version 6 has no such field.
final class JournalImportDrinkShareTests: JournalImportTestCase {
    private func sourceWithDrink() throws -> SwiftDataJournalStore {
        let source = try store(directory())
        let drink = ProductDefinition(
            snapshotID: "snap-drink-share-import", productID: "product-drink-share", name: "Sample soda",
            brand: nil, barcode: nil, labelBasis: "per serving", catalogOrigin: "sample", catalogVersion: "1",
            kind: .drink)
        try source.create(
            Intake(id: oatsID, category: "other", occurredAt: base, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(
                componentID: "soda", name: "Sample soda", amount: 200, unit: .mL, hydrationPercent: 50)],
            product: drink, now: base)
        return source
    }

    private func exportedDrinkData() throws -> Data {
        let source = try sourceWithDrink()
        return try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: source, favorites: nil, appVersion: appVersion, exportedAt: exportedAt))
    }

    func testVersionSevenRoundTripsTheDrinkWaterShare() throws {
        let data = try exportedDrinkData()
        let target = try store(directory())

        _ = try JournalImporter.importExport(data, into: target, favorites: nil)

        let imported = try XCTUnwrap(try target.revisions(of: oatsID).last)
        let component = try XCTUnwrap(imported.components.first)
        XCTAssertEqual(component.hydrationPercent, 50)
        XCTAssertEqual(component.amount, 200)
    }

    func testVersionSixRefusesAFileThatCarriesTheShare() throws {
        var root = try object(of: try exportedDrinkData())
        root["schema_version"] = 6
        let data = try JSONSerialization.data(withJSONObject: root)
        let target = try store(directory())

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: target, favorites: nil))
    }
}
