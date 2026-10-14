import Foundation
import XCTest
import NutritionDomain
@testable import NutritionJournal
@testable import NutritionUI

private final class FakeNameSearch: ProductNameSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    private let outcome: ProductNameSearchOutcome

    init(outcome: ProductNameSearchOutcome) { self.outcome = outcome }

    var receivedQueries: [String] { lock.withLock { queries } }

    func search(query: String) async -> ProductNameSearchOutcome {
        lock.withLock { queries.append(query) }
        return outcome
    }
}

/// A source whose full record differs from its search result, and can be held open by a test.
private final class FakeDetailedSearch: ProductNameSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holding: Bool
    let full: LookedUpProduct

    init(full: LookedUpProduct, hold: Bool = false) { self.full = full; self.holding = hold }

    var detailBarcodes: [String] { lock.withLock { asked } }

    func search(query: String) async -> ProductNameSearchOutcome { .empty }

    func details(for product: LookedUpProduct) async -> LookedUpProduct {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                asked.append(product.barcode)
                if holding { held = continuation }
                return holding
            }
            if !wait { continuation.resume() }
        }
        return full
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holding = false
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}

final class OpenFoodFactsProductSearchTests: XCTestCase {
    private func product(_ name: String) -> LookedUpProduct {
        LookedUpProduct(barcode: "2000000000015", name: name, brand: nil, basis: .per100g, nutrients: [:])
    }

    @MainActor func testSignedOutSearchStillShowsOpenFoodFactsResults() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let source = FakeNameSearch(outcome: .results([product("Oat Biscuit")]))
        let model = CommunityProductSearchViewModel(store: store, service: service, openFoodFacts: source, isSignedIn: { false })
        await model.search(query: "oat", kind: nil)
        await model.openFoodFactsSearchFinished()
        XCTAssertEqual(model.openFoodFactsResults.map(\.name), ["Oat Biscuit"])
        XCTAssertEqual(model.openFoodFactsState, .results)
        XCTAssertEqual(model.state, .signInRequired)
        let calls = await service.calls
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testOneCharacterQueryIsNotSentToOpenFoodFacts() async throws {
        let source = FakeNameSearch(outcome: .empty)
        let model = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: ProductSearchServicePort(), openFoodFacts: source, isSignedIn: { true })
        await model.search(query: "a", kind: nil)
        await model.openFoodFactsSearchFinished()
        XCTAssertEqual(model.openFoodFactsState, .queryTooShort)
        XCTAssertTrue(source.receivedQueries.isEmpty)
    }

    @MainActor func testRateLimitAndEmptyAreReportedPerSource() async throws {
        let limited = FakeNameSearch(outcome: .rateLimited(retryAfterSeconds: 42))
        let model = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: ProductSearchServicePort(), openFoodFacts: limited, isSignedIn: { true })
        await model.search(query: "oat", kind: nil)
        await model.openFoodFactsSearchFinished()
        XCTAssertEqual(model.openFoodFactsState, .rateLimited(retryAfterSeconds: 42))

        let none = FakeNameSearch(outcome: .empty)
        let second = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: ProductSearchServicePort(), openFoodFacts: none, isSignedIn: { true })
        await second.search(query: "zzqqxx", kind: nil)
        await second.openFoodFactsSearchFinished()
        XCTAssertEqual(second.openFoodFactsState, .empty)
        XCTAssertTrue(second.openFoodFactsResults.isEmpty)
    }

    /// The wait usually comes from this app's own per-minute cap, so the text must not blame the source.
    @MainActor func testLimitTextSaysTooManySearchesAndTheWait() {
        XCTAssertEqual(
            CommunityProductSearchViewModel.openFoodFactsLimitText(retryAfterSeconds: 39),
            "Too many Open Food Facts searches just now. Try again in about 39 seconds.")
        XCTAssertEqual(
            CommunityProductSearchViewModel.openFoodFactsLimitText(retryAfterSeconds: 1),
            "Too many Open Food Facts searches just now. Try again in about 1 second.")
        XCTAssertEqual(
            CommunityProductSearchViewModel.openFoodFactsLimitText(retryAfterSeconds: nil),
            "Too many Open Food Facts searches just now. Try again in a minute.")
    }

    @MainActor func testPickedResultIsFilledFromTheFullRecord() async {
        let hit = LookedUpProduct(barcode: "2000000000015", name: "Oat Milk", brand: nil, basis: .per100Unspecified, nutrients: [:])
        let full = LookedUpProduct(barcode: "2000000000015", name: "Oat Milk", brand: "Example Dairy", basis: .per100ml, nutrients: [:])
        let source = FakeDetailedSearch(full: full)
        let model = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: ProductSearchServicePort(), openFoodFacts: source, isSignedIn: { false })
        let opened = await model.openFoodFactsDetails(for: hit)
        XCTAssertEqual(opened, full)
        XCTAssertEqual(source.detailBarcodes, ["2000000000015"])
        XCTAssertNil(model.openingOpenFoodFactsBarcode)
    }

    @MainActor func testSourceWithoutFullRecordsOpensTheSearchResult() async {
        let hit = product("Oat Biscuit")
        let model = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: ProductSearchServicePort(), openFoodFacts: FakeNameSearch(outcome: .empty), isSignedIn: { false })
        let opened = await model.openFoodFactsDetails(for: hit)
        XCTAssertEqual(opened, hit)
    }

    @MainActor func testSecondPickWhileOneIsLoadingOpensNothing() async {
        let hit = product("Oat Biscuit")
        let source = FakeDetailedSearch(full: hit, hold: true)
        let model = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: ProductSearchServicePort(), openFoodFacts: source, isSignedIn: { false })
        let first = Task { @MainActor in await model.openFoodFactsDetails(for: hit) }
        while source.detailBarcodes.isEmpty { await Task.yield() }
        XCTAssertEqual(model.openingOpenFoodFactsBarcode, "2000000000015")
        let second = await model.openFoodFactsDetails(for: hit)
        XCTAssertNil(second)
        source.release()
        let opened = await first.value
        XCTAssertEqual(opened, hit)
        XCTAssertEqual(source.detailBarcodes.count, 1)
    }

    @MainActor func testNewSearchWhileAPickIsLoadingOpensNothing() async {
        let hit = product("Oat Biscuit")
        let source = FakeDetailedSearch(full: hit, hold: true)
        let model = CommunityProductSearchViewModel(store: ProductEditorStorePort(), service: ProductSearchServicePort(), openFoodFacts: source, isSignedIn: { false })
        let first = Task { @MainActor in await model.openFoodFactsDetails(for: hit) }
        while source.detailBarcodes.isEmpty { await Task.yield() }
        await model.search(query: "rice", kind: nil)
        XCTAssertNil(model.openingOpenFoodFactsBarcode)
        source.release()
        let opened = await first.value
        XCTAssertNil(opened)
    }

    @MainActor func testFailureIsUnavailableWithoutAffectingLocalResults() async throws {
        let store = ProductEditorStorePort()
        store.products = [syntheticCommunityRevision(name: "Synthetic oat", kind: .food)]
        let model = CommunityProductSearchViewModel(store: store, service: ProductSearchServicePort(), openFoodFacts: FakeNameSearch(outcome: .failed("offline")), isSignedIn: { true })
        await model.search(query: "oat", kind: nil)
        await model.openFoodFactsSearchFinished()
        XCTAssertEqual(model.openFoodFactsState, .unavailable)
        XCTAssertEqual(model.localResults.count, 1)
    }
}
