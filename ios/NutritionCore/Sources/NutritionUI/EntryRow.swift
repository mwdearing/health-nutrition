import NutritionDomain
import SwiftUI

/// One logged entry in a list: an icon, what it was, how much and when, and a tag for a drink or a
/// supplement. Today and the Journal both list entries with it.
public struct EntryRow: View {
    private let title: String
    private let detail: String
    private let kind: ProductKind
    private let showsChevron: Bool

    public init(title: String, detail: String, kind: ProductKind = .food, showsChevron: Bool = true) {
        self.title = title
        self.detail = detail
        self.kind = kind
        self.showsChevron = showsChevron
    }

    /// The symbol in the icon well for a kind.
    static func symbol(for kind: ProductKind) -> String {
        switch kind {
        case .food: return "fork.knife"
        case .drink: return "cup.and.saucer"
        case .supplement: return "pills"
        }
    }

    public var body: some View {
        HStack(spacing: DesignSpacing.m) {
            Image(systemName: Self.symbol(for: kind))
                .foregroundStyle(TokenColors.accent)
                .frame(width: 40, height: 40)
                .background(TokenColors.accentTint, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                Text(title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                Text(detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                if let tag = KindTag(kind: kind) {
                    tag
                }
            }
            Spacer(minLength: DesignSpacing.s)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
