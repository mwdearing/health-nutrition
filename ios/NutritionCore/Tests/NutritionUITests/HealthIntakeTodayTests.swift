import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Today with an empty journal and nutrition from other apps in Health: the lines show Health's amounts.
@MainActor
final class HealthIntakeTodayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// No journal entries at all, Health reports energy and protein for the day: both show Health's amounts,
    /// as at least, because the journal side has nothing known.
    func testEmptyJournalShowsHealthEnergyAndProteinAsAtLeast() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.outsideIntake = .read(
            values: ["energy": 620, "protein": 48], readKeys: ["energy", "protein"])
        model.load(now: now)

        let energy = try XCTUnwrap(model.progress.first { $0.nutrient == "energy" })
        let protein = try XCTUnwrap(model.progress.first { $0.nutrient == "protein" })
        XCTAssertEqual(energy.knownSum, NutrientValue.known(620, HealthKitWritePlanner.mapping(for: "energy")!.unit))
        XCTAssertEqual(protein.knownSum, NutrientValue.known(48, HealthKitWritePlanner.mapping(for: "protein")!.unit))
        XCTAssertTrue(energy.isPartial)
        XCTAssertTrue(protein.isPartial)
    }

    /// Changing only the Health side and loading again changes Today's lines.
    func testChangingOnlyTheHealthSideReloadsTheLines() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertFalse(model.progress.contains { $0.nutrient == "energy" && $0.knownSum != nil })

        model.outsideIntake = .read(values: ["energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertEqual(model.progress.first { $0.nutrient == "energy" }?.knownSum,
                       NutrientValue.known(620, HealthKitWritePlanner.mapping(for: "energy")!.unit))
    }
}
