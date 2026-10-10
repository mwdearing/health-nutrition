import Foundation
import XCTest
@testable import NutritionProviders

final class CommunityConfigTests: XCTestCase {
    func testAcceptsSupabaseHTTPSHost() throws {
        let config = try XCTUnwrap(CommunityConfig(infoDictionary: testInfo()))
        XCTAssertEqual(config.baseURL.absoluteString, "https://example-ref.supabase.co")
        XCTAssertEqual(config.anonKey, "test-anon-key")
    }

    func testTrimsWhitespaceAroundValues() throws {
        let info = ["SUPABASE_URL": "  https://example-ref.supabase.co \n", "SUPABASE_ANON_KEY": " test-anon-key "]
        let config = try XCTUnwrap(CommunityConfig(infoDictionary: info))
        XCTAssertEqual(config.baseURL.absoluteString, "https://example-ref.supabase.co")
        XCTAssertEqual(config.anonKey, "test-anon-key")
    }

    func testRejectsPlainHTTP() {
        XCTAssertNil(CommunityConfig(infoDictionary: testInfo(url: "http://example-ref.supabase.co")))
    }

    func testRejectsOtherHosts() {
        let urls = [
            "https://example.com",
            "https://example-ref.supabase.co.attacker.example",
            "https://supabase.co",
            "https://example-ref.supabase.co:8443",
        ]
        for url in urls {
            XCTAssertNil(CommunityConfig(infoDictionary: testInfo(url: url)), url)
        }
    }

    func testRejectsBlankOrMissingValues() {
        XCTAssertNil(CommunityConfig(infoDictionary: testInfo(key: "   ")))
        XCTAssertNil(CommunityConfig(infoDictionary: testInfo(url: "")))
        XCTAssertNil(CommunityConfig(infoDictionary: ["SUPABASE_URL": "https://example-ref.supabase.co"]))
        XCTAssertNil(CommunityConfig(infoDictionary: nil))
    }
}
