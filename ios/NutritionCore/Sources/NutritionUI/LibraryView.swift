import SwiftUI

public struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    private let now: () -> Date
    private let onAdded: () -> Void

    public init(model: LibraryViewModel, now: @escaping () -> Date = { Date() }, onAdded: @escaping () -> Void) {
        self.model = model
        self.now = now
        self.onAdded = onAdded
    }

    public var body: some View {
        List {
            ForEach(model.sections) { section in
                Section(section.title) {
                    if section.items.isEmpty {
                        Text("Nothing here yet.").font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    }
                    ForEach(section.items) { item in
                        HStack {
                            Button {
                                if model.select(item, now: now()) != nil { onAdded() }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                                    Text(item.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                                }
                            }
                            .accessibilityLabel("Add \(item.title), \(item.detail)")
                            .accessibilityHint("Adds a new entry now with the same amounts")
                            Spacer()
                            Button {
                                if item.isFavorite { model.removeFavorite(item) } else { model.addFavorite(item) }
                            } label: {
                                Image(systemName: item.isFavorite ? "star.fill" : "star")
                                    .foregroundStyle(TokenColors.accent)
                                    .accessibilityLabel(item.isFavorite ? "Favorite" : "Not a favorite")
                            }
                            .accessibilityLabel(item.isFavorite ? "Remove \(item.title) from favorites" : "Add \(item.title) to favorites")
                        }
                    }
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Library")
        .onAppear { model.load() }
    }
}
