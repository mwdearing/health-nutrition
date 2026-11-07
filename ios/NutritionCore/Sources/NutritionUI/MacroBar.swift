import SwiftUI

/// One macro: its label and figure above a thin bar in the macro's color. One accessibility element, and the
/// words carry the meaning, so color is never the only cue.
public struct MacroBar: View {
    private let model: GoalBarModel
    private let color: Color
    private let onHero: Bool
    @Environment(\.heroBaseColorScheme) private var heroBase
    @Environment(\.colorScheme) private var colorScheme

    public init(model: GoalBarModel, color: Color, onHero: Bool = false) {
        self.model = model
        self.color = color
        self.onHero = onHero
    }

    private var fillsBar: Bool {
        model.state == .progress || model.state == .overGoal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(model.label)
                .font(.caption)
                .foregroundStyle(onHero ? TokenColors.heroSecondaryText : TokenColors.textSecondary)
            Text(model.valueText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(onHero ? TokenColors.heroText : TokenColors.textPrimary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(onHero ? TokenColors.heroTrack : TokenColors.track)
                        .environment(\.colorScheme, onHero ? (heroBase ?? colorScheme) : colorScheme)
                    if fillsBar, let fraction = model.fraction {
                        Capsule()
                            .fill(color)
                            .frame(width: GoalBar.drawingWidth(of: fraction, in: proxy.size.width))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityText)
    }
}

private func previewModel(_ label: String, _ text: String, _ fraction: Decimal) -> GoalBarModel {
    GoalBarModel(
        id: label, label: label, valueText: text, state: .progress, fraction: fraction, goalMarker: nil,
        accessibilityText: "\(label), \(text)", reason: nil)
}

#Preview("Macros, light") {
    HStack(spacing: DesignSpacing.m) {
        MacroBar(model: previewModel("Protein", "62 g of 90 g", 0.69), color: TokenColors.macroProtein)
        MacroBar(model: previewModel("Carbs", "140 g of 250 g", 0.56), color: TokenColors.macroCarbs)
        MacroBar(model: previewModel("Fat", "40 g of 70 g", 0.57), color: TokenColors.macroFat)
    }
    .padding()
    .background(TokenColors.card)
    .preferredColorScheme(.light)
}

#Preview("Macros, dark") {
    HeroCard {
        HStack(spacing: DesignSpacing.m) {
            MacroBar(model: previewModel("Protein", "62 g of 90 g", 0.69), color: TokenColors.macroProtein, onHero: true)
            MacroBar(model: previewModel("Carbs", "140 g of 250 g", 0.56), color: TokenColors.macroCarbs, onHero: true)
            MacroBar(model: previewModel("Fat", "40 g of 70 g", 0.57), color: TokenColors.macroFat, onHero: true)
        }
    }
    .padding()
    .background(TokenColors.page)
    .preferredColorScheme(.dark)
}
