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
                Section(section.id) {
                    ForEach(section.rows) { row in
                        Button {
                            onSelect(row.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(row.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                                Text(row.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                            }
                        }
                        .accessibilityLabel("\(row.title), \(row.detail)")
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
}
