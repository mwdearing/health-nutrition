import NutritionDomain
import SwiftUI

public struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    private let onProduct: ((CustomProductRevision) -> Void)?
    private let onEditProduct: ((CustomProductRevision) -> Void)?
    private let onLegacyProduct: ((LegacyCustomProductDraft) -> Void)?
    private let onSearchProducts: (() -> Void)?
    private let onNewProduct: (() -> Void)?
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
        onOpen: ((RepeatTemplate) -> Void)? = nil,
        onProduct: ((CustomProductRevision) -> Void)? = nil,
        onEditProduct: ((CustomProductRevision) -> Void)? = nil,
        onLegacyProduct: ((LegacyCustomProductDraft) -> Void)? = nil,
        onSearchProducts: (() -> Void)? = nil, onNewProduct: (() -> Void)? = nil
    ) {
        self.onProduct = onProduct; self.onEditProduct = onEditProduct; self.onLegacyProduct = onLegacyProduct
        self.onSearchProducts = onSearchProducts; self.onNewProduct = onNewProduct
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
                LabeledField("Search on this device") { focus in
                    TextField("Search on this device", text: $model.searchText).focused(focus)
                }
                if let onSearchProducts { Button("Search foods", action: onSearchProducts) }
                if let onNewProduct { Button("Create product", action: onNewProduct) }
                if let stack = model.supplementStack {
                    NavigationLink("My supplements") { SupplementStackView(model: stack, now: now, onLogged: onAdded) }
                }
                if let medicationLog = model.medicationLog, medicationLog.isOn {
                    NavigationLink("Medication log") { MedicationLogView(model: medicationLog) }
                }
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
        .task { await model.observeProductStatus() }
        // The Undo window ends with this screen: its ten-second task is canceled with the toast.
        .onDisappear { if self.onPick == nil { self.model.clearUndo() } }
        .safeAreaInset(edge: .bottom) {
            // Pick mode is Add's "From Library": a token from this screen must never show there.
            if onPick == nil, let token = model.undoToken {
                UndoToast(token.message) {
                    if self.model.undo(now: self.now()) { self.onAdded() }
                }
                .id(token.intakeID)
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
        if sectionTitle == "Products" { standaloneRows }
        ForEach(model.sections.filter { self.sectionTitle == nil || $0.title == self.sectionTitle }) { section in
            Section(section.title) {
                if section.items.isEmpty {
                    Text(model.emptyText(for: section.title == "Favorites" ? .favorites : section.title == "Products" ? .products : .recent).message)
                        .font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
                ForEach(section.items) { item in
                    self.libraryRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch model.segment {
        case .favorites, .recent, .products:
            if model.segment == .products { standaloneRows }
            if model.isSearchEmpty {
                ContentUnavailableView.search(text: model.searchText)
                if let onSearchProducts {
                    Button("Find shared products", action: onSearchProducts).frame(minHeight: 44)
                }
            } else if model.visibleItems.isEmpty && (model.segment != .products || model.filteredProducts.isEmpty) {
                emptyState(for: model.segment)
            } else {
                ForEach(model.visibleItems) { item in
                    self.libraryRow(item)
                }
            }
        case .recipes:
            if let onOpenRecipes {
                Button("Open recipes") { onOpenRecipes() }
                    .font(.headline)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityHint("Opens your personal recipes")
            } else {
                emptyState(for: .recipes)
            }
        }
    }

    @ViewBuilder private var standaloneRows: some View {
        ForEach(model.filteredProducts, id: \.localProductID) { product in
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                Button { onProduct?(product) } label: {
                    VStack(alignment: .leading) {
                        Text(product.content.name).font(.headline)
                        Text(product.content.kind.displayName).font(.footnote)
                        if LibraryProductPresentation(product).missingFacts { Text("Missing facts").font(.footnote) }
                        if let source = product.source { Text("Imported from \(source.attribution)").font(.footnote) }
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Opens intake details without adding an entry")
                Text(LibraryProductPresentation(product).verificationText)
                    .font(.footnote).accessibilityIdentifier("productVerificationStatus")
                if let sharing = model.productSharing {
                    Text(sharing.status(product).rawValue).accessibilityIdentifier("productDeliveryStatus")
                    Text(sharing.detail(product)).font(.footnote)
                    if sharing.canRetry(product) { Button("Retry") { Task { await sharing.retry(product); model.load() } } }
                }
                if let onEditProduct { Button("Edit and sharing review") { onEditProduct(product) } }
            }
        }
    }

    private func emptyState(for segment: LibrarySegment) -> some View {
        let text = model.emptyText(for: segment)
        return EmptyState(title: text.title, message: text.message, systemImage: text.systemImage)
    }

    @ViewBuilder
    private func libraryRow(_ item: LibraryItem) -> some View {
        // Every row opens its details form; the row never logs by itself (#503). Logging is the Log control at the
        // row's end, which logs once with Undo.
        HStack {
            Button {
                switch LibraryRowTap.forRow() {
                case .openDetails:
                    if let onPick { onPick(item.template) } else { onOpen?(item.template) }
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
            .accessibilityLabel(item.accessibilityLabel(forPick: true))
            .accessibilityValue(item.accessibilityValue)
            .accessibilityHint("Opens details without adding an entry")
            Spacer()
            if let onLegacyProduct, model.canCompleteProduct(item) {
                Button(item.template.productSnapshotID == nil ? "Complete product" : "Edit product") {
                    do {
                        if let product = try model.standaloneProduct(for: item), let onEditProduct {
                            onEditProduct(product)
                        } else {
                            onLegacyProduct(try model.legacyDraft(item))
                        }
                    } catch { model.reportOpenFailure() }
                }.buttonStyle(.borderless)
            }
            if onPick == nil {
                QuietCapsule("Add") {
                    if self.model.quickAdd(item, now: self.now()) { self.onAdded() }
                }
                .accessibilityLabel(item.logAccessibilityLabel)
                .accessibilityValue(item.accessibilityValue)
                .accessibilityHint("Logs once. You can undo for 10 seconds.")
            }
            Button {
                if item.isFavorite { self.model.removeFavorite(item) } else { self.model.addFavorite(item) }
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isFavorite ? "Remove \(item.title) from favorites" : "Add \(item.title) to favorites")
        }
    }
}

