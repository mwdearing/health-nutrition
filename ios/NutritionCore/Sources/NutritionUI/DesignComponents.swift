import NutritionDomain
import SwiftUI

/// Spacing steps the design uses. Integers, so there is no floating-point literal to drift.
public enum DesignSpacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 14
    public static let l: CGFloat = 22
    /// Room at the bottom of a scrolling screen for the floating Add button and the tab bar.
    public static let floatingClearance: CGFloat = 140
}

/// Corner radii the design uses. Buttons are capsules and need no radius.
public enum DesignRadius {
    public static let card: CGFloat = 22
    public static let control: CGFloat = 12
}

/// A rounded container on the surface color, for content composed of more than standard rows.
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

/// A text input with a caption that stays above it, the input in a box, and any error under the box.
///
/// The caption says what the field is for and never goes away: a placeholder vanishes as soon as something
/// is typed, so the placeholder the input carries is an example, not a repeat of the caption. The caption
/// is hidden from VoiceOver because the input is labeled by the caption's words, so the field is read once.
///
/// The box turns the accent color while the input has focus and the error color when an error is passed. The
/// error is not read on its own: the caller gives it to the input as the hint, so the field is read once.
/// Focus is the field's own unless the screen passes its focus state, which it does when it also moves focus
/// itself. `onFocusEnd` runs when focus leaves, so a screen can show an error once the person is done with a
/// field rather than while they are still typing.
public struct LabeledField<Content: View>: View {
    private let label: String
    private let error: String?
    private let externalFocus: FocusState<Bool>.Binding?
    private let onFocusEnd: (() -> Void)?
    private let onFocusBegin: (() -> Void)?
    private let content: (FocusState<Bool>.Binding) -> Content
    @FocusState private var ownFocus: Bool

    public init(
        _ label: String,
        error: String? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        onFocusEnd: (() -> Void)? = nil,
        onFocusBegin: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (FocusState<Bool>.Binding) -> Content
    ) {
        self.label = label
        self.error = error
        self.externalFocus = focus
        self.onFocusEnd = onFocusEnd
        self.onFocusBegin = onFocusBegin
        self.content = content
    }

    private var focus: FocusState<Bool>.Binding { externalFocus ?? $ownFocus }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
                .accessibilityHidden(true)
            content(focus)
                .padding(.horizontal, DesignSpacing.m)
                .padding(.vertical, DesignSpacing.s)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(
                    TokenColors.background,
                    in: RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous)
                        .stroke(strokeColor, lineWidth: 1))
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.error)
            }
        }
        .onChange(of: focus.wrappedValue) { _, isFocused in
            if isFocused { onFocusBegin?() } else { onFocusEnd?() }
        }
    }

    private var strokeColor: Color {
        if error != nil { return TokenColors.error }
        return focus.wrappedValue ? TokenColors.accent : TokenColors.border
    }
}

/// Shared visible and accessible wording for starting an intake.
public enum AddIntakeAction {
    public static let title = "Add food, drink, or supplement"
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

    @Environment(\.isEnabled) private var isEnabled

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
            // A disabled capsule looks disabled: the fixed colours alone read as tappable.
            .opacity(isEnabled ? 1 : 0.5)
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

/// A recent journal write and its short-lived undo action.
public struct UndoToast: View {
    private let message: String
    private let onUndo: () -> Void

    public init(_ message: String, onUndo: @escaping () -> Void) {
        self.message = message
        self.onUndo = onUndo
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public var body: some View {
        // Stacked at accessibility sizes so the Undo button keeps its width and the message can wrap.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.s))
            : AnyLayout(HStackLayout(spacing: DesignSpacing.m))
        layout {
            Text(message).font(.body)
            if !stacked { Spacer(minLength: DesignSpacing.s) }
            // Undo is an accent fill with the background ink, so it reads apart from the accentTint toast.
            Button(action: onUndo) {
                Text("Undo")
                    .font(.headline)
                    .foregroundStyle(TokenColors.background)
                    .padding(.horizontal, DesignSpacing.m)
                    .frame(minHeight: 44)
                    .background(TokenColors.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(TokenColors.textPrimary)
        .padding(DesignSpacing.m)
        .background(TokenColors.accentTint, in: RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous))
        // VoiceOver hears the toast's own message when it appears.
        .onAppear { AccessibilityNotification.Announcement(message).post() }
        // A replaced undo offer keeps this view, so announce its new message too.
        .onChange(of: message) { _, newMessage in AccessibilityNotification.Announcement(newMessage).post() }
    }
}
