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
    /// Opens the Add details form, prefilled from the item. Nothing is logged until Save.
    private let onOpen: ((RepeatTemplate) -> Void)?

    public init(
        model: LibraryViewModel, now: @escaping () -> Date = { Date() }, onAdded: @escaping () -> Void,
        onOpenRecipes: (() -> Void)? = nil,
        // Kept so existing callers still compile. Goals and the privacy screen are reached from Settings
        // now, and the Library no longer shows either, so both are ignored.
        connections: ConnectionsPrivacyViewModel? = nil, goals: GoalsViewModel? = nil,
        onPick: ((RepeatTemplate) -> Void)? = nil, sectionTitle: String? = nil,
        onOpen: ((RepeatTemplate) -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onAdded = onAdded
        self.onOpenRecipes = onOpenRecipes
        self.onPick = onPick
        self.sectionTitle = sectionTitle
        self.onOpen = onOpen
    }

    public var body: some View {
        List {
            if onPick != nil {
                pickSections
            } else {
                searchPlaceholder
                Picker("Library segment", selection: $model.segment) {
                    ForEach(LibrarySegment.allCases) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                segmentContent
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Library")
        .onAppear { self.model.load() }
        .safeAreaInset(edge: .bottom) {
            if let token = model.undoToken {
                UndoToast(token.message) {
                    if self.model.undo(now: self.now()) { self.onAdded() }
                }
                .padding(DesignSpacing.m)
                .task(id: token.intakeID) {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self.model.expireUndo(token)
                }
            }
        }
    }

    /// Pick mode (Add's "From Library") keeps the plain list of both sections, no segments and no Add.
    @ViewBuilder
    private var pickSections: some View {
        ForEach(model.sections.filter { self.sectionTitle == nil || $0.title == self.sectionTitle }) { section in
            Section(section.title) {
                if section.items.isEmpty {
                    Text(model.emptyText(for: section.title == "Favorites" ? .favourites : .recent).message)
                        .font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
                ForEach(section.items) { item in
                    self.libraryRow(item)
                }
            }
        }
    }

    /// Search is not built yet: a disabled row that says so.
    private var searchPlaceholder: some View {
        HStack {
            Label("Search the Library", systemImage: "magnifyingglass")
                .foregroundStyle(TokenColors.textSecondary)
            Spacer()
            LaterBadge()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not available yet")
        .disabled(true)
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch model.segment {
        case .favourites, .recent:
            if model.visibleItems.isEmpty {
                emptyState(for: model.segment)
            } else {
                ForEach(model.visibleItems) { item in
                    self.libraryRow(item)
                }
            }
        case .foods:
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                emptyState(for: .foods)
                LaterBadge()
            }
        case .recipes:
            if let onOpenRecipes {
                Button("Open recipes") { onOpenRecipes() }
                    .font(.headline)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityLabel(RecipeLabels.recipesRow)
                    .accessibilityHint("Opens your personal recipes")
            } else {
                emptyState(for: .recipes)
            }
        }
    }

    private func emptyState(for segment: LibrarySegment) -> some View {
        let text = model.emptyText(for: segment)
        return EmptyState(title: text.title, message: text.message, systemImage: text.systemImage)
    }

    @ViewBuilder
    private func libraryRow(_ item: LibraryItem) -> some View {
        let opensDetails = onPick != nil || onOpen != nil
        HStack {
            Button {
                if let onPick = self.onPick {
                    onPick(item.template)
                } else {
                    self.onOpen?(item.template)
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
            .accessibilityLabel(item.accessibilityLabel(forPick: opensDetails))
            .accessibilityHint(opensDetails ? "Opens details without adding an entry" : "")
            Spacer()
            if onPick == nil {
                QuietCapsule("Add") {
                    if self.model.quickAdd(item, now: self.now()) { self.onAdded() }
                }
                .accessibilityLabel("Add \(item.title) now")
            }
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
