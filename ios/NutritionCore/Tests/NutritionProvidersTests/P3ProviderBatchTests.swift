import Foundation
import NutritionDomain
import XCTest
@testable import NutritionProviders

final class P3ProviderBatchTests: XCTestCase {
    func testAStatedZeroOnALabelIsKnownZero() throws {
        let json = """
            {"id":1,"fullName":"Zero","brandName":"Test","offMarket":0,
             "ingredientRows":[{"order":1,"name":"Vitamin C","forms":[],"nestedRows":[],
              "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":0,"unit":"mg"}]}]}
            """
        let label = try DSLDLabelAdapter().parse(Data(json.utf8))
        XCTAssertEqual(label.facts.first?.amount, .known(0, .mg))
    }

    func testAnOversizedReplyIsNotANetworkError() async throws {
        let body = String(repeating: "a", count: BoundedResponseLimits.community + 1)
        let transport = FakeCommunityTransport([.response(status: 200, body: body)])
        let community = CommunityClient(
            config: try makeConfig(), transport: transport,
            store: InMemoryCommunitySessionStore(testSession()), now: { testNow })
        await assertCommunityError(.responseTooLarge) { try await community.lookupLabel(barcode: "0123456070004") }
    }
}
