import SwiftUI

/// Pure geometry for the Today ring and bars, kept free of SwiftUI so a test can pin it.
public enum NourishGauge {
    /// How much of the ring or bar to draw for a value against a goal: 0 through 1, and 0 when there is no
    /// usable goal. A day over goal draws a full ring; the figure beside it still says the real amount.
    public static func fraction(value: Double, goal: Double?) -> Double {
        guard let goal, goal > 0, value > 0, value.isFinite, goal.isFinite else { return 0 }
        return min(value / goal, 1)
    }
}

/// The calorie ring on Today: a track, a mint arc, and the figure and caption inside it.
public struct CalorieRing: View {
    private let fraction: Double
    private let figure: String
    private let caption: String
    private let footnote: String?

    public init(fraction: Double, figure: String, caption: String, footnote: String? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.figure = figure
        self.caption = caption
        self.footnote = footnote
    }

    public var body: some View {
        ZStack {
            Circle().stroke(TokenColors.track, lineWidth: 18)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(TokenColors.mint, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: DesignSpacing.xs) {
                Text(figure)
                    .font(.largeTitle.weight(.bold))
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(TokenColors.textPrimary)
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
            }
            .padding(DesignSpacing.l)
        }
        .frame(maxWidth: 240)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(figure) \(caption)")
        .accessibilityValue(footnote ?? "")
    }
}

/// One of the three macro columns under the ring: label, figure and a thin bar.
public struct MacroColumn: View {
    private let label: String
    private let figure: String
    private let fraction: Double

    public init(label: String, figure: String, fraction: Double) {
        self.label = label
        self.figure = figure
        self.fraction = min(max(fraction, 0), 1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(label).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            Text(figure).font(.title3.weight(.semibold)).foregroundStyle(TokenColors.textPrimary)
            ThinBar(fraction: fraction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A rounded track with a mint fill, used under figures.
public struct ThinBar: View {
    private let fraction: Double

    public init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TokenColors.track)
                Capsule().fill(TokenColors.mint).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// A half-width summary tile: icon, title, figure and a thin bar, with a chevron when it opens something.
public struct SummaryTile: View {
    private let systemImage: String
    private let title: String
    private let figure: String
    private let fraction: Double?
    private let action: (() -> Void)?

    public init(
        systemImage: String, title: String, figure: String, fraction: Double? = nil, action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.figure = figure
        self.fraction = fraction
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) { tile }.buttonStyle(.plain)
        } else {
            tile
        }
    }

    private var tile: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                HStack {
                    Image(systemName: systemImage).foregroundStyle(TokenColors.accent).accessibilityHidden(true)
                    Spacer(minLength: 0)
                    if action != nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                Text(title).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                Text(figure).font(.title3.weight(.semibold)).foregroundStyle(TokenColors.textPrimary)
                if let fraction { ThinBar(fraction: fraction) }
            }
        }
    }
}
