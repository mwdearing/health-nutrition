import SwiftUI

/// Browsing in Add never writes an entry. A pick opens the existing details form.
public struct AddLibraryPicker: View {
    @ObservedObject private var library: LibraryViewModel
    @ObservedObject private var recipes: RecipeListViewModel
    private let onPick: (RepeatTemplate) -> Void
    private let onRecipe: (RecipeListItem) -> Void
    @State private var segment = "Recent"

    public init(library: LibraryViewModel, recipes: RecipeListViewModel,
        onPick: @escaping (RepeatTemplate) -> Void, onRecipe: @escaping (RecipeListItem) -> Void) {
        self.library = library
        self.recipes = recipes
        self.onPick = onPick
        self.onRecipe = onRecipe
    }

    public var body: some View {
        VStack {
            Picker("Library", selection: $segment) {
                Text("Favourites").tag("Favourites")
                Text("Recent").tag("Recent")
                Text("Recipes").tag("Recipes")
            }
            .pickerStyle(.segmented)
            .padding(DesignSpacing.m)
            if segment == "Recipes" {
                List {
                    if recipes.items.isEmpty {
                        EmptyState(title: "No recipes yet", message: "Your personal recipes appear here.",
                            systemImage: "book")
                    }
                    ForEach(recipes.items) { item in
                        Button { self.onRecipe(item) } label: {
                            VStack(alignment: .leading) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                            }
                        }
                        .foregroundStyle(TokenColors.textPrimary)
                    }
                    if let message = recipes.errorMessage { InlineNotice(message, tone: .failed) }
                    if let message = recipes.skippedMessage { InlineNotice(message, tone: .waiting) }
                }
                .scrollContentBackground(.hidden)
            } else {
                LibraryView(model: library, onAdded: {}, onPick: onPick,
                    sectionTitle: segment == "Favourites" ? "Favorites" : "Recents")
            }
        }
        .background(TokenColors.background)
        .navigationTitle("Library")
        .onAppear { self.recipes.load() }
    }
}
