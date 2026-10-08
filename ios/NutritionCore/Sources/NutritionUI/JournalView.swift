import NutritionDomain
import SwiftUI

public struct JournalView: View {
    @ObservedObject var model: JournalViewModel
    private let now: () -> Date
    private let onSelect: (String) -> Void

    public init(model: JournalViewModel, now: @escaping () -> Date = { Date() }, onSelect: @escaping (String) -> Void) {
        self.model = model
        self.now = now
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            ForEach(model.sections) { section in
                Section(section.title) {
                    Text(section.totalsText)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityLabel("Totals: \(section.totalsText)")
                    ForEach(section.rows) { row in
                        Button {
                            onSelect(row.id)
                        } label: {
                            entryRow(row)
                        }
                        .accessibilityLabel(row.accessibilityText)
                        .accessibilityHint("Opens the entry")
                    }
                }
            }
            if model.skippedCount > 0 {
                Text("\(model.skippedCount) entries could not be shown because their stored time zone or record is unreadable.")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.warning)
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Journal")
        .onAppear { model.load(now: now()) }
    }

    /// One entry: what it was, how much of it, and which meal it was for. The meal is a secondary
    /// line because it qualifies the entry rather than being another amount of it.
    ///
    /// A supplement is marked rather than left to be guessed at: its amounts read like any other
    /// entry's, and nothing in them says the entry is not food.
    private func entryRow(_ row: JournalRow) -> some View {
        VStack(alignment: .leading) {
            Text(row.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
            Text(row.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
            if let meal = row.meal {
                Text(meal).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            if row.kind == .supplement {
                Label(ProductKind.supplement.displayName, systemImage: "pills")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.accent)
            }
        }
    }
}
