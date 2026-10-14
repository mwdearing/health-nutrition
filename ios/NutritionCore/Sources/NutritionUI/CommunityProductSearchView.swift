import SwiftUI
import NutritionDomain
import NutritionProviders

public struct CommunityProductSearchView: View {
    @ObservedObject private var model: CommunityProductSearchViewModel
    private let onSelect: (CustomProductRevision) -> Void
    private let onLegacy: (LegacyCustomProductDraft) -> Void
    private let onSignIn: () -> Void
    private let onOpenFoodFacts: (LookedUpProduct, ProductKind?) -> Void
    @State private var query = ""
    @State private var kind: ProductKind?
    @State private var selectionError: String?
    @FocusState private var searchFocused: Bool
    public init(model: CommunityProductSearchViewModel, onSelect: @escaping (CustomProductRevision) -> Void, onLegacy: @escaping (LegacyCustomProductDraft) -> Void, onSignIn: @escaping () -> Void, onOpenFoodFacts: @escaping (LookedUpProduct, ProductKind?) -> Void = { _, _ in }) {
        self.model = model; self.onSelect = onSelect; self.onLegacy = onLegacy; self.onSignIn = onSignIn; self.onOpenFoodFacts = onOpenFoodFacts
    }
    public var body: some View {
        List {
            Section {
                LabeledField("Search products", focus: $searchFocused) { focus in
                    TextField("Search products", text: $query).focused(focus)
                }.onSubmit { search() }
                Picker("Kind", selection: $kind) {
                    Text("All kinds").tag(ProductKind?.none)
                    ForEach(ProductKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                Button("Search", action: search)
            }
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
            if kind != .supplement { Section(header: Text("Open Food Facts"), footer: Text("The words you search for are sent to Open Food Facts, a public database. Nothing else from this phone is sent.")) {
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
                if let attribution = model.openFoodFactsResults.compactMap(\.attribution).first,
                   let url = URL(string: attribution.url) {
                    Link("Open Food Facts license and source", destination: url).font(.footnote)
                }
            } }
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
                            Button("Save representative on this phone") { select(product); model.closeInspection() }
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
    }
    @ViewBuilder private var openFoodFactsStatus: some View {
        switch model.openFoodFactsState {
        case .idle: EmptyView()
        case .queryTooShort: Text("Enter at least two characters to search Open Food Facts.")
        case .loading: ProgressView("Searching Open Food Facts")
        case .results: EmptyView()
        case .empty: Text("No Open Food Facts products match this search.")
        case .rateLimited(let seconds):
            Text(CommunityProductSearchViewModel.openFoodFactsLimitText(retryAfterSeconds: seconds))
        case .unavailable: Text("Open Food Facts is unavailable right now.")
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
                    Text("Product serving: \(serving.quantity) \(serving.unit.symbol)")
                    if let text = serving.text { Text(text) }
                }
                if product.facts.isEmpty { Text("No facts stated") }
                ForEach(product.facts, id: \.rawKeyIdentity) { fact in
                    Text("\(fact.displayName): \(fact.amount ?? fact.state.rawValue) \(fact.unit?.symbol ?? "")")
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
                    Text("\(key): \(NSDecimalNumber(decimal: label.nutrients[key]!).stringValue) \(key == "energyKcal" ? "kcal" : key == "sodium" ? "mg" : "g")")
                }
            }
        }
    }
}
