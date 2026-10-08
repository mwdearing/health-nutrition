import NutritionDomain
import SwiftUI

/// Spacing steps the design uses. Integers, so there is no floating-point literal to drift.
public enum DesignSpacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 14
    public static let l: CGFloat = 22
}

/// Corner radii the design uses. Buttons are capsules and need no radius.
public enum DesignRadius {
    public static let card: CGFloat = 22
    public static let control: CGFloat = 12
}

/// A rounded container on the surface colour, for content composed of more than standard rows.
public struct Card<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(DesignSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                TokenColors.surface,
                in: RoundedRectangle(cornerRadius: DesignRadius.card, style: .continuous))
    }
}

/// The one filled action on a screen: mint with the dark ink on it.
public struct PrimaryCapsule: View {
    private let title: String
    private let systemImage: String?
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSpacing.s) {
                if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title).font(.headline)
            }
            .foregroundStyle(TokenColors.onMint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(TokenColors.mint, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A secondary action: the accent tint with the accent ink on it.
public struct QuietCapsule: View {
    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(TokenColors.accentInk)
                .padding(.horizontal, DesignSpacing.m)
                .frame(minHeight: 44)
                .background(TokenColors.accentTint, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The small "Later" chip that marks a placeholder: a feature the product intends and this build does
/// not have. A row carrying it is disabled; see `laterPlaceholder()`.
public struct LaterBadge: View {
    public init() {}

    public var body: some View {
        Text("Later")
            .font(.caption)
            .foregroundStyle(TokenColors.waitingInk)
            .padding(.horizontal, DesignSpacing.s)
            .padding(.vertical, DesignSpacing.xs)
            .background(TokenColors.waitingTint, in: Capsule())
    }
}

extension View {
    /// Makes a row a placeholder: disabled, announced as not available, with no handler behind it.
    public func laterPlaceholder() -> some View {
        self
            .disabled(true)
            .accessibilityValue("Not available yet")
    }
}

/// A product-kind chip on a row. A food carries none, being what a row normally is.
public struct KindTag: View {
    private let kind: ProductKind
    private let text: String

    /// Nil for a food, which has no tag.
    public init?(kind: ProductKind) {
        guard let text = Self.title(for: kind) else { return nil }
        self.kind = kind
        self.text = text
    }

    /// The chip's words, or nil where a kind has none.
    public static func title(for kind: ProductKind) -> String? {
        switch kind {
        case .food: return nil
        case .drink: return "Drink"
        case .supplement: return "Supplement"
        }
    }

    public var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(TokenColors.textPrimary)
            .padding(.horizontal, DesignSpacing.s)
            .padding(.vertical, DesignSpacing.xs)
            .background(TokenColors.accentTint, in: Capsule())
    }
}

/// A line that says something about the state of the app, tinted by that state. Never about the day.
public struct InlineNotice: View {
    public enum Tone: Equatable, Sendable {
        case waiting, failed
    }

    private let text: String
    private let tone: Tone

    public init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.s) {
            Image(systemName: tone == .failed ? "exclamationmark.triangle" : "clock")
                .accessibilityHidden(true)
            Text(text).font(.footnote)
        }
        .foregroundStyle(tone == .failed ? TokenColors.failedInk : TokenColors.waitingInk)
        .padding(DesignSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tone == .failed ? TokenColors.failedTint : TokenColors.waitingTint,
            in: RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A list with nothing in it: a symbol, a title, one line and at most one button.
public struct EmptyState: View {
    private let title: String
    private let message: String
    private let systemImage: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        title: String, message: String, systemImage: String, actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .tint(TokenColors.accent)
            }
        }
    }
}
