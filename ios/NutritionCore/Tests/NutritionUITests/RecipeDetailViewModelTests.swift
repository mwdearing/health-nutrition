import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class RecipeDetailViewModelTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"

    private func makeJournal() throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: try uiTempURL(self, "journal.store"))
    }

    func testPerServingRowsAndProvenance() throws {
        let model = RecipeDetailViewModel(version: uiSampleVersion(), journal: try makeJournal())
        XCTAssertEqual(model.rows.first(where: { $0.id == "energy" })?.text, "215 kcal")
        XCTAssertEqual(model.provenanceText, "Calculated from version 1")
    }

    func testUnknownShownAsUnknownNotZero() throws {
        let version = uiSampleVersion(perUnitB: ["energy": .known(8, .kcal)])
        let model = RecipeDetailViewModel(version: version, journal: try makeJournal())
        let protein = model.rows.first(where: { $0.id == "protein" })
        XCTAssertEqual(protein?.text, "unknown")
        XCTAssertEqual(model.coverageTexts, ["1 of 2 ingredients lack protein"])
    }

    func testPortionChangeRecalculatesAndBadPortionShowsError() throws {
        let model = RecipeDetailViewModel(version: uiSampleVersion(), journal: try makeJournal())
        model.portionText = "2"
        XCTAssertEqual(model.rows.first(where: { $0.id == "energy" })?.text, "430 kcal")
        model.portionText = "0"
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLogPortionWritesOneIntake() throws {
        let journal = try makeJournal()
        let model = RecipeDetailViewModel(
            version: uiSampleVersion(), journal: journal, timeZoneIdentifier: "UTC", makeID: { self.intakeID })
        XCTAssertTrue(model.logPortion(now: when))
        XCTAssertEqual(try journal.activeIntakes().count, 1)
        XCTAssertEqual(try journal.revisions(of: intakeID)[0].productSnapshotID, "recipe:recipe-1:v1")
    }

    func testCoverageLineTextHelper() {
        let line = RecipeCoverage(nutrientID: "protein", lacking: 1, total: 3)
        XCTAssertEqual(line.text(nutrientName: "protein"), "1 of 3 ingredients lack protein")
    }
}
