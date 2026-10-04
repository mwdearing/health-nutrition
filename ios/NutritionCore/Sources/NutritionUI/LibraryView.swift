import SwiftUI

public struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    private let now: () -> Date
    private let onAdded: () -> Void
    /// When given, the Library screen offers the way in to Connections and privacy. It is the only entry point.
    private let connections: ConnectionsPrivacyViewModel?

    public init(
        model: LibraryViewModel, now: @escaping () -> Date = { Date() }, onAdded: @escaping () -> Void,
        connections: ConnectionsPrivacyViewModel? = nil
    ) {
        self.model = model
        self.now = now
        self.onAdded = onAdded
        self.connections = connections
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
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add \(item.title), \(item.detail)")
                            .accessibilityHint("Adds a new entry now with the same amounts")
                            Spacer()
                            Button {
                                if item.isFavorite { model.removeFavorite(item) } else { model.addFavorite(item) }
                            } label: {
                                Image(systemName: item.isFavorite ? "star.fill" : "star")
                                    .foregroundStyle(TokenColors.accent)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(item.isFavorite ? "Remove \(item.title) from favorites" : "Add \(item.title) to favorites")
                        }
                    }
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            if let connections {
                Section("Connections") {
                    NavigationLink {
                        ConnectionsPrivacyView(model: connections, now: now)
                    } label: {
                        Text("Connections and privacy")
                            .font(.body)
                            .foregroundStyle(TokenColors.textPrimary)
                    }
                    .accessibilityLabel("Connections and privacy")
                    .accessibilityHint("Export your journal and read what data leaves this device")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Library")
        .onAppear { model.load() }
    }
}
