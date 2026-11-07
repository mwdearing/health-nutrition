import Foundation
import SwiftUI

/// A white card on the page in light mode and a teal card in dark.
public struct ContentCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = DesignRadius.card, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(DesignSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                TokenColors.card,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A rounded square with a symbol on the accent tint. The symbol is decorative.
public struct IconWell: View {
    public enum Size { case small, regular }

    private let systemName: String
    private let size: Size

    public init(systemName: String, size: Size = .regular) {
        self.systemName = systemName
        self.size = size
    }

    private var side: CGFloat { size == .small ? 30 : 36 }

    public var body: some View {
        Image(systemName: systemName)
            .font(size == .small ? .subheadline : .body)
            .foregroundStyle(TokenColors.accent)
            .accessibilityHidden(true)
            .frame(width: side, height: side)
            .background(
                TokenColors.accentTint,
                in: RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
    }
}

/// A heading for a group of cards, with an optional note on the right.
public struct SectionHeader: View {
    private let title: String
    private let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(TokenColors.textPrimary)
            Spacer(minLength: DesignSpacing.s)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small card with an icon, one figure and an optional bar. Read as one element: "title, value detail".
public struct StatTile: View {
    private let title: String
    private let value: String
    private let detail: String
    private let systemImage: String
    private let fraction: Decimal?

    public init(title: String, value: String, detail: String, systemImage: String, fraction: Decimal?) {
        self.title = title
        self.value = value
        self.detail = detail
        self.systemImage = systemImage
        self.fraction = fraction
    }

    public var body: some View {
        ContentCard(cornerRadius: DesignRadius.tile) {
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                HStack(spacing: DesignSpacing.s) {
                    IconWell(systemName: systemImage, size: .small)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(TokenColors.textSecondary)
                }
                Text(value)
                    .font(.title2.bold())
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(TokenColors.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                if let fraction {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(TokenColors.track)
                            Capsule()
                                .fill(TokenColors.accent)
                                .frame(width: GoalBar.drawingWidth(of: fraction, in: proxy.size.width))
                        }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(detail)")
    }
}

#Preview("Cards, light") {
    VStack(spacing: DesignSpacing.cardGap) {
        SectionHeader("Today", trailing: "3 meals")
        ContentCard { Text("A card").font(.body).foregroundStyle(TokenColors.textPrimary) }
        StatTile(title: "Protein", value: "62 g", detail: "of 90 g", systemImage: "leaf", fraction: 0.69)
    }
    .padding()
    .background(TokenColors.page)
    .preferredColorScheme(.light)
}

#Preview("Cards, dark") {
    VStack(spacing: DesignSpacing.cardGap) {
        SectionHeader("Today", trailing: "3 meals")
        ContentCard { Text("A card").font(.body).foregroundStyle(TokenColors.textPrimary) }
        StatTile(title: "Protein", value: "62 g", detail: "of 90 g", systemImage: "leaf", fraction: 0.69)
    }
    .padding()
    .background(TokenColors.page)
    .preferredColorScheme(.dark)
}
