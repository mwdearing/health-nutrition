import Foundation
import SwiftUI

/// What the calorie ring draws for a day.
public enum CalorieRingState: Equatable, Sendable {
    case progress, overGoal, noGoal, cannotTotal
}

/// The calorie ring as plain data: the state, how far to draw and whether the day is partial. The view decides nothing.
///
/// Fractions stay `Decimal`; the one conversion to a drawing number is `GoalBar.drawingWidth`.
public struct CalorieRingModel: Equatable {
    public let state: CalorieRingState
    /// How full the ring is, 0 through 1. Nil whenever there is nothing honest to draw: no goal or no known food total.
    public let fraction: Decimal?
    /// Copied from the day, so the screen keeps showing its partial note.
    public let isPartial: Bool

    public init(state: CalorieRingState, fraction: Decimal?, isPartial: Bool) {
        self.state = state
        self.fraction = fraction
        self.isPartial = isPartial
    }

    public static func make(_ calories: CalorieRemaining) -> CalorieRingModel {
        guard let goal = calories.goal else {
            return CalorieRingModel(state: .noGoal, fraction: nil, isPartial: calories.isPartial)
        }
        guard let food = calories.food, let remaining = calories.remaining else {
            return CalorieRingModel(state: .cannotTotal, fraction: nil, isPartial: calories.isPartial)
        }
        if remaining < 0 {
            return CalorieRingModel(state: .overGoal, fraction: 1, isPartial: calories.isPartial)
        }
        let allowance = goal + (calories.burned ?? 0)
        let fraction: Decimal
        if allowance <= 0 {
            fraction = food == 0 ? 0 : 1
        } else {
            fraction = min(max(food / allowance, 0), 1)
        }
        return CalorieRingModel(state: .progress, fraction: fraction, isPartial: calories.isPartial)
    }
}

/// How large the ring may grow with the text size.
public enum CalorieRingMetrics {
    /// The base diameter times the text-size scale, never more than one and six tenths of the base.
    public static func diameter(base: CGFloat, scale: CGFloat) -> CGFloat {
        min(base * scale, base * 1.6)
    }
}

/// A ring that fills with the day's calories, with the caller's content in the middle.
///
/// The drawing is decorative and hidden from VoiceOver; the caller labels the combined element.
public struct CalorieRing<Center: View>: View {
    private let model: CalorieRingModel
    private let onHero: Bool
    private let center: Center
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.heroBaseColorScheme) private var heroBase
    @Environment(\.colorScheme) private var colorScheme

    public init(model: CalorieRingModel, onHero: Bool, @ViewBuilder center: () -> Center) {
        self.model = model
        self.onHero = onHero
        self.center = center()
    }

    private var diameter: CGFloat {
        CalorieRingMetrics.diameter(base: onHero ? 200 : 116, scale: scale)
    }

    private var lineWidth: CGFloat { onHero ? 16 : 12 }

    public var body: some View {
        ZStack {
            ring
                .frame(maxWidth: diameter, maxHeight: diameter)
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
            center
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(onHero ? TokenColors.heroTrack : TokenColors.track, lineWidth: lineWidth)
                // On the hero the track resolves in the real appearance; fills keep the forced-dark values.
                .environment(\.colorScheme, onHero ? (heroBase ?? colorScheme) : colorScheme)
            if let fraction = model.fraction {
                Circle()
                    .trim(from: 0, to: GoalBar.drawingWidth(of: fraction, in: 1))
                    .stroke(
                        onHero ? TokenColors.mint : TokenColors.accent,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .spring, value: fraction)
            }
        }
        .padding(lineWidth / 2)
    }
}

#Preview("Ring, light") {
    CalorieRing(
        model: CalorieRingModel(state: .progress, fraction: 0.46, isPartial: false), onHero: false
    ) {
        Text("1,240").font(.title2.bold()).fontDesign(.rounded).monospacedDigit()
    }
    .padding()
    .background(TokenColors.page)
    .preferredColorScheme(.light)
}

#Preview("Ring, dark") {
    CalorieRing(
        model: CalorieRingModel(state: .progress, fraction: 0.46, isPartial: false), onHero: true
    ) {
        Text("1,240").font(.largeTitle.bold()).fontDesign(.rounded).monospacedDigit()
            .foregroundStyle(TokenColors.heroText)
    }
    .padding()
    .background(TokenColors.hero)
    .preferredColorScheme(.dark)
}
