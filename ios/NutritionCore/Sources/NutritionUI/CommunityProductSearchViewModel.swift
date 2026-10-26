import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

public enum CommunityProductSearchState: Equatable { case idle, queryTooShort, loading, loaded, empty, signInRequired, unsupported, unavailable }

@MainActor public final class CommunityProductSearchViewModel: ObservableObject {
    @Published public private(set) var localResults: [CustomProductRevision] = []
    @Published public private(set) var sharedResults: [CommunityProduct] = []
    @Published public private(set) var state: CommunityProductSearchState = .idle
    @Published public private(set) var loadingNextPage = false
    @Published public private(set) var pageError = false
    @Published public private(set) var localError = false
    @Published public private(set) var inspectedProduct: CommunityProduct?
    @Published public private(set) var inspectedAlternatives: [ProductAlternative] = []
    @Published public private(set) var inspectionError: String?
    @Published public private(set) var inspectionNeedsRefresh = false
    @Published public private(set) var loadingAlternatives = false
    @Published public private(set) var openFoodFactsResults: [LookedUpProduct] = []
    @Published public private(set) var openFoodFactsState: ProductNameSearchState = .idle
    private var openFoodFactsTask: Task<Void, Never>?
    private let openFoodFacts: (any ProductNameSearching)?
    private var alternativesCursor: String?
    private var inspectionGeneration = UUID()
    public var canLoadAlternatives: Bool { alternativesCursor != nil && !loadingAlternatives && !inspectionNeedsRefresh }
    private let store: any CustomProductStore
    /// Every product on this device, as the latest `search` read them; `filterLocal` narrows this list.
    private var localProducts: [CustomProductRevision] = []
    private let service: (any CommunityProductServicing)?
    private let isSignedIn: @MainActor () -> Bool
    private var query = ""
    private var kind: ProductKind?
    private var cursor: String?
    private var generation = UUID()
    public var canLoadMore: Bool { cursor != nil && !loadingNextPage }

