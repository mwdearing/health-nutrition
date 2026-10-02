import XCTest
@testable import NutritionCore

final class NutritionTokensTests: XCTestCase {
    private let roles = ["background", "surface", "border", "textPrimary", "textSecondary", "accent", "success", "warning", "error"]

    private func token(_ name: String) throws -> Token {
        guard let found = NutritionTokens.token(named: name) else {
            XCTFail("missing token \(name)")
            throw TokenError.malformedHex(name)
        }
        return found
    }

    private func rgb(_ hex: String) throws -> RGB {
        try RGB(hex: hex)
    }

    func testAuditedTokensMatchHealthRelayValues() throws {
        XCTAssertEqual(NutritionTokens.audited.count, 11)
        let expected: [(String, String, String)] = [
            ("AccentColor", "#0F6B78", "#5EEAD4"),
            ("RelayAccentInk", "#0B3D4A", "#5EEAD4"),
            ("RelayMint", "#5EEAD4", "#5EEAD4"),
            ("RelayOnMint", "#07222E", "#07222E"),
            ("RelayReadyInk", "#14592A", "#A6E8B8"),
            ("RelayReadyTint", "#D6F2DE", "#14331E"),
            ("RelayWaitingInk", "#7A3E00", "#FFCB94"),
            ("RelayWaitingTint", "#FFE6CC", "#3A2610"),
            ("RelayFailedInk", "#8A1C14", "#FFB3AB"),
            ("RelayFailedTint", "#FFDCD8", "#3D1512"),
            ("RelaySecondaryText", "#6C6C70", "#AEAEB2"),
        ]
        for (name, light, dark) in expected {
            let found = try token(name)
            XCTAssertEqual(found.light.hex, light, "\(name) light")
            XCTAssertEqual(found.dark.hex, dark, "\(name) dark")
        }
        XCTAssertEqual(try token("AccentColor").light, try rgb("#0F6B78"))
        XCTAssertEqual(try token("RelayMint").dark, try rgb("#5EEAD4"))
        XCTAssertEqual(try token("RelayOnMint").light, try rgb("#07222E"))
    }

    func testEveryRoleHasLightAndDarkValue() throws {
        XCTAssertEqual(NutritionTokens.semantic.count, roles.count)
        for role in roles {
            let found = NutritionTokens.semantic.first { $0.name == role }
            XCTAssertNotNil(found, "missing role \(role)")
        }
        XCTAssertNotEqual(try token("background").light, try token("background").dark)
        XCTAssertNotEqual(try token("surface").light, try token("surface").dark)
        XCTAssertNotEqual(try token("textPrimary").light, try token("textPrimary").dark)
        XCTAssertNotEqual(try token("border").light, try token("border").dark)
    }

    func testHexValuesAreSixDigitOpaque() throws {
        for item in NutritionTokens.audited + NutritionTokens.semantic {
            let lightText = item.light.hex
            let darkText = item.dark.hex
            XCTAssertEqual(lightText.count, 7, "\(item.name) light")
            XCTAssertEqual(darkText.count, 7, "\(item.name) dark")
            XCTAssertTrue(lightText.hasPrefix("#"))
            XCTAssertEqual(try rgb(lightText), item.light)
            XCTAssertEqual(try rgb(darkText), item.dark)
        }
        XCTAssertEqual(try rgb("#0a0b0c").hex, "#0A0B0C")
        XCTAssertEqual(RGB(red: 1, green: 2, blue: 3).hex, "#010203")
        XCTAssertThrowsError(try RGB(hex: "FFFFFF"))
        XCTAssertThrowsError(try RGB(hex: "#FFFFF"))
        XCTAssertThrowsError(try RGB(hex: "#FFFFFFFF"))
        XCTAssertThrowsError(try RGB(hex: "#GGGGGG"))
        XCTAssertThrowsError(try RGB(hex: "#+1+1+1"))
        XCTAssertThrowsError(try RGB(hex: ""))
    }

