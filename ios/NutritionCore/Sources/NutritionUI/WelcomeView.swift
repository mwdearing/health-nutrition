import SwiftUI

/// The first-run welcome: what the app is for, and where the journal is kept. It asks for nothing:
/// no permission prompt, no network request, and nothing stored. Whether it has been shown is kept by
/// the host, not here.
public struct WelcomeView: View {
    private let onStart: () -> Void
    private let onRestore: () -> Void

    public init(onStart: @escaping () -> Void, onRestore: @escaping () -> Void) {
        self.onStart = onStart
        self.onRestore = onRestore
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.l) {
                VStack(alignment: .leading, spacing: DesignSpacing.s) {
                    Text("HealthNutrition")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(TokenColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Log what you eat and drink. See it against goals you set.")
                        .font(.body)
                        .foregroundStyle(TokenColors.textSecondary)
                }
                point("Scan a label or barcode, or type it in", symbol: "barcode.viewfinder")
                point("Your journal stays on this phone", symbol: "iphone")
                point("No scores, no advice", symbol: "hand.raised")
                PrimaryCapsule("Get started", action: onStart)
                Button(action: onRestore) {
                    Text("Restore from an export")
                        .font(.subheadline)
                        .foregroundStyle(TokenColors.accent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Restores a journal export file")
            }
            .padding(DesignSpacing.l)
        }
        .background(TokenColors.background)
    }

    /// One statement with a decorative symbol that carries no meaning of its own.
    private func point(_ text: String, symbol: String) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.m) {
                Image(systemName: symbol)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.headline)
                    .foregroundStyle(TokenColors.textPrimary)
            }
        }
    }
}