    public init(store: any CustomProductStore, service: (any CommunityProductServicing)?, openFoodFacts: (any ProductNameSearching)? = nil, isSignedIn: @escaping @MainActor () -> Bool) {
        self.store = store; self.service = service; self.openFoodFacts = openFoodFacts; self.isSignedIn = isSignedIn
    }
    public func search(query: String, kind: ProductKind?) async {
        closeInspection()
        generation = UUID(); let token = generation
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines); self.kind = kind
        cursor = nil; sharedResults = []; pageError = false; loadingNextPage = false
        do {
            localProducts = try store.customProducts()
            localResults = Self.localMatches(localProducts, query: self.query, kind: kind)
            localError = false
        } catch { localProducts = []; localResults = []; localError = true }
        // Open Food Facts needs no account, so it runs whether or not the person is signed in.
        startOpenFoodFacts(token: token)
        guard isSignedIn() else { state = .signInRequired; return }
        guard self.query.unicodeScalars.count >= 2 else { state = .queryTooShort; return }
        guard let service else { state = .unsupported; return }
        state = .loading
        do {
            let capability = try await service.capabilities()
            guard capability.supportsBoundedPublication else { throw ProductAPIError.unsupportedBackend }
            let page = try await service.searchProducts(query: self.query, kind: kind, cursor: nil)
            guard generation == token else { return }
            guard isSignedIn() else { sharedResults = []; state = .signInRequired; return }
            merge(page); state = sharedResults.isEmpty ? .empty : .loaded
        } catch {
            guard generation == token else { return }
            state = !isSignedIn() ? .signInRequired : error as? ProductAPIError == .unsupportedBackend ? .unsupported : .unavailable
        }
    }
    /// Filters the products on this device while the person types, from the list the latest `search` read.
    /// It reads no store and sends nothing anywhere: Open Food Facts and shared products are searched only
    /// when a search is submitted, never as the person types. Shared results, paging and the query that
    /// `retry` and `loadNextPage` use stay as the last submitted search left them.
    public func filterLocal(query: String, kind: ProductKind?) {
        guard !localError else { return }
        localResults = Self.localMatches(localProducts, query: query.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
    }
    private static func localMatches(_ products: [CustomProductRevision], query: String, kind: ProductKind?) -> [CustomProductRevision] {
        products.filter {
            (kind == nil || $0.content.kind == kind) && (query.isEmpty || ($0.content.name + " " + ($0.content.brand ?? "")).localizedCaseInsensitiveContains(query))
        }.sorted { $0.content.name.localizedStandardCompare($1.content.name) == .orderedAscending }
    }
    /// Waits for the open product source search started by the latest `search` call.
    public func openFoodFactsSearchFinished() async {
        await openFoodFactsTask?.value
    }
    private func startOpenFoodFacts(token: UUID) {
        openFoodFactsTask?.cancel()
        openFoodFactsResults = []
        let text = query
        // Supplements are not in Open Food Facts, so nothing is sent for that kind.
        guard let openFoodFacts, kind != .supplement else { openFoodFactsState = .idle; return }
        guard text.count >= 2 else { openFoodFactsState = .queryTooShort; return }
        openFoodFactsState = .loading
        openFoodFactsTask = Task { [openFoodFacts] in
            let outcome = await openFoodFacts.search(query: text)
            guard self.generation == token else { return }
            switch outcome {
            case .results(let products):
                self.openFoodFactsResults = products
                self.openFoodFactsState = .results
            case .empty: self.openFoodFactsState = .empty
            case .rateLimited(let seconds): self.openFoodFactsState = .rateLimited(retryAfterSeconds: seconds)
            case .failed: self.openFoodFactsState = .unavailable
            }
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
    /// Shown when a name search is refused for now. The wait most often comes from this app's own
    /// per-minute cap on searches, so the text names the person's searches and not the source.
    public static func openFoodFactsLimitText(retryAfterSeconds: Int?) -> String {
        guard let seconds = retryAfterSeconds else {
            return "Too many product searches just now. Try again in a minute."
        }
        return "Too many product searches just now. Try again in about \(seconds) second\(seconds == 1 ? "" : "s")."
    }
    private func merge(_ page: CommunityProductPage) {
        for product in page.products {
            if let index = sharedResults.firstIndex(where: { $0.productID == product.productID }) { sharedResults[index] = product }
            else { sharedResults.append(product) }
        }
        cursor = page.nextCursor
    }
    public func inspect(_ product: CommunityProduct) throws {
        guard isSignedIn(), sharedResults.contains(product) else { throw ProductAPIError.notFound }
        inspectionGeneration = UUID(); inspectedProduct = product
        inspectedAlternatives = product.alternatives; alternativesCursor = product.alternativesCursor
        inspectionError = nil; inspectionNeedsRefresh = false; loadingAlternatives = false
    }
    public func closeInspection() {
        inspectionGeneration = UUID(); inspectedProduct = nil; inspectedAlternatives = []
        alternativesCursor = nil; inspectionError = nil; loadingAlternatives = false; inspectionNeedsRefresh = false
    }
    public func loadAlternatives() async {
        guard canLoadAlternatives, let cursor = alternativesCursor, let product = inspectedProduct, let service, isSignedIn() else { return }
        let token = inspectionGeneration; loadingAlternatives = true; inspectionError = nil
        defer { if token == inspectionGeneration { loadingAlternatives = false } }
        do {
            let page = try await service.alternatives(productID: product.productID, cursor: cursor)
            guard token == inspectionGeneration, isSignedIn() else { return }
            guard page.productID == product.productID, page.alternativesTotal == product.alternativesTotal,
                  page.nextCursor != cursor else { throw ProductAPIError.unavailable }
            let existing = Set(inspectedAlternatives.map(\.representativeRevision))
            guard Set(page.alternatives.map(\.representativeRevision)).count == page.alternatives.count,
                  UInt64(inspectedAlternatives.count + page.alternatives.count) <= (UInt64(page.alternativesTotal) ?? 0),
                  page.alternatives.allSatisfy({ !existing.contains($0.representativeRevision) }) else { throw ProductAPIError.unavailable }
            inspectedAlternatives += page.alternatives; alternativesCursor = page.nextCursor
        } catch {
            guard token == inspectionGeneration else { return }
            if case ProductAPIError.revisionConflict = error {
                inspectionNeedsRefresh = true
                inspectionError = "These shared facts changed. Refresh to inspect the current product before saving."
            } else { inspectionError = "Could not load more alternatives. Try again." }
        }
    }
    public func refreshInspection() async {
        guard let product = inspectedProduct, let service, isSignedIn() else { return }
        let token = inspectionGeneration
        do {
            let current = try await service.product(id: product.productID)
            guard token == inspectionGeneration, isSignedIn() else { return }
            if let index = sharedResults.firstIndex(where: { $0.productID == current.productID }) { sharedResults[index] = current }
            try inspect(current)
        } catch { if token == inspectionGeneration { inspectionError = "Could not refresh this product. Try again." } }
    }
    public func select(_ product: CommunityProduct) throws -> CustomProductRevision {
        guard isSignedIn(), sharedResults.contains(product),
              !(inspectedProduct?.productID == product.productID && inspectionNeedsRefresh) else { throw ProductAPIError.notFound }
        let revision = try CustomProductMapping.importedRevision(from: product)
        return try store.saveCustomProduct(CustomProductSave(revision: revision), now: Date())
    }
    public func legacyDraft(_ product: CommunityProduct) throws -> LegacyCustomProductDraft {
        guard isSignedIn(), sharedResults.contains(product),
              !(inspectedProduct?.productID == product.productID && inspectionNeedsRefresh) else { throw ProductAPIError.notFound }
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
