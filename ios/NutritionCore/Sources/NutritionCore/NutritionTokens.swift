import Foundation

/// Errors thrown when a hex color string is malformed.
public enum TokenError: Error, Sendable, Equatable {
    case malformedHex(String)
}

/// An opaque sRGB color with 8-bit channels.
public struct RGB: Sendable, Equatable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses "#RRGGBB" (exactly six hex digits after the hash). Throws on anything else.
    public init(hex: String) throws {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == 35 else {
            throw TokenError.malformedHex(hex)
        }
        var channels: [UInt8] = []
        var index = 1
        while index < 7 {
            guard let high = RGB.hexValue(bytes[index]), let low = RGB.hexValue(bytes[index + 1]) else {
                throw TokenError.malformedHex(hex)
            }
            channels.append(high * 16 + low)
            index += 2
        }
        self.init(red: channels[0], green: channels[1], blue: channels[2])
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func twoDigits(_ value: UInt8) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }

    /// Upper-case "#RRGGBB".
    public var hex: String {
        "#" + RGB.twoDigits(red) + RGB.twoDigits(green) + RGB.twoDigits(blue)
    }

    private static func linear(_ channel: UInt8) -> Double {
        let value = Double(channel) / 255.0
        if value <= 0.03928 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.x relative luminance, 0 (black) to 1 (white).
    public var relativeLuminance: Double {
        0.2126 * RGB.linear(red) + 0.7152 * RGB.linear(green) + 0.0722 * RGB.linear(blue)
    }

    /// WCAG 2.x contrast ratio, 1 to 21. Symmetric in its arguments.
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let first = a.relativeLuminance
        let second = b.relativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// A named color with a light and a dark appearance.
public struct Token: Sendable, Equatable {
    public let name: String
    public let light: RGB
    public let dark: RGB
    /// The "#RRGGBB" text the token was declared with (upper-case when built from RGB values).
    public let lightHex: String
    public let darkHex: String

    public init(name: String, light: RGB, dark: RGB) {
        self.name = name
        self.light = light
        self.dark = dark
        self.lightHex = light.hex
        self.darkHex = dark.hex
    }

    /// Takes "#RRGGBB" strings. A malformed string becomes black here, but the original text is
    /// kept in `lightHex` / `darkHex`, and the tests re-parse every declared string with the
    /// throwing `RGB(hex:)`, so a typo in the table fails the tests instead of shipping.
    public init(name: String, light: String, dark: String) {
        let black = RGB(red: 0, green: 0, blue: 0)
        self.name = name
        self.light = (try? RGB(hex: light)) ?? black
        self.dark = (try? RGB(hex: dark)) ?? black
        self.lightHex = light
        self.darkHex = dark
    }
}

/// Design tokens as plain data. The app maps them to platform colors later.
public enum NutritionTokens: Sendable {
    /// The 11 audited values. Never change these.
    public static let audited: [Token] = [
        Token(name: "AccentColor", light: "#0F6B78", dark: "#5EEAD4"),
        Token(name: "RelayAccentInk", light: "#0B3D4A", dark: "#5EEAD4"),
        Token(name: "RelayMint", light: "#5EEAD4", dark: "#5EEAD4"),
        Token(name: "RelayOnMint", light: "#07222E", dark: "#07222E"),
        Token(name: "RelayReadyInk", light: "#14592A", dark: "#A6E8B8"),
        Token(name: "RelayReadyTint", light: "#D6F2DE", dark: "#14331E"),
        Token(name: "RelayWaitingInk", light: "#7A3E00", dark: "#FFCB94"),
        Token(name: "RelayWaitingTint", light: "#FFE6CC", dark: "#3A2610"),
        Token(name: "RelayFailedInk", light: "#8A1C14", dark: "#FFB3AB"),
        Token(name: "RelayFailedTint", light: "#FFDCD8", dark: "#3D1512"),
        Token(name: "RelaySecondaryText", light: "#6C6C70", dark: "#AEAEB2"),
    ]

    /// Semantic roles. accent, textSecondary, success, warning and error reuse audited values.
    public static let semantic: [Token] = [
        Token(name: "background", light: "#FFFFFF", dark: "#07222E"),
        Token(name: "surface", light: "#F2F2F7", dark: "#0B3D4A"),
        Token(name: "border", light: "#D1D5DB", dark: "#1F5663"),
        Token(name: "textPrimary", light: "#111827", dark: "#F0F6FC"),
        Token(name: "textSecondary", light: "#6C6C70", dark: "#AEAEB2"),
        Token(name: "accent", light: "#0F6B78", dark: "#5EEAD4"),
        Token(name: "success", light: "#14592A", dark: "#A6E8B8"),
        Token(name: "warning", light: "#7A3E00", dark: "#FFCB94"),
        Token(name: "error", light: "#8A1C14", dark: "#FFB3AB"),
    ]

    /// Colors the design adds for bars and tags. Proposed like the semantic roles above, and kept in
    /// their own list so the audited and semantic tables stay exactly as they were approved.
    public static let design: [Token] = [
        Token(name: "track", light: "#DCE7E9", dark: "#1F5663"),
        Token(name: "accentTint", light: "#E3F1F0", dark: "#134B58"),
    ]

    /// Looks a token up by name in all three lists.
    public static func token(named name: String) -> Token? {
        (audited + semantic + design).first { $0.name == name }
    }
}