    func testTextRolesMeetContrastOnBackgroundAndSurface() throws {
        let background = try token("background")
        let surface = try token("surface")
        let foregrounds = ["textPrimary", "textSecondary", "accent", "success", "warning", "error"]
        for name in foregrounds {
            let fg = try token(name)
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fg.light, background.light), 4.5, "\(name) light on background")
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fg.dark, background.dark), 4.5, "\(name) dark on background")
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fg.light, surface.light), 4.5, "\(name) light on surface")
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fg.dark, surface.dark), 4.5, "\(name) dark on surface")
        }
        let pairs = [
            ("RelayReadyInk", "RelayReadyTint"),
            ("RelayWaitingInk", "RelayWaitingTint"),
            ("RelayFailedInk", "RelayFailedTint"),
            ("RelayOnMint", "RelayMint"),
        ]
        for (ink, fill) in pairs {
            let fg = try token(ink)
            let bg = try token(fill)
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fg.light, bg.light), 4.5, "\(ink) light")
            XCTAssertGreaterThanOrEqual(RGB.contrastRatio(fg.dark, bg.dark), 4.5, "\(ink) dark")
        }
    }

    func testSemanticStatusRolesMapToAuditedInks() throws {
        XCTAssertEqual(try token("accent"), Token(name: "accent", light: try token("AccentColor").light, dark: try token("AccentColor").dark))
        XCTAssertEqual(try token("textSecondary").light, try token("RelaySecondaryText").light)
        XCTAssertEqual(try token("textSecondary").dark, try token("RelaySecondaryText").dark)
        XCTAssertEqual(try token("success").light, try token("RelayReadyInk").light)
        XCTAssertEqual(try token("success").dark, try token("RelayReadyInk").dark)
        XCTAssertEqual(try token("warning").light, try token("RelayWaitingInk").light)
        XCTAssertEqual(try token("warning").dark, try token("RelayWaitingInk").dark)
        XCTAssertEqual(try token("error").light, try token("RelayFailedInk").light)
        XCTAssertEqual(try token("error").dark, try token("RelayFailedInk").dark)
    }

    func testContrastRatioKnownValues() throws {
        XCTAssertEqual(RGB.contrastRatio(try rgb("#07222E"), try rgb("#5EEAD4")), 11.1, accuracy: 0.1)
        XCTAssertEqual(RGB.contrastRatio(try rgb("#FFFFFF"), try rgb("#FFFFFF")), 1.0, accuracy: 0.0001)
        XCTAssertEqual(RGB.contrastRatio(try rgb("#000000"), try rgb("#FFFFFF")), 21.0, accuracy: 0.0001)
        XCTAssertEqual(RGB.contrastRatio(try rgb("#FFFFFF"), try rgb("#000000")), 21.0, accuracy: 0.0001)
        XCTAssertEqual(RGB.contrastRatio(try rgb("#5EEAD4"), try rgb("#FFFFFF")), 1.48, accuracy: 0.01)
        XCTAssertEqual(RGB.contrastRatio(try rgb("#6C6C70"), try rgb("#FFFFFF")), 5.23, accuracy: 0.01)
        XCTAssertEqual(try rgb("#FFFFFF").relativeLuminance, 1.0, accuracy: 0.0001)
        XCTAssertEqual(try rgb("#000000").relativeLuminance, 0.0, accuracy: 0.0001)
    }

    func testEveryDeclaredHexLiteralParsesAndRoundTrips() throws {
        for item in NutritionTokens.audited + NutritionTokens.semantic {
            for (label, text) in [("light", item.lightHex), ("dark", item.darkHex)] {
                let parsed = try RGB(hex: text)
                XCTAssertEqual(parsed.hex, text.uppercased(), "\(item.name) \(label)")
            }
            XCTAssertEqual(item.light, try RGB(hex: item.lightHex), "\(item.name) light stored value")
            XCTAssertEqual(item.dark, try RGB(hex: item.darkHex), "\(item.name) dark stored value")
        }
        let broken = Token(name: "broken", light: "#12345", dark: "#ZZZZZZ")
        XCTAssertThrowsError(try RGB(hex: broken.lightHex))
        XCTAssertThrowsError(try RGB(hex: broken.darkHex))
    }

    func testTokenNamesAreUnique() {
        let names = (NutritionTokens.audited + NutritionTokens.semantic).map { $0.name }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 20)
        XCTAssertFalse(names.contains(""))
    }

    func testLightBackgroundIsWhite() throws {
        XCTAssertEqual(try token("background").light, RGB(red: 255, green: 255, blue: 255))
        XCTAssertEqual(try token("background").light.hex, "#FFFFFF")
    }
}
