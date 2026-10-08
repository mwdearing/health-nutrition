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

    /// One entry: what it was, how much of it, and which meal it was for, as the shared row. The meal
    /// joins the amounts on one line because it qualifies the entry rather than being another amount.
    /// A supplement and a drink carry their tag; a food carries none.
    private func entryRow(_ row: JournalRow) -> some View {
        let detail = [row.detail, row.meal].compactMap { $0 }.joined(separator: " · ")
        return EntryRow(title: row.title, detail: detail, kind: row.kind)
    }
}
