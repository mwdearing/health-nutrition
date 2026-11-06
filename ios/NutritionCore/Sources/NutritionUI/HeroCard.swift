import SwiftUI

/// The deep teal card at the top of a screen.
///
/// Its content is drawn with the dark appearance in both modes, so macro fills and controls keep their dark values
/// on the hero; text on it uses `heroText` and `heroSecondaryText`. The override covers the content only: the
/// background resolves from the real appearance.
public struct HeroCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = DesignRadius.card, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .foregroundStyle(TokenColors.heroText)
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
