import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

public enum CommunityProductSearchState: Equatable { case idle, loading, loaded, empty, signInRequired, unsupported, unavailable }

@MainActor public final class CommunityProductSearchViewModel: ObservableObject {
    @Published public private(set) var localResults: [CustomProductRevision] = []
    @Published public private(set) var sharedResults: [CommunityProduct] = []
    @Published public private(set) var state: CommunityProductSearchState = .idle
    @Published public private(set) var loadingNextPage = false
    @Published public private(set) var pageError = false
    @Published public private(set) var localError = false
    private let store: any CustomProductStore
    private let service: (any CommunityProductServicing)?
    private let isSignedIn: @MainActor () -> Bool
    private var query = ""
    private var kind: ProductKind?
    private var cursor: String?
    private var generation = UUID()
    public var canLoadMore: Bool { cursor != nil && !loadingNextPage }

    public init(store: any CustomProductStore, service: (any CommunityProductServicing)?, isSignedIn: @escaping @MainActor () -> Bool) {
        self.store = store; self.service = service; self.isSignedIn = isSignedIn
    }
    public func search(query: String, kind: ProductKind?) async {
        generation = UUID(); let token = generation
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines); self.kind = kind
        cursor = nil; sharedResults = []; pageError = false; loadingNextPage = false
        do {
            localResults = try store.customProducts().filter {
                (kind == nil || $0.content.kind == kind) && (self.query.isEmpty || ($0.content.name + " " + ($0.content.brand ?? "")).localizedCaseInsensitiveContains(self.query))
            }.sorted { $0.content.name.localizedStandardCompare($1.content.name) == .orderedAscending }
            localError = false
        } catch { localResults = []; localError = true }
        guard isSignedIn() else { state = .signInRequired; return }
        guard let service else { state = .unsupported; return }
        state = .loading
        do {
            let page = try await service.searchProducts(query: self.query, kind: kind, cursor: nil)
            guard generation == token else { return }
            guard isSignedIn() else { sharedResults = []; state = .signInRequired; return }
            merge(page); state = sharedResults.isEmpty ? .empty : .loaded
        } catch {
            guard generation == token else { return }
            state = !isSignedIn() ? .signInRequired : error as? ProductAPIError == .unsupportedBackend ? .unsupported : .unavailable
        }
    }
    public func loadNextPage() async {
        guard let cursor, let service, !loadingNextPage, isSignedIn() else { return }
        let token = generation; loadingNextPage = true; pageError = false
        defer { if generation == token { loadingNextPage = false } }
        do {
            let page = try await service.searchProducts(query: query, kind: kind, cursor: cursor)
            guard generation == token else { return }
            guard isSignedIn() else { sharedResults = []; self.cursor = nil; state = .signInRequired; return }
            merge(page)
            // An unchanged cursor must never create an endless load-more loop.
            if self.cursor == cursor { self.cursor = nil }
        } catch { if generation == token { pageError = true } }
    }
    public func retry() async { await search(query: query, kind: kind) }
    private func merge(_ page: CommunityProductPage) {
        for product in page.products {
            if let index = sharedResults.firstIndex(where: { $0.productID == product.productID }) { sharedResults[index] = product }
            else { sharedResults.append(product) }
        }
        cursor = page.nextCursor
    }
    public func select(_ product: CommunityProduct) throws -> CustomProductRevision {
        guard isSignedIn(), sharedResults.contains(product) else { throw ProductAPIError.notFound }
        let revision = try CustomProductMapping.importedRevision(from: product)
        return try store.saveCustomProduct(CustomProductSave(revision: revision), now: Date())
    }
    public func legacyDraft(_ product: CommunityProduct) throws -> LegacyCustomProductDraft {
        guard isSignedIn(), sharedResults.contains(product) else { throw ProductAPIError.notFound }
        return try CustomProductMapping.stagedDraft(from: product)
    }
    nonisolated public static func name(_ product: CommunityProduct) -> String {
        switch product.product { case .custom(let content): return content.name; case .legacyLabel(let label): return label.name }
    }
    nonisolated public static func verificationText(_ product: CommunityProduct) -> String {
        product.verification.status == .verified && product.verification.source == "owner_reviewed"
            ? "Verified by owner review" : "Shared, not yet verified"
    }
}
