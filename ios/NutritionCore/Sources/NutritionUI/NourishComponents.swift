import SwiftUI

/// Pure geometry for the Today ring and bars, kept free of SwiftUI so a test can pin it.
public enum NourishGauge {
    /// How much of the ring or bar to draw for a value against a goal: 0 through 1, and 0 when there is no
    /// usable goal. A day over goal draws a full ring; the figure beside it still says the real amount.
    public static func fraction(value: Double, goal: Double?) -> Double {
        guard let goal, goal > 0, value > 0, value.isFinite, goal.isFinite else { return 0 }
        return clamped(value / goal)
    }

    /// A drawing fraction forced into 0 through 1; NaN and infinities draw nothing.
    public static func clamped(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}

/// One of the three macro columns under the ring: label, figure and a thin bar.
public struct MacroColumn: View {
    private let label: String
    private let figure: String
    private let fraction: Double
    private let spoken: String?
    /// The missing-value note on a partial day, shown once under the figure. Nil on a whole day.
    private let note: String?

    public init(label: String, figure: String, fraction: Double, spoken: String? = nil, note: String? = nil) {
        self.spoken = spoken
        self.label = label
        self.figure = figure
        self.fraction = NourishGauge.clamped(fraction)
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .center, spacing: DesignSpacing.xs) {
            Text(label).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("macroLabel-\(label)")
            Text(figure).font(.title3.weight(.semibold)).foregroundStyle(TokenColors.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("macroFigure-\(label)")
            ThinBar(fraction: fraction)
            if let note {
                Text(note).font(.caption2).foregroundStyle(TokenColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? "\(label) \(figure)")
    }
}

/// A rounded track with a mint fill, used under figures.
public struct ThinBar: View {
    private let fraction: Double

    public init(fraction: Double) {
        self.fraction = NourishGauge.clamped(fraction)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TokenColors.track)
                Capsule().fill(TokenColors.accent).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
