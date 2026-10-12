import SwiftUI
import NutritionDomain
import NutritionProviders

public struct CommunityProductSearchView: View {
    @ObservedObject private var model: CommunityProductSearchViewModel
    private let onSelect: (CustomProductRevision) -> Void
    private let onLegacy: (LegacyCustomProductDraft) -> Void
    private let onSignIn: () -> Void
    @State private var query = ""
    @State private var kind: ProductKind?
    @State private var selectionError: String?
    public init(model: CommunityProductSearchViewModel, onSelect: @escaping (CustomProductRevision) -> Void, onLegacy: @escaping (LegacyCustomProductDraft) -> Void, onSignIn: @escaping () -> Void) {
        self.model = model; self.onSelect = onSelect; self.onLegacy = onLegacy; self.onSignIn = onSignIn
    }
    public var body: some View {
        List {
            Section {
                LabeledField("Search products") { focus in
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
            Section("Shared products") {
                sharedState
                ForEach(model.sharedResults, id: \.productID) { product in
                    Button { select(product) } label: {
                        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                            Text(CommunityProductSearchViewModel.name(product)).font(.headline)
                            Text(CommunityProductSearchViewModel.verificationText(product))
                            Text("\(product.support.distinctAccounts) supporting accounts").font(.footnote)
                            if product.missingFacts { Text("Missing facts").font(.footnote) }
                            if !product.alternatives.isEmpty {
                                Text("Separate alternatives; facts are not averaged.").font(.footnote)
                                ForEach(product.alternatives, id: \.representativeRevision) { alternative in
                                    Text("Alternative revision \(alternative.representativeRevision): \(alternative.support.distinctAccounts) supporting accounts").font(.footnote)
                                }
                            }
                            Text(product.source.attribution).font(.footnote)
                        }
                    }.accessibilityHint("Saves a local copy and opens details. Does not log or share.")
                }
                if model.loadingNextPage { ProgressView("Loading more shared products") }
                if model.pageError { Text("Could not load the next page.") }
                if model.canLoadMore { Button(model.pageError ? "Retry next page" : "Load more") { Task { await model.loadNextPage() } } }
            }
            if let selectionError { Text(selectionError).foregroundStyle(TokenColors.error) }
        }
        .navigationTitle("Find products")
        .task { if model.state == .idle { await model.search(query: query, kind: kind) } }
    }
    @ViewBuilder private var sharedState: some View {
        switch model.state {
        case .idle: Text("Search shared foods, drinks and supplements.")
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
    private func search() { Task { await model.search(query: query, kind: kind) } }
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
