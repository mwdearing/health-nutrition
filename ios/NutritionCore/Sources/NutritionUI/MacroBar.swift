import SwiftUI

/// One macro: its label and figure above a thin bar in the macro's colour. One accessibility element, and the
/// words carry the meaning, so colour is never the only cue.
public struct MacroBar: View {
    private let model: GoalBarModel
    private let color: Color

    public init(model: GoalBarModel, color: Color) {
        self.model = model
        self.color = color
    }

    private var fillsBar: Bool {
        model.state == .progress || model.state == .overGoal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(model.label)
                .font(.caption)
                .foregroundStyle(TokenColors.textSecondary)
            Text(model.valueText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(TokenColors.textPrimary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(TokenColors.track)
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
            MacroBar(model: previewModel("Protein", "62 g of 90 g", 0.69), color: TokenColors.macroProtein)
            MacroBar(model: previewModel("Carbs", "140 g of 250 g", 0.56), color: TokenColors.macroCarbs)
            MacroBar(model: previewModel("Fat", "40 g of 70 g", 0.57), color: TokenColors.macroFat)
        }
    }
    .padding()
    .background(TokenColors.page)
    .preferredColorScheme(.dark)
}
