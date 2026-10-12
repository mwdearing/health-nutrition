import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import NutritionProviders

/// Exercises the v2 raw path: authorization failures must not revive a dead session or erase a newer one.
final class SharedProductIntegrationTests: XCTestCase {
    func testDefiniteSessionRejectionInvalidatesOnlyMatchingV2Credentials() async throws {
        for (status, body) in [(401, "{}"), (403, #"{"code":"28000"}"#)] {
            let store = InMemoryCommunitySessionStore(testSession())
            let client = CommunityClient(config: try makeConfig(), transport: FakeCommunityTransport([
                .response(status: status, body: body)
            ]), store: store, now: { testNow })
            do { _ = try await client.capabilities(); XCTFail("expected rejection") }
            catch { XCTAssertEqual(error as? ProductAPIError, .unauthorized) }
            XCTAssertNil(try store.load(), "A definite v2 session rejection must clear its token")
        }
    }

    func testDelayedV2RejectionAndReplacementSignInInBothResponseOrders() async throws {
        for status in [401, 403] {
            for rejectionFirst in [false, true] {
                let store = InMemoryCommunitySessionStore(testSession())
                let transport = LifecycleTransport(gated: ["profile", "signin"], profileStatus: status)
                let client = CommunityClient(config: try makeConfig(), transport: transport, store: store, now: { testNow })
                let old = Task { try await client.capabilities() }
                await transport.waitFor("profile")
                let replacement = Task { try await client.auth.signInWithApple(idToken: "synthetic", nonce: "synthetic") }
                await transport.waitFor("signin")
                if rejectionFirst {
                    transport.release("profile")
                    do { _ = try await old.value; XCTFail("expected old rejection") }
                    catch { XCTAssertEqual(error as? ProductAPIError, .unauthorized) }
                    XCTAssertNil(try store.load())
                }
                transport.release("signin")
                let newer = try await replacement.value
                if !rejectionFirst {
                    transport.release("profile")
                    do { _ = try await old.value; XCTFail("expected old rejection") }
                    catch { XCTAssertEqual(error as? ProductAPIError, .unauthorized) }
                }
                XCTAssertEqual(try store.load(), newer)
            }
        }
    }

    func testRawCommunityAPIRejectsOversizedInjectedReply() async throws {
        let api = CommunityAPI(config: try makeConfig(), transport: FakeCommunityTransport([
            .response(status: 200, body: String(repeating: "x", count: 1_048_577))
        ]))
        await assertCommunityError(.network) { try await api.raw("/rest/v1/rpc/catalog_capabilities_v2") }
    }

    func testOrdinaryForbiddenAndTypedConsentRetainV2Credentials() async throws {
        for (status, body) in [(403, "{}"), (403, #"{"code":"42501"}"#),
            (400, #"{"code":"P0001","details":"{\"code\":\"consent_required\",\"consent_generation\":\"2\"}"}"#),
            (400, #"{"code":"P0001","details":"{\"code\":\"unauthorized\"}"}"#)] {
            let store = InMemoryCommunitySessionStore(testSession())
            let client = CommunityClient(config: try makeConfig(), transport: FakeCommunityTransport([
                .response(status: status, body: body)
            ]), store: store, now: { testNow })
            do { _ = try await client.capabilities(); XCTFail("expected rejection") } catch {}
            XCTAssertEqual(try store.load(), testSession())
        }
    }
}
