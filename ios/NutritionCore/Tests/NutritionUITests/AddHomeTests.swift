import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AddHomeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testMealPresetIsCarriedIntoEveryMethodsDetails() async throws {
        let home = AddHomeViewModel(store: try makeStore(), meal: .lunch)
        let typed = home.makeDetails(now: now)
        XCTAssertEqual(typed.meal, .lunch)
        let scanned = home.makeDetails(now: now)
        await home.scannedBarcode("4006381333931", into: scanned)
        XCTAssertEqual(scanned.meal, .lunch)
        let label = home.makeDetails(now: now)
        XCTAssertEqual(label.meal, .lunch)
        let template = RepeatTemplate(displayName: "Oats", category: "food", meal: "breakfast",
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)])
        let library = try home.makeDetails(prefill: template, now: now)
        XCTAssertEqual(library.meal, .lunch)
        XCTAssertEqual(library.amountText, "40")
        XCTAssertEqual(library.name, "Oats")
    }

    func testQuickAddFromRecentCanBeUndone() throws {
        let store = try makeStore()
        let seed = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        seed.name = "Oats"
        seed.amountText = "40"
        XCTAssertTrue(seed.save(now: now))
        let home = AddHomeViewModel(store: store, meal: .lunch, now: { self.now })
        home.load()
        let recent = try XCTUnwrap(home.recents.first)
        let token = try XCTUnwrap(home.quickAdd(recent))
        let added = try XCTUnwrap(store.activeIntakes().first { $0.id == token.intakeID })
        XCTAssertEqual(added.meal, "lunch")
        XCTAssertTrue(home.undo())
        XCTAssertFalse(try store.activeIntakes().contains { $0.id == token.intakeID })
        XCTAssertEqual(try store.activeIntakes().count, 1)
    }

    func testScannedBarcodeStartsTheLookupButTypingDoesNot() async throws {
        let home = AddHomeViewModel(store: try makeStore(), lookup: MissingProductLookup())
        let typed = home.makeDetails(now: now)
        typed.barcode = "4006381333931"
        XCTAssertEqual(typed.lookupState, .idle)
        let scanned = home.makeDetails(now: now)
        await home.scannedBarcode("4006381333931", into: scanned)
        XCTAssertEqual(scanned.lookupState, .notFound)
    }
}

private struct MissingProductLookup: BarcodeProductLookup {
    func lookUp(barcode: String) async -> BarcodeLookupResult { .notFound }
}
