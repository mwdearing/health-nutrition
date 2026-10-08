import SwiftUI

public struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    private let now: () -> Date
    private let onAdded: () -> Void
/// When given, the Library screen offers the way in to personal recipes.
    private let onOpenRecipes: (() -> Void)?
    /// When given, the Library screen offers the way in to Connections and privacy. It is the only entry point.
    private let connections: ConnectionsPrivacyViewModel?
    /// When given, the Library screen offers the way in to the daily goals.
    private let goals: GoalsViewModel?

    public init(
        model: LibraryViewModel, now: @escaping () -> Date = { Date() }, onAdded: @escaping () -> Void,
        onOpenRecipes: (() -> Void)? = nil, connections: ConnectionsPrivacyViewModel? = nil,
        goals: GoalsViewModel? = nil
    ) {
        self.model = model
        self.now = now
        self.onAdded = onAdded
        self.onOpenRecipes = onOpenRecipes
        self.connections = connections
        self.goals = goals
    }

    public var body: some View {
        List {
            if let onOpenRecipes {
                Button("Recipes") { onOpenRecipes() }
                    .font(.headline)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityLabel(RecipeLabels.recipesRow)
                    .accessibilityHint("Opens your personal recipes")
            }
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
                                    // A supplement is marked here for the reason it is marked on Today:
                                    // its amounts read like any other item's, and nothing in them says the
                                    // item is not food.
                                    if item.kind == .supplement {
                                        Label(ProductKind.supplement.displayName, systemImage: "pills")
                                            .font(.footnote)
                                            .foregroundStyle(TokenColors.accent)
                                    }
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
                    if let goals {
                        NavigationLink {
                            GoalsView(model: goals)
                        } label: {
                            Text("Daily goals")
                                .font(.body)
                                .foregroundStyle(TokenColors.textPrimary)
                        }
                        .accessibilityLabel("Daily goals")
                        .accessibilityHint("Set what you are aiming for in protein, sugar, salt and the rest")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Library")
        .onAppear { model.load() }
    }
}
