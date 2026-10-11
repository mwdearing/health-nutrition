import Foundation
import XCTest
@testable import NutritionProviders

final class CommunitySessionStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryCommunitySessionStore()
        XCTAssertNil(store.load())

        try store.save(testSession())
        XCTAssertEqual(store.load(), testSession())

        try store.clear()
        XCTAssertNil(store.load())
    }

    #if canImport(Security)
    func testKeychainStoreRoundTrip() throws {
        // A unique service per run, so a test never reads or deletes a real session.
        let store = KeychainCommunitySessionStore(service: "communityaccount-test-\(UUID().uuidString)")
        defer { try? store.clear() }
        XCTAssertNil(store.load())
        XCTAssertNoThrow(try store.clear(), "an absent disposable service is already cleared")

        try store.save(testSession())
        XCTAssertEqual(store.load(), testSession())

        XCTAssertNoThrow(try store.clear())
        XCTAssertNoThrow(try store.clear(), "repeated clear should accept item-not-found")
        XCTAssertNil(store.load())
    }

    func testKeychainClearAcceptsOnlySuccessAndItemNotFound() throws {
        XCTAssertNoThrow(try KeychainCommunitySessionStore.validateDeleteStatus(errSecSuccess))
        XCTAssertNoThrow(try KeychainCommunitySessionStore.validateDeleteStatus(errSecItemNotFound))
        XCTAssertThrowsError(try KeychainCommunitySessionStore.validateDeleteStatus(errSecAuthFailed)) { error in
            XCTAssertEqual(error as? CommunityError, .storage)
        }
    }
    #endif
}
