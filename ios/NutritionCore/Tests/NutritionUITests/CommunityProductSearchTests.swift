import Foundation
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

final class CommunityProductSearchTests: XCTestCase {
    @MainActor func testSignedOutSearchStillFindsLocalProductsAndNeverCallsSharedService() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        store.products = [syntheticCommunityRevision(name: "Synthetic tea", kind: .drink)]
        let model = CommunityProductSearchViewModel(store: store, service: service, isSignedIn: { false })
        await model.search(query: "tea", kind: .drink)
        XCTAssertEqual(model.localResults.count, 1)
        XCTAssertEqual(model.state, .signInRequired)
        let calls = await service.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.operations.isEmpty)
    }
    @MainActor func testPaginationKeepsLocalSeparateDeduplicatesAndImportsWithoutIntakeOrUpload() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let first = syntheticCommunityProduct(name: "Synthetic tea", kind: .drink)
        let second = syntheticCommunityProduct(name: "Synthetic tonic", kind: .drink)
        await service.setPages([.init(products: [first], nextCursor: "next"), .init(products: [first, second], nextCursor: nil)])
        let model = CommunityProductSearchViewModel(store: store, service: service, isSignedIn: { true })
        await model.search(query: "Synthetic", kind: nil)
        XCTAssertEqual(model.state, .loaded); XCTAssertTrue(model.canLoadMore)
        await model.loadNextPage()
        XCTAssertEqual(model.sharedResults.count, 2); XCTAssertTrue(model.localResults.isEmpty)
        XCTAssertFalse(model.canLoadMore)
        let selected = try model.select(first)
        XCTAssertEqual(selected.source?.productID, first.productID)
        XCTAssertEqual(store.commands.count, 1)
        XCTAssertNil(store.commands[0].intake); XCTAssertNil(store.commands[0].publication)
        XCTAssertTrue(store.operations.isEmpty)
    }
    @MainActor func testUnavailableRetryEmptyAndBackendUnsupportedAreDistinct() async throws {
        let service = ProductSearchServicePort()
        let model = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: service, isSignedIn: { true })
        await service.setFailure(.unavailable)
        await model.search(query: "Synthetic", kind: nil)
        XCTAssertEqual(model.state, .unavailable)
        await service.setFailure(nil); await model.retry()
        XCTAssertEqual(model.state, .empty)
        await service.setFailure(.unsupportedBackend); await model.retry()
        XCTAssertEqual(model.state, .unsupported)
    }
    @MainActor func testLegacySelectionRequiresEditorChoices() async throws {
        let service = ProductSearchServicePort(), store = ProductEditorStorePort(), id = UUID()
        let legacy = CommunityProduct(productID: id, representativeRevision: "1", product: .legacyLabel(.init(contentType: "legacy_label", name: "Synthetic legacy", barcode: "0012345678905", basis: .perServing, rawServingText: "one spoon", nutrients: ["protein": 2], legacySource: .community)), source: .init(productID: id, representativeRevision: "1", attribution: "Community"), verification: .init(status: .sharedUnverified), support: .init(distinctAccounts: "1", verificationThreshold: "3"), missingFacts: false, alternatives: [])
        await service.setPages([.init(products: [legacy], nextCursor: nil)])
        let model = CommunityProductSearchViewModel(store: store, service: service, isSignedIn: { true })
        await model.search(query: "Synthetic", kind: nil)
        XCTAssertThrowsError(try model.select(legacy))
        let draft = try model.legacyDraft(legacy)
        XCTAssertNil(draft.kind); XCTAssertEqual(draft.rawServingText, "one spoon")
        XCTAssertTrue(store.commands.isEmpty)
    }
    func testVerificationRequiresOwnerReviewedSourceNotSupportCount() {
        let product = syntheticCommunityProduct(name: "Synthetic", kind: .food, verification: .init(status: .verified), support: "100")
        XCTAssertEqual(CommunityProductSearchViewModel.verificationText(product), "Shared, not yet verified")
        let reviewed = syntheticCommunityProduct(name: "Synthetic", kind: .food, verification: .init(status: .verified, source: "owner_reviewed"))
        XCTAssertEqual(CommunityProductSearchViewModel.verificationText(reviewed), "Verified by owner review")
    }
}
func syntheticCommunityRevision(name: String, kind: ProductKind) -> CustomProductRevision {
    .init(localProductID: UUID(), revisionID: UUID(), content: .init(name: name, kind: kind, basis: .perServing))
}
func syntheticCommunityProduct(name: String, kind: ProductKind, verification: ProductVerification = .init(status: .sharedUnverified), support: String = "1") -> CommunityProduct {
    let id = UUID()
    return .init(productID: id, representativeRevision: "1", product: .custom(.init(name: name, kind: kind, basis: .perServing, facts: [])), source: .init(productID: id, representativeRevision: "1", attribution: "Community"), verification: verification, support: .init(distinctAccounts: support, verificationThreshold: "3"), missingFacts: true, alternatives: [])
}
actor ProductSearchServicePort: CommunityProductServicing {
    var pages: [CommunityProductPage] = []
    var failure: ProductAPIError?
    var ownState: ProductContributionState?
    var currentProduct: CommunityProduct?
    func setContribution(_ state: ProductContributionState, product: CommunityProduct) { ownState = state; currentProduct = product }
    var holdSearch = false
    var searchGate: CheckedContinuation<Void, Never>?
    var searchArrival: CheckedContinuation<Void, Never>?
    var searchArrived = false
    func holdNextSearch() { holdSearch = true }
    func waitForSearch() async {
        if searchArrived { return }
        await withCheckedContinuation { searchArrival = $0 }
    }
    func finishSearch() { searchGate?.resume(); searchGate = nil }
    var calls = 0
    var contributionHeld = false
    var contributionGate: CheckedContinuation<Void, Never>?
    var contributionArrival: CheckedContinuation<Void, Never>?
    var contributionArrived = false
    func holdContribution() { contributionHeld = true }
    func waitForContribution() async {
        if contributionArrived { return }
        await withCheckedContinuation { contributionArrival = $0 }
    }
    func finishContribution() { contributionGate?.resume(); contributionGate = nil }

    func setPages(_ value: [CommunityProductPage]) { pages = value }
    func setFailure(_ value: ProductAPIError?) { failure = value }
    func searchProducts(query: String, kind: ProductKind?, cursor: String?) async throws -> CommunityProductPage {
        calls += 1
        if let failure { throw failure }
        let page = pages.isEmpty ? CommunityProductPage(products: [], nextCursor: nil) : pages.removeFirst()
        if holdSearch {
            holdSearch = false
            await withCheckedContinuation { continuation in
                searchGate = continuation; searchArrived = true
                searchArrival?.resume(); searchArrival = nil
            }
        }
        return page
    }
    func product(id: UUID) async throws -> CommunityProduct { guard let currentProduct else { throw ProductAPIError.notFound }; return currentProduct }
    func capabilities() async throws -> ProductCatalogCapabilities { throw ProductAPIError.unavailable }
    func publish(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt { throw ProductAPIError.unavailable }
    func withdraw(_ request: ProductWithdrawRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt { throw ProductAPIError.unavailable }
    func resolvePublishForWithdrawal(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductPublishResolution { throw ProductAPIError.unavailable }
    func acknowledgeConsent(version: Int, expectedOwnerID: UUID) async throws -> ProductConsentState { throw ProductAPIError.unavailable }
    func contribution(productID: UUID, expectedOwnerID: UUID) async throws -> ProductContributionState {
        if contributionHeld {
            await withCheckedContinuation { continuation in
                contributionGate = continuation; contributionArrived = true
                contributionArrival?.resume(); contributionArrival = nil
            }
        }
        return ownState ?? .init(productID: productID, currentState: .none)
    }
}

extension CommunityProductSearchTests {
    @MainActor func testLoadingAndLatePreviousQueryCannotReplaceNewResults() async throws {
        let service = ProductSearchServicePort(), store = ProductEditorStorePort()
        let first = syntheticCommunityProduct(name: "Synthetic old", kind: .food)
        let newest = syntheticCommunityProduct(name: "Synthetic new", kind: .supplement)
        await service.setPages([.init(products: [first], nextCursor: "old"), .init(products: [newest], nextCursor: nil)])
        await service.holdNextSearch()
        let model = CommunityProductSearchViewModel(store: store, service: service, isSignedIn: { true })
        let old = Task { await model.search(query: "old", kind: .food) }
        await service.waitForSearch(); XCTAssertEqual(model.state, .loading)
        await model.search(query: "new", kind: .supplement)
        await service.finishSearch(); await old.value
        XCTAssertEqual(model.sharedResults, [newest]); XCTAssertFalse(model.canLoadMore)
    }
    @MainActor func testPageFailurePreservesResultsAndRefreshDropsNoLongerVisibleProduct() async throws {
        let service = ProductSearchServicePort(), store = ProductEditorStorePort()
        let first = syntheticCommunityProduct(name: "Synthetic", kind: .food)
        await service.setPages([.init(products: [first], nextCursor: "next")])
        let model = CommunityProductSearchViewModel(store: store, service: service, isSignedIn: { true })
        await model.search(query: "Synthetic", kind: nil)
        await service.setFailure(.unavailable); await model.loadNextPage()
        XCTAssertTrue(model.pageError); XCTAssertEqual(model.sharedResults, [first])
        XCTAssertEqual(model.state, .loaded)
        await service.setFailure(nil); await model.retry()
        XCTAssertEqual(model.state, .empty); XCTAssertTrue(model.sharedResults.isEmpty)
        XCTAssertThrowsError(try model.select(first)); XCTAssertTrue(store.commands.isEmpty)
    }
}
