import Foundation
import XCTest
@testable import NutritionProviders

final class CommunitySessionStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryCommunitySessionStore()
        XCTAssertNil(try store.load())

        try store.save(testSession())
        XCTAssertEqual(try store.load(), testSession())

        try store.clear()
        XCTAssertNil(try store.load())
    }

    #if canImport(Security)
    func testKeychainStoreRoundTrip() throws {
        // A unique service per run, so a test never reads or deletes a real session.
        let store = KeychainCommunitySessionStore(service: "communityaccount-test-\(UUID().uuidString)")
        defer { try? store.clear() }
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear(), "an absent disposable service is already cleared")

        try store.save(testSession())
        XCTAssertEqual(try store.load(), testSession())

        XCTAssertNoThrow(try store.clear())
        XCTAssertNoThrow(try store.clear(), "repeated clear should accept item-not-found")
        XCTAssertNil(try store.load())
    }

    func testKeychainClearAcceptsOnlySuccessAndItemNotFound() throws {
        XCTAssertNoThrow(try KeychainCommunitySessionStore.validateDeleteStatus(errSecSuccess))
        XCTAssertNoThrow(try KeychainCommunitySessionStore.validateDeleteStatus(errSecItemNotFound))
        XCTAssertThrowsError(try KeychainCommunitySessionStore.validateDeleteStatus(errSecAuthFailed)) { error in
            XCTAssertEqual(error as? CommunityError, .storage)
        }
    }

    func testKeychainLoadStatusAndPayloadDecoderDoesNotNeedInstalledCredentials() throws {
        XCTAssertNil(try KeychainCommunitySessionStore.decodeLoadResult(status: errSecItemNotFound, data: nil))

        for status in [errSecAuthFailed, errSecInteractionNotAllowed] {
            XCTAssertThrowsError(try KeychainCommunitySessionStore.decodeLoadResult(status: status, data: nil)) { error in
                XCTAssertEqual(error as? CommunityError, .storage)
            }
        }

        XCTAssertThrowsError(try KeychainCommunitySessionStore.decodeLoadResult(status: errSecSuccess, data: Data("invalid".utf8))) { error in
            XCTAssertEqual(error as? CommunityError, .storage)
        }

        let data = try JSONEncoder().encode(testSession())
        XCTAssertEqual(try KeychainCommunitySessionStore.decodeLoadResult(status: errSecSuccess, data: data), testSession())
    }
    #endif
}
