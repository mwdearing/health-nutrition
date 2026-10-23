import SwiftUI
import NutritionDomain

/// Browsing in Add never writes an entry. A pick opens the existing details form.
public struct AddLibraryPicker: View {
    @ObservedObject private var library: LibraryViewModel
    @ObservedObject private var recipes: RecipeListViewModel
    private let onPick: (RepeatTemplate) -> Void
    private let onRecipe: (RecipeListItem) -> Void
    private let onProduct: ((CustomProductRevision) -> Void)?
    private let onSearchProducts: (() -> Void)?
    @State private var segment = "Recent"

    public init(library: LibraryViewModel, recipes: RecipeListViewModel,
        onPick: @escaping (RepeatTemplate) -> Void, onRecipe: @escaping (RecipeListItem) -> Void,
        onProduct: ((CustomProductRevision) -> Void)? = nil, onSearchProducts: (() -> Void)? = nil) {
        self.onProduct = onProduct; self.onSearchProducts = onSearchProducts
        self.library = library
        self.recipes = recipes
        self.onPick = onPick
        self.onRecipe = onRecipe
    }

    public var body: some View {
        VStack {
            Picker("Library", selection: $segment) {
                Text("Favorites").tag("Favorites")
                Text("Recent").tag("Recent")
                Text("Products").tag("Products")
                Text("Recipes").tag("Recipes")
            }
            .pickerStyle(.segmented)
            .padding(DesignSpacing.m)
            if let onSearchProducts { Button("Search foods", action: onSearchProducts) }
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
                    sectionTitle: segment == "Favorites" ? "Favorites" : segment == "Products" ? "Products" : "Recents", onProduct: onProduct)
            }
        }
        .background(TokenColors.background)
        .navigationTitle("Library")
        .onAppear { self.recipes.load() }
    }
}
