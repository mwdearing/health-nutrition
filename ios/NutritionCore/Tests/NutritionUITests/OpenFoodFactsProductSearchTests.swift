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
            "Too many product searches just now. Try again in about 39 seconds.")
        XCTAssertEqual(
            CommunityProductSearchViewModel.openFoodFactsLimitText(retryAfterSeconds: 1),
            "Too many product searches just now. Try again in about 1 second.")
        XCTAssertEqual(
            CommunityProductSearchViewModel.openFoodFactsLimitText(retryAfterSeconds: nil),
            "Too many product searches just now. Try again in a minute.")
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
