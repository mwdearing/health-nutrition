import NutritionDomain
import SwiftUI

public struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    private let now: () -> Date
    private let onAdded: () -> Void
/// When given, the Library screen offers the way in to personal recipes.
    private let onOpenRecipes: (() -> Void)?
    private let onPick: ((RepeatTemplate) -> Void)?
    private let sectionTitle: String?

    public init(
        model: LibraryViewModel, now: @escaping () -> Date = { Date() }, onAdded: @escaping () -> Void,
        onOpenRecipes: (() -> Void)? = nil,
        // Kept so existing callers still compile. Goals and the privacy screen are reached from Settings
        // now, and the Library no longer shows either, so both are ignored.
        connections: ConnectionsPrivacyViewModel? = nil, goals: GoalsViewModel? = nil,
        onPick: ((RepeatTemplate) -> Void)? = nil, sectionTitle: String? = nil
    ) {
        self.model = model
        self.now = now
        self.onAdded = onAdded
        self.onOpenRecipes = onOpenRecipes
        self.onPick = onPick
        self.sectionTitle = sectionTitle
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
            ForEach(model.sections.filter { self.sectionTitle == nil || $0.title == self.sectionTitle }) { section in
                Section(section.title) {
                    if section.items.isEmpty {
                        Text("Nothing here yet.").font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    }
                    ForEach(section.items) { item in
                        self.libraryRow(item)
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
        .onAppear { self.model.load() }
    }

    @ViewBuilder
    private func libraryRow(_ item: LibraryItem) -> some View {
        HStack {
            Button {
                if let onPick = self.onPick {
                    onPick(item.template)
                } else if self.model.select(item, now: self.now()) != nil {
                    self.onAdded()
                }
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
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityHint(onPick == nil ? "Adds a new entry now with the same amounts" : "Opens details without adding an entry")
            Spacer()
            Button {
                if item.isFavorite { self.model.removeFavorite(item) } else { self.model.addFavorite(item) }
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
