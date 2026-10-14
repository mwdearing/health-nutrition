import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The component id a food the user names is saved under. An ordinary food keeps its slug, but a name whose
/// slug the intake-context catalog reserves is namespaced, so "Caffeine" or "Energy blend" stays a food and
/// does not take the catalog's nutrient or blend. Water poured by volume is the one food the catalog row
/// describes exactly, so it keeps the catalog id.
@MainActor
final class AddIntakeComponentIDTests: XCTestCase {
    func testAnOrdinaryFoodKeepsItsSlug() {
        XCTAssertEqual(AddIntakeViewModel.componentID(forFoodNamed: "Oats", unit: .g), "oats")
    }

    func testReservedNamesAreNamespacedSoTheFoodKeepsItsOwnMeaning() {
        XCTAssertEqual(AddIntakeViewModel.componentID(forFoodNamed: "Caffeine", unit: .mg), "food-caffeine")
        XCTAssertEqual(AddIntakeViewModel.componentID(forFoodNamed: "Energy blend", unit: .g), "food-energy-blend")
        XCTAssertEqual(AddIntakeViewModel.componentID(forFoodNamed: "Protein", unit: .g), "food-protein")
        XCTAssertEqual(AddIntakeViewModel.componentID(forFoodNamed: "Water", unit: .g), "food-water")
    }

    func testANameTheEntrysOwnSnapshotStatesIsNamespaced() {
        XCTAssertEqual(
            AddIntakeViewModel.componentID(forFoodNamed: "Collagen", unit: .g, snapshotNutrientKeys: ["collagen"]),
            "food-collagen", "the snapshot's collagen fact keeps its id")
        XCTAssertEqual(
            AddIntakeViewModel.componentID(forFoodNamed: "Collagen", unit: .g), "collagen",
            "without a snapshot stating it, an ordinary name keeps its slug")
    }

    func testWaterPouredByVolumeKeepsTheCatalogID() {
        XCTAssertEqual(AddIntakeViewModel.componentID(forFoodNamed: "Water", unit: .mL), "water")
    }

    func testANamespacedIDIsAValidComponentIDWithinTheSchemaLimit() {
        let id = AddIntakeViewModel.componentID(forFoodNamed: "Energy blend", unit: .g)
        XCTAssertTrue(JournalValidation.isValidComponentID(id))
        XCTAssertLessThanOrEqual(id.count, 64)
    }

    func testTheCatalogReservesItsRowsAndTheSlugsOfStatedNutrients() {
        for id in ["water", "caffeine", "energy-blend", "protein", "energy", "vitamin-d"] {
            XCTAssertTrue(IntakeContextFactCatalog.isReserved(componentID: id), id)
        }
        XCTAssertFalse(IntakeContextFactCatalog.isReserved(componentID: "oats"))
    }
}
