import SwiftUI

private struct HeroBaseColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    /// The real appearance outside a `HeroCard`, whose content is forced dark. Nil outside a hero.
    var heroBaseColorScheme: ColorScheme? {
        get { self[HeroBaseColorSchemeKey.self] }
        set { self[HeroBaseColorSchemeKey.self] = newValue }
    }
}

/// The deep teal card at the top of a screen.
///
/// Its content is drawn with the dark appearance in both modes, so macro fills and controls keep their dark values
/// on the hero; text on it uses `heroText` and `heroSecondaryText`. The override covers the content only: the
/// background resolves from the real appearance.
public struct HeroCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = DesignRadius.card, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .foregroundStyle(TokenColors.heroText)
            .environment(\.heroBaseColorScheme, colorScheme)
            .environment(\.colorScheme, .dark)
            .padding(DesignSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                TokenColors.hero,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

#Preview("Hero, light") {
    HeroCard {
        Text("Today").font(.headline)
        Text("1,240 left").font(.title2.bold()).fontDesign(.rounded).monospacedDigit()
    }
    .padding()
    .background(TokenColors.page)
    .preferredColorScheme(.light)
}

#Preview("Hero, dark") {
    HeroCard {
        Text("Today").font(.headline)
        Text("1,240 left").font(.title2.bold()).fontDesign(.rounded).monospacedDigit()
    }
    .padding()
    .background(TokenColors.page)
    .preferredColorScheme(.dark)
}
