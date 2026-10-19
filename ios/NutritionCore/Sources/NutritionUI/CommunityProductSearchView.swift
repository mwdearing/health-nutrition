import SwiftUI
import NutritionDomain
import NutritionProviders

public struct CommunityProductSearchView: View {
    @ObservedObject private var model: CommunityProductSearchViewModel
    private let onSelect: (CustomProductRevision) -> Void
    private let onLegacy: (LegacyCustomProductDraft) -> Void
    private let onSignIn: () -> Void
    private let onSaved: () -> Void
    private let onOpenFoodFacts: (LookedUpProduct, ProductKind?) -> Void
    /// The person's own favorites and recents, listed above the products. Both must be given, or the
    /// screen shows products only.
    private let library: LibraryViewModel?
    /// Opens the details form prefilled from a favorite or recent. Nothing is logged until Save.
    private let onPick: ((RepeatTemplate) -> Void)?
    @State private var query = ""
    @State private var kind: ProductKind?
    @State private var selectionError: String?
    /// The saved meal whose "Log to which meal" choice is up.
    @State private var mealToLog: SavedMeal?
    @FocusState private var searchFocused: Bool
    /// Focus is taken once per screen. Going Back from a result must not raise the keyboard over it.
    @State private var didAutoFocus = false
    public init(model: CommunityProductSearchViewModel, onSelect: @escaping (CustomProductRevision) -> Void, onLegacy: @escaping (LegacyCustomProductDraft) -> Void, onSignIn: @escaping () -> Void, onOpenFoodFacts: @escaping (LookedUpProduct, ProductKind?) -> Void = { _, _ in },
                library: LibraryViewModel? = nil, onPick: ((RepeatTemplate) -> Void)? = nil,
                focusSearchOnAppear: Bool = false, onSaved: @escaping () -> Void = {}) {
        self.onSaved = onSaved
        self.model = model; self.onSelect = onSelect; self.onLegacy = onLegacy; self.onSignIn = onSignIn; self.onOpenFoodFacts = onOpenFoodFacts
        self.library = library; self.onPick = onPick; self.focusSearchOnAppear = focusSearchOnAppear
    }
    /// Opened from Add's search row: the field takes focus so the keyboard is up at once.
    private let focusSearchOnAppear: Bool
    public var body: some View {
        List {
            Section {
                LabeledField("Search foods and products", focus: $searchFocused) { focus in
                    TextField("Search foods and products", text: $query).focused(focus).submitLabel(.search)
                }.onSubmit { search() }
                Picker("Kind", selection: $kind) {
                    Text("All kinds").tag(ProductKind?.none)
                    ForEach(ProductKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                Button("Search", action: search)
                if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    Button("Search food databases", action: search)
                }
            } footer: {
                Text("Your foods and products on this phone narrow as you type. Public food databases and shared products are searched only when you tap Search or press Return.")
            }
            if kind != .supplement { Section(header: Text("Food databases"), footer: Text("The words you search for are sent to public food databases (USDA FoodData Central and Open Food Facts). Nothing else from this phone is sent.")) {
                openFoodFactsStatus
                ForEach(model.openFoodFactsResults, id: \.self) { product in
                    Button { onOpenFoodFacts(product, kind) } label: {
                        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                            Text(product.name ?? "Unnamed product").font(.headline)
                            if let brand = product.brand { Text(brand) }
                            Text(product.basis.label).font(.footnote)
                            if let attribution = product.attribution { Text(attribution.text).font(.footnote) }
                        }
                    }.accessibilityHint("Opens intake details filled from this product. Nothing is logged until you save.")
                }
                ForEach(Self.sourceAttributions(model.openFoodFactsResults), id: \.self) { attribution in
                    if let url = URL(string: attribution.url) {
                        Link(attribution.text, destination: url).font(.footnote)
                    }
                }
            } }
            // A saved meal can mix foods, drinks and supplements, so meals are offered only under All kinds; a
            // warning about entries a failed log left behind shows under any kind.
            if let savedMeals = library?.savedMeals, onPick != nil {
                SavedMealSections(model: savedMeals, query: query, showsMeals: kind == nil, onLog: { mealToLog = $0 })
            }
            if let library, let onPick { LibrarySearchSections(library: library, query: query, kind: kind, onPick: onPick) }
            Section("On this phone") {
                if model.localError { Text("Could not read local products.") }
                else if model.localResults.isEmpty { Text("No matching local products.") }
                ForEach(model.localResults, id: \.localProductID) { product in
                    Button { onSelect(product) } label: {
                        VStack(alignment: .leading) {
                            Text(product.content.name)
                            Text(product.content.kind.displayName).font(.footnote)
                        }
                    }.accessibilityHint("Opens intake details without logging or sharing")
                }
            }
            Section("Shared products") {
                sharedState
                ForEach(model.sharedResults, id: \.productID) { product in
                    Button { do { try model.inspect(product) } catch { selectionError = "Search again to refresh this product." } } label: {
                        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                            Text(CommunityProductSearchViewModel.name(product)).font(.headline)
                            Text(CommunityProductSearchViewModel.verificationText(product))
                            Text("\(product.support.distinctAccounts) supporting accounts").font(.footnote)
                            if product.missingFacts { Text("No numeric facts stated").font(.footnote) }
                            if !product.alternatives.isEmpty {
                                Text("Separate alternatives; facts are not averaged.").font(.footnote)
                                ForEach(product.alternatives, id: \.representativeRevision) { alternative in
                                    Text("Alternative revision \(alternative.representativeRevision): \(alternative.support.distinctAccounts) supporting accounts").font(.footnote)
                                }
                            }
                            Text(product.source.attribution).font(.footnote)
                        }
                    }.accessibilityHint("Inspects shared facts and alternatives without saving, logging or sharing.")
                }
                if model.loadingNextPage { ProgressView("Loading more shared products") }
                if model.pageError { Text("Could not load the next page.") }
                if model.canLoadMore { Button(model.pageError ? "Retry next page" : "Load more") { Task { await model.loadNextPage() } } }
            }
            if let selectionError { Text(selectionError).foregroundStyle(TokenColors.error) }
        }
        .sheet(isPresented: Binding(get: { model.inspectedProduct != nil }, set: { if !$0 { model.closeInspection() } })) {
            if let product = model.inspectedProduct {
                NavigationStack {
                    List {
                        Section("Shared representative") {
                            SharedProductFactsView(content: product.product, source: product.source, verification: product.verification)
                            Text("\(product.support.distinctAccounts) supporting accounts")
                            if product.missingFacts { Text("No numeric facts stated") }
                        }
                        ForEach(model.inspectedAlternatives, id: \.representativeRevision) { alternative in
                            Section("Separate alternative · revision \(alternative.representativeRevision)") {
                                SharedProductFactsView(content: alternative.product, source: alternative.source, verification: alternative.verification)
                                Text("\(alternative.support.distinctAccounts) supporting accounts")
                            }
                        }
                        Section {
                            Text("Alternatives have separate facts and support; they are not averaged. Saving uses the representative above.")
                            Text("\(model.inspectedAlternatives.count) of \(product.alternativesTotal ?? String(product.alternatives.count)) alternatives shown")
                            if model.loadingAlternatives { ProgressView("Loading alternatives") }
                            if model.canLoadAlternatives { Button("Load more alternatives") { Task { await model.loadAlternatives() } } }
                            if let error = model.inspectionError { Text(error) }
                            if model.inspectionNeedsRefresh { Button("Refresh shared facts") { Task { await model.refreshInspection() } } }
                            Button("Save representative on this phone") {
                                select(product)
                                // Only a saved product confirms; a legacy label opens an editor draft that is not saved yet.
                                if selectionError == nil, case .custom = product.product { onSaved() }
                                model.closeInspection()
                            }
                                .disabled(model.inspectionNeedsRefresh)
                        }
                    }
                    .navigationTitle("Inspect product facts")
                    .toolbar { Button("Close") { model.closeInspection() } }
                }
            }
        }
        .navigationTitle("Find products")
        .task { if model.state == .idle { await model.search(query: query, kind: kind) } }
        // Focus after the push animation. Setting focus during the transition can be dropped.
        .task {
            guard focusSearchOnAppear, !didAutoFocus else { return }
            // Counted as this screen's one focus even if it closes during the delay, so a return
            // never raises the keyboard unasked.
            didAutoFocus = true
            // A screen left before the delay ends must not raise the keyboard on its way out.
            guard (try? await Task.sleep(nanoseconds: 400_000_000)) != nil else { return }
            searchFocused = true
        }
        .onAppear {
            if onPick != nil {
                library?.load()
                library?.savedMeals?.load()
            }
        }
        // The Undo window ends with this screen, as it does on the Library screen.
        .onDisappear { library?.savedMeals?.clearUndo() }
        .safeAreaInset(edge: .bottom) {
            if let savedMeals = library?.savedMeals { SavedMealUndoBar(model: savedMeals) }
        }
        .confirmationDialog(
            mealToLog.map { "Log \($0.name)" } ?? "Log saved meal",
            isPresented: Binding(get: { mealToLog != nil }, set: { if !$0 { mealToLog = nil } }),
            titleVisibility: .visible, presenting: mealToLog
        ) { saved in
            ForEach(SavedMealsModel.mealChoices(for: saved), id: \.self) { choice in
                Button(choice.map { "Log to \($0.displayName)" } ?? "Log with no meal") {
                    library?.savedMeals?.log(saved, as: choice, now: Date())
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { saved in
            Text("Adds \(SavedMealsModel.itemsText(saved.items.count)) now, as new entries. Like any entry, they are written to Apple Health once it is connected.")
        }
        // Typing narrows what is already on this phone. It never starts a search that leaves the phone.
        .onChange(of: query) { _, text in model.filterLocal(query: text, kind: kind) }
        .onChange(of: kind) { _, selected in model.filterLocal(query: query, kind: selected) }
    }
    /// One attribution per source, in a stable order, so each license link shows once under the results.
    static func sourceAttributions(_ products: [LookedUpProduct]) -> [ProductAttribution] {
        Array(Set(products.compactMap(\.attribution))).sorted { $0.source < $1.source }
    }

    @ViewBuilder private var openFoodFactsStatus: some View {
        switch model.openFoodFactsState {
        case .idle: EmptyView()
        case .queryTooShort: Text("Enter at least two characters to search food databases.")
        case .loading: ProgressView("Searching food databases")
        case .results: EmptyView()
        case .empty: Text("No products match this search.")
        case .rateLimited(let seconds):
            Text(CommunityProductSearchViewModel.openFoodFactsLimitText(retryAfterSeconds: seconds))
        case .unavailable: Text("Food databases are unavailable right now.")
        }
    }
    @ViewBuilder private var sharedState: some View {
        switch model.state {
        case .idle: Text("Search shared foods, drinks and supplements.")
        case .queryTooShort: Text("Enter at least two characters to search shared products.")
        case .loading: ProgressView("Searching shared products")
        case .loaded: EmptyView()
        case .empty: Text("No shared products match this search.")
        case .signInRequired:
            Text("Sign in to search shared products. Local products are available above.")
            Button("Sign in", action: onSignIn)
        case .unsupported: Text("Shared product search is unavailable on this server.")
        case .unavailable:
            Text("Shared products are temporarily unavailable.")
            Button("Retry") { Task { await model.retry() } }
        }
    }
    private func search() {
        // The keyboard covers the results below the form, which reads as if nothing happened.
        searchFocused = false
        Task { await model.search(query: query, kind: kind) }
    }
    private func select(_ product: CommunityProduct) {
        do {
            switch product.product {
            case .custom: onSelect(try model.select(product))
            case .legacyLabel: onLegacy(try model.legacyDraft(product))
            }
            selectionError = nil
        } catch { selectionError = "Could not open this product. Search again to refresh the results." }
    }
}

/// The saved meals on Find products, narrowed by name as the person types. A tap asks which meal to log it
/// under; nothing is logged until one is chosen.
struct SavedMealSections: View {
    @ObservedObject var model: SavedMealsModel
    let query: String
    /// False under a Kind other than All kinds: only a leftover warning is shown then.
    let showsMeals: Bool
    let onLog: (SavedMeal) -> Void
    var body: some View {
        let meals = showsMeals ? model.matching(query) : []
        let showsNotes = showsMeals && (model.loadError != nil || (model.notice != nil && model.noticeIsFailure))
        if model.leftoverWarning != nil || !meals.isEmpty || showsNotes {
            Section("Saved meals") {
                if let warning = model.leftoverWarning { InlineNotice(warning, tone: .failed) }
                if showsMeals, let error = model.loadError { Text(error).foregroundStyle(TokenColors.error) }
                if showsMeals, let notice = model.notice, model.noticeIsFailure { InlineNotice(notice, tone: .failed) }
                ForEach(meals) { saved in
                    Button { onLog(saved) } label: {
                        VStack(alignment: .leading) {
                            Text(saved.name).font(.headline).foregroundStyle(TokenColors.textPrimary)
                            Text(Self.detail(saved)).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                        }
                    }
                    .accessibilityHint("Asks which meal to log it under")
                    // No full swipe: removing a meal is one tap on Remove, and Undo is offered for ten seconds.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", role: .destructive) { model.remove(saved) }
                    }
                }
            }
        }
    }
    static func detail(_ saved: SavedMeal) -> String {
        let items = SavedMealsModel.itemsText(saved.items.count)
        guard let meal = saved.meal else { return items }
        return "\(items) · \(meal.displayName)"
    }
}

/// The Undo offer for the saved meal just logged, for ten seconds.
struct SavedMealUndoBar: View {
    @ObservedObject var model: SavedMealsModel
    var body: some View {
        // Both offers can be up at once: a removal does not hide the Undo of a meal just logged.
        VStack(spacing: DesignSpacing.s) {
            if let token = model.undoToken {
                UndoToast(token.message) { model.undo(now: Date()) }
                    .id(token.id)
                    .padding(DesignSpacing.m)
                    .task(id: token.id) {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        model.expireUndo(token)
                    }
            }
            if let removal = model.removalUndo {
                UndoToast(removal.message) { model.undoRemove() }
                    .padding(DesignSpacing.m)
                    .task(id: removal.id) {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        model.expireRemoval(removal)
                    }
            }
        }
    }
}

/// The person's own favorites and recents on Find products, narrowed as they type. Built from the Library's
/// last load: nothing here reads the network or sends the query anywhere, and a tap opens details only.
struct LibrarySearchSections: View {
    @ObservedObject var library: LibraryViewModel
    let query: String
    /// The screen's Kind selection; nil lists every kind.
    let kind: ProductKind?
    let onPick: (RepeatTemplate) -> Void
    var body: some View {
        // The screen loads the Library as it appears, and only a failed load leaves a message after it:
        // the groups would otherwise show whatever an earlier load left as if it were current.
        if library.errorMessage != nil {
            Section("Your foods") {
                Text("Could not read your recent and favorite items.").foregroundStyle(TokenColors.error)
            }
        } else {
            groups
        }
    }
    @ViewBuilder private var groups: some View {
        ForEach(library.searchGroups(matching: query, kind: kind)) { group in
            Section(group.title) {
                if group.items.isEmpty { Text("Nothing you have logged or saved matches.").foregroundStyle(TokenColors.textSecondary) }
                ForEach(group.items) { item in
                    Button { onPick(item.template) } label: {
                        VStack(alignment: .leading) {
                            Text(item.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                            Text(item.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                            // Marked for the reason the Library marks it: its amounts read like food.
                            if item.kind == .supplement {
                                Label(ProductKind.supplement.displayName, systemImage: "pills")
                                    .font(.footnote).foregroundStyle(TokenColors.accent)
                            }
                        }
                    }
                    .accessibilityLabel(item.accessibilityLabel(forPick: true))
                    .accessibilityHint("Opens details without adding an entry")
                }
            }
        }
    }
}

/// Read-only content. No import, account authority or attestation is created by rendering this view.
struct SharedProductFactsView: View {
    let content: CommunityProductContent
    let source: ProductSourceDTO?
    let verification: ProductVerification?
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            if let source { Text(source.attribution).font(.footnote) }
            if let verification {
                Text(verification.status == .verified && verification.source == "owner_reviewed"
                    ? "Verified by owner review of these exact facts" : "Shared, not yet verified")
            } else { Text("Review status is not provided for this alternative.") }
            switch content {
            case .custom(let product):
                Text(product.name).font(.headline)
                if let brand = product.brand { Text(brand) }
                if let barcode = product.barcode { Text("Barcode: \(barcode)") }
                Text(product.kind.displayName)
                Text(product.basis.rawValue)
                if let serving = product.serving {
                    Text("Product serving: \(serving.quantity) \(serving.unit.screenSymbol)")
                    if let text = serving.text { Text(text) }
                }
                if product.facts.isEmpty { Text("No facts stated") }
                ForEach(product.facts, id: \.rawKeyIdentity) { fact in
                    Text("\(fact.displayName): \(fact.amount ?? fact.state.rawValue) \(fact.unit?.screenSymbol ?? "")")
                }
            case .legacyLabel(let label):
                Text(label.name).font(.headline)
                if label.nameDisplayTrimmed { Text("Outer spaces in the original label name are omitted for display. Facts and source revision are unchanged.").font(.footnote) }
                if let brand = label.brand { Text(brand) }
                Text("Barcode: \(label.barcode)")
                Text("Legacy label · kind not selected")
                Text(label.basis.rawValue)
                if let serving = label.rawServingText { Text("Original serving: \(serving)") }
                Text("Source: \(label.legacySource.rawValue)")
                ForEach(label.nutrients.keys.sorted(), id: \.self) { key in
                    let amount = NSDecimalNumber(decimal: label.nutrients[key]!).stringValue
                    Text(key == "energyKcal" ? "Calories: \(amount)" : "\(NutrientNames.displayName(for: key)): \(amount) \(key == "sodium" ? "mg" : "g")")
                }
            }
        }
    }
}
