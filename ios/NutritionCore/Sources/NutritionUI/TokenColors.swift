import NutritionCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The only place that turns design-token values into SwiftUI colors.
/// Every other file in this target uses the named accessors below.
public enum TokenColors {
    public static var accent: Color { color(named: "accent") }
    public static var background: Color { color(named: "background") }
    public static var surface: Color { color(named: "surface") }
    public static var border: Color { color(named: "border") }
    public static var textPrimary: Color { color(named: "textPrimary") }
    public static var textSecondary: Color { color(named: "textSecondary") }
    public static var success: Color { color(named: "success") }
    public static var warning: Color { color(named: "warning") }
    public static var error: Color { color(named: "error") }
    public static var mint: Color { color(named: "RelayMint") }
    public static var onMint: Color { color(named: "RelayOnMint") }
    public static var accentInk: Color { color(named: "RelayAccentInk") }
    public static var waitingTint: Color { color(named: "RelayWaitingTint") }
    public static var waitingInk: Color { color(named: "RelayWaitingInk") }
    public static var failedTint: Color { color(named: "RelayFailedTint") }
    public static var failedInk: Color { color(named: "RelayFailedInk") }
    public static var track: Color { color(named: "track") }
    public static var accentTint: Color { color(named: "accentTint") }

    private static func color(named name: String) -> Color {
        guard let token = NutritionTokens.token(named: name) else {
            return Color.primary
        }
        return dynamic(light: token.light, dark: token.dark)
    }

    #if canImport(UIKit)
    private static func platform(_ rgb: RGB) -> UIColor {
        UIColor(
            red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        let lightColor = platform(light)
        let darkColor = platform(dark)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }
    #elseif canImport(AppKit)
    private static func platform(_ rgb: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        let lightColor = platform(light)
        let darkColor = platform(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
    #else
    private static func dynamic(light: RGB, dark: RGB) -> Color {
        Color.primary
    }
    #endif
}
