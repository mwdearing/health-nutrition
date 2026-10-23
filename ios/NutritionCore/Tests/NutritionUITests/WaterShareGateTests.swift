import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// #462: an entry with a volume amount and no product record can still have its water share set.
@MainActor
final class WaterShareGateTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    func testAVolumeEntryWithNoProductOffersTheWaterShare() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let entryID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: entryID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "soup", name: "Soup", amount: Decimal(250), unit: .mL)],
            product: nil, now: when)

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
        model.load(now: when)

        XCTAssertTrue(model.showsWaterShare)
    }

    /// A food in grams with no product does not offer the water share: only a volume amount does.
    func testAGramEntryWithNoProductDoesNotOfferTheWaterShare() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let entryID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: entryID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: Decimal(40), unit: .g)],
            product: nil, now: when)

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
        model.load(now: when)

        XCTAssertFalse(model.showsWaterShare)
    }

    /// A drink with a volume amount offers the water share, as it always has, whether or not it has a product.
    func testADrinkWithAVolumeAmountOffersTheWaterShare() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let entryID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: entryID, category: "drink", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "tea", name: "Tea", amount: Decimal(250), unit: .mL)],
            product: nil, now: when)

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
        model.load(now: when)

        XCTAssertTrue(model.showsWaterShare)
    }
}
