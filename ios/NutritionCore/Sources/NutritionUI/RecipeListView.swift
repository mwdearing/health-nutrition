import SwiftUI

public struct RecipeListView: View {
    @ObservedObject var model: RecipeListViewModel
    private let onNew: () -> Void
    private let onOpen: (RecipeListItem) -> Void
    @State private var pendingDelete: RecipeListItem?

    public init(model: RecipeListViewModel, onNew: @escaping () -> Void, onOpen: @escaping (RecipeListItem) -> Void) {
        self.model = model
        self.onNew = onNew
        self.onOpen = onOpen
    }

    public var body: some View {
        List {
            Section {
                Button(RecipeLabels.newRecipe) { onNew() }
                    .font(.headline)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityLabel(RecipeLabels.newRecipe)
                    .accessibilityHint("Starts an empty recipe")
            }
            Section("Recipes") {
                if model.items.isEmpty {
                    Text("No recipes yet.").font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
                ForEach(model.items) { item in
                    HStack {
                        Button {
                            onOpen(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                                Text(item.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(RecipeLabels.open(title: item.title, version: item.versionNumber))
                        Spacer()
                        Button {
                            pendingDelete = item
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(TokenColors.error)
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(RecipeLabels.delete(title: item.title))
                    }
                }
            }
            if let message = model.skippedMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.warning)
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Recipes")
        .onAppear { model.load() }
        .confirmationDialog(
            "Delete this recipe?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = pendingDelete { model.delete(id: item.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It disappears from the list. Logged entries keep the version they used.")
        }
    }
}
