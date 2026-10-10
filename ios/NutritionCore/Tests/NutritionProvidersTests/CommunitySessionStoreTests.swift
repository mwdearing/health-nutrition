import Foundation
import XCTest
@testable import NutritionProviders

final class CommunitySessionStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryCommunitySessionStore()
        XCTAssertNil(store.load())

        try store.save(testSession())
        XCTAssertEqual(store.load(), testSession())

        store.clear()
        XCTAssertNil(store.load())
    }

    #if canImport(Security)
    func testKeychainStoreRoundTrip() throws {
        // A unique service per run, so a test never reads or deletes a real session.
        let store = KeychainCommunitySessionStore(service: "communityaccount-test-\(UUID().uuidString)")
        defer { store.clear() }
        XCTAssertNil(store.load())

        try store.save(testSession())
        XCTAssertEqual(store.load(), testSession())

        store.clear()
        XCTAssertNil(store.load())
    }
    #endif
}
