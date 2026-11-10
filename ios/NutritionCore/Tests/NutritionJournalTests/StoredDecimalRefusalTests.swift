import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// A value no rounding can make readable is refused when it is written, not saved and then dropped on read.
final class StoredDecimalRefusalTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    func testAnUnstorableValueIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let journal = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let top = Decimal(string: "340282366920938463463374607431768211455" + String(repeating: "0", count: 127))!
        let product = ProductDefinition(
            snapshotID: "snapshot-big", productID: "product-big", name: "Large value",
            labelBasis: "per serving", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["carbohydrate": .known(top, .g)])
        let intake = Intake(
            id: "4d0f6a52-1c3b-4e7a-9b21-0c6d5e8f7a10", category: "food", occurredAt: when, timeZoneIdentifier: "UTC")
        XCTAssertThrowsError(try journal.create(
            intake, components: [IntakeComponent(componentID: "big", name: "Large value", amount: 1, unit: .serving)],
            product: product, now: when)
        ) { error in
            guard case JournalError.invalidAmount = error else {
                return XCTFail("expected invalidAmount, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty, "nothing was saved")
    }
}
