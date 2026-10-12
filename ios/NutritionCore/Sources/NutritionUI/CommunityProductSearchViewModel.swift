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
    @Published public private(set) var inspectedProduct: CommunityProduct?
    @Published public private(set) var inspectedAlternatives: [ProductAlternative] = []
    @Published public private(set) var inspectionError: String?
    @Published public private(set) var inspectionNeedsRefresh = false
    @Published public private(set) var loadingAlternatives = false
    private var alternativesCursor: String?
    private var inspectionGeneration = UUID()
    public var canLoadAlternatives: Bool { alternativesCursor != nil && !loadingAlternatives && !inspectionNeedsRefresh }
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
        closeInspection()
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
