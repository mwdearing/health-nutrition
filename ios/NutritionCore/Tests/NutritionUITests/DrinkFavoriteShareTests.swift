import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A favorite keeps a drink's water share, so repeating it from Favorites logs the share it was saved with,
/// and a favorite saved before shares existed repeats with no share (the 90 percent default).
final class DrinkFavoriteShareTests: XCTestCase {
    func testAFavoriteRepeatsWithTheShareItWasSavedWith() throws {
        let favorite = FavoriteTemplate(
            id: "fav-soda-share", displayName: "7up", category: "other",
            components: [FavoriteComponent(
                componentID: "soda", name: "7up", amountText: "200", unitSymbol: "mL",
                hydrationPercentText: "95")])

        let repeated = try XCTUnwrap(RepeatTemplate(favorite: favorite))

        XCTAssertEqual(repeated.components.first?.hydrationPercent, 95)
    }

    func testAFavoriteSavedBeforeSharesRepeatsWithNoShare() throws {
        let favorite = FavoriteTemplate(
            id: "fav-soda-old", displayName: "Old soda", category: "other",
            components: [FavoriteComponent(
                componentID: "soda", name: "Old soda", amountText: "200", unitSymbol: "mL")])

        let repeated = try XCTUnwrap(RepeatTemplate(favorite: favorite))

        XCTAssertNil(repeated.components.first?.hydrationPercent)
    }
}
