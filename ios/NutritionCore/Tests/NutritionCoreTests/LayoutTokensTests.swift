import XCTest
@testable import NutritionCore

/// The color roles of the branded-hero layout: exact values, and the contrast each pairing needs.
final class LayoutTokensTests: XCTestCase {
    private let expected: [(String, String, String)] = [
        ("page", "#F2F2F7", "#07222E"),
        ("card", "#FFFFFF", "#0B3D4A"),
        ("hero", "#07222E", "#11505F"),
        ("heroText", "#FFFFFF", "#FFFFFF"),
        ("heroSecondaryText", "#9FC5CC", "#9FC5CC"),
        ("heroTrack", "#17464C", "#1F6C74"),
        ("macroProtein", "#0F6B78", "#5EEAD4"),
        ("macroCarbs", "#B45309", "#FBBF24"),
        ("macroFat", "#2563EB", "#93B4FF"),
    ]

    private func token(_ name: String) throws -> Token {
        guard let found = NutritionTokens.token(named: name) else {
            XCTFail("missing token \(name)")
            throw TokenError.malformedHex(name)
        }
        return found
    }

    func testLayoutRolesAreDeclaredWithTheirExactValues() throws {
        XCTAssertEqual(NutritionTokens.layout.map(\.name), expected.map { $0.0 })
        for (name, light, dark) in expected {
            let found = try token(name)
            XCTAssertEqual(found.light.hex, light, "\(name) light")
            XCTAssertEqual(found.dark.hex, dark, "\(name) dark")
            XCTAssertEqual(try RGB(hex: found.lightHex), found.light, "\(name) light text")
            XCTAssertEqual(try RGB(hex: found.darkHex), found.dark, "\(name) dark text")
        }
        let all = NutritionTokens.audited + NutritionTokens.semantic + NutritionTokens.design + NutritionTokens.layout
        let names = all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testEarlierTablesAreUnchanged() {
        XCTAssertEqual(NutritionTokens.audited.count, 11)
        XCTAssertEqual(NutritionTokens.semantic.count, 9)
        XCTAssertEqual(NutritionTokens.design.count, 2)
    }

    func testHeroTextMeetsContrastOnHero() throws {
        let hero = try token("hero")
        for name in ["heroText", "heroSecondaryText"] {
            let text = try token(name)
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(text.light, hero.light), 4.5, "\(name) light")
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(text.dark, hero.dark), 4.5, "\(name) dark")
        }
    }

    func testFillsOnHeroMeetThreeToOne() throws {
        let hero = try token("hero")
        let fills = [
            try token("RelayMint").light, try token("macroProtein").dark,
            try token("macroCarbs").dark, try token("macroFat").dark,
        ]
        for fill in fills {
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fill, hero.light), 3, "\(fill.hex) on the light hero")
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fill, hero.dark), 3, "\(fill.hex) on the dark hero")
        }
    }

    func testMacroColorsMeetThreeToOneOnCard() throws {
        let card = try token("card")
        for name in ["macroProtein", "macroCarbs", "macroFat"] {
            let fill = try token(name)
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fill.light, card.light), 3, "\(name) light")
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fill.dark, card.dark), 3, "\(name) dark")
        }
    }

    func testTextRolesMeetContrastOnPageAndCard() throws {
        for ground in ["page", "card"] {
            let background = try token(ground)
            for name in ["textPrimary", "textSecondary", "accent", "success", "warning", "error"] {
                let text = try token(name)
                XCTAssertGreaterThanOrEqual(
                    RGB.contrastRatio(text.light, background.light), 4.5, "\(name) light on \(ground)")
                XCTAssertGreaterThanOrEqual(
                    RGB.contrastRatio(text.dark, background.dark), 4.5, "\(name) dark on \(ground)")
            }
        }
    }

    func testDarkHeroStandsApartFromDarkCard() throws {
        let hero = try token("hero")
        let card = try token("card")
        XCTAssertNotEqual(hero.dark, card.dark)
        XCTAssertGreaterThanOrEqual(RGB.contrastRatio(hero.dark, card.dark), 1.2)
    }
}
