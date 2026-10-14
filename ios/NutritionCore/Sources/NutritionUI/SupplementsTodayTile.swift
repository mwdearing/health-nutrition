import SwiftUI

/// Today's way into the supplement list: how many supplement entries are logged today, and a tap opens the
/// list where each one can be taken.
struct SupplementsTodayTile: View {
    @ObservedObject var model: SupplementStackViewModel
    let now: () -> Date

    private var loggedToday: Int {
        model.rows.reduce(0) { $0 + $1.loggedToday }
    }

    private var detail: String {
        if model.rows.isEmpty { return "Set up your supplements" }
        return loggedToday == 1 ? "1 logged today" : "\(loggedToday) logged today"
    }

    var body: some View {
        NavigationLink {
            SupplementStackView(model: model, now: now)
        } label: {
            Card {
                HStack(spacing: DesignSpacing.m) {
                    Image(systemName: "pills")
                        .foregroundStyle(TokenColors.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                        Text("Supplements")
                            .font(.headline)
                            .foregroundStyle(TokenColors.textPrimary)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                    }
                    Spacer(minLength: DesignSpacing.s)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your supplement list")
        .onAppear { model.load(now: now()) }
    }
}
