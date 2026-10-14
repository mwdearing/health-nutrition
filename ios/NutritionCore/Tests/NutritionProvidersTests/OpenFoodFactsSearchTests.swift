import Foundation
import XCTest
@testable import NutritionProviders

final class OpenFoodFactsSearchTests: XCTestCase {
    private let twoProducts = Data("""
    {"count": 2, "page": 1, "page_size": 20, "hits": [
      {"code": "2000000000015", "product_name": "Oat Biscuit", "brands": ["Example Foods", " Example Bakery", " "],
       "last_modified_t": 1800000000,
       "nutriments": {"energy-kcal_100g": 450, "proteins_100g": "7.5"}},
      {"code": "2000000000022", "product_name": "Oat Milk", "brands": "Example Dairy", "nutriments": {}}
    ]}
    """.utf8)

    /// Seven queries the client treats as different searches that all match the fixture's names.
    private static let distinctOatQueries = ["oat", "Oat", "OAT", "oAt", "oaT", "OAt", "oAT"]

    private func client(_ transport: any OpenFoodFactsTransport, clock: TestClock = TestClock()) -> OpenFoodFactsClient {
        OpenFoodFactsClient(
            environment: .production, transport: transport, appVersion: "1.0.0",
            now: { clock.now() }, monotonic: { clock.uptime() })
    }

    private func queryItems(of request: URLRequest) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            items[item.name] = item.value
        }
        return items
    }

    func testSearchParsesResults() async throws {
        let transport = StubTransport(body: twoProducts)
        let outcome = await client(transport).search(query: "oat")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000015", "2000000000022"])
        XCTAssertEqual(products.first?.name, "Oat Biscuit")
        XCTAssertEqual(products.first?.brands, "Example Foods, Example Bakery")
        XCTAssertEqual(products.last?.brands, "Example Dairy")
        // The search index does not say whether the figures are per 100 g or per 100 ml.
        XCTAssertEqual(products.map(\.basis), [.per100Unspecified, .per100Unspecified])
        XCTAssertEqual(products.first?.nutrients[OpenFoodFactsProduct.energyKcal], .known(450, .kcal))
        XCTAssertEqual(products.first?.nutrients[OpenFoodFactsProduct.fat], .unknown)
        XCTAssertEqual(products.first?.lastModified, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testSearchDropsResultsWithoutAName() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "brands": ["Example Foods"], "nutriments": {}},
          {"code": "2000000000022", "product_name": "   ", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Oat Milk", "nutriments": {}}
        ]}
        """.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "oat")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000039"])
    }

    func testSearchKeepsTheFirstOfResultsWithTheSameNameAndBrand() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Oat Milk", "brands": ["Example Dairy"], "nutriments": {}},
          {"code": "2000000000022", "product_name": "oat milk ", "brands": "example dairy", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Oat Milk", "brands": ["Other Dairy"], "nutriments": {}},
          {"code": "2000000000046", "product_name": "Oat Milk", "nutriments": {}}
        ]}
        """.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "oat")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000015", "2000000000039", "2000000000046"])
    }

    /// The service also matches on category, label and names in other languages. Only rows that show
    /// every typed word are kept: the name first, then name and brand together, in the service's order.
    func testOnlyResultsShowingEveryWordAreKeptNameMatchesFirst() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Leche Entera", "brands": ["Oat Milk Co"], "nutriments": {}},
          {"code": "2000000000022", "product_name": "Organic OAT Drink, Mílk style", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Milk", "nutriments": {}},
          {"code": "2000000000046", "product_name": "Oat-Milk Barista", "nutriments": {}},
          {"code": "2000000000053", "product_name": "Barista Blend", "brands": "Example Oat", "nutriments": {}}
        ]}
        """.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "Oat milk")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000022", "2000000000046", "2000000000015"])
    }

    func testPluralAndSingularFormsOfAWordStillMatch() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Apple Juice", "nutriments": {}},
          {"code": "2000000000022", "product_name": "Large Egg", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Dried apples", "nutriments": {}}
        ]}
        """.utf8)
        let apples = await client(StubTransport(body: body)).search(query: "apples")
        guard case .results(let appleRows) = apples else {
            return XCTFail("expected results, got \(apples)")
        }
        XCTAssertEqual(appleRows.map(\.barcode), ["2000000000015", "2000000000039"])
        let eggs = await client(StubTransport(body: body)).search(query: "eggs")
        guard case .results(let eggRows) = eggs else {
            return XCTFail("expected results, got \(eggs)")
        }
        XCTAssertEqual(eggRows.map(\.barcode), ["2000000000022"])
    }

    /// A typed word has to begin a word in the name or brand. A word that only appears inside another
    /// word ("ham" in "Champagne") or shares its first letters with a different word ("milk" and
    /// "Millet") is not a match.
    func testTypedWordsMustBeginAShownWord() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Champagne Brut", "nutriments": {}},
          {"code": "2000000000022", "product_name": "Ham slices", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Millet flakes", "nutriments": {}},
          {"code": "2000000000046", "product_name": "Whole milk", "nutriments": {}},
          {"code": "2000000000053", "product_name": "Hamburger buns", "nutriments": {}},
          {"code": "2000000000060", "product_name": "Oatmilk", "nutriments": {}}
        ]}
        """.utf8)
        let ham = await client(StubTransport(body: body)).search(query: "ham")
        guard case .results(let hamRows) = ham else {
            return XCTFail("expected results, got \(ham)")
        }
        XCTAssertEqual(hamRows.map(\.barcode), ["2000000000022", "2000000000053"])
        let milk = await client(StubTransport(body: body)).search(query: "milk")
        guard case .results(let milkRows) = milk else {
            return XCTFail("expected results, got \(milk)")
        }
        XCTAssertEqual(milkRows.map(\.barcode), ["2000000000046"])
    }

    /// Singular candidates are compared only as whole words, so extra candidates cannot start unrelated
    /// words; the typed word itself still matches the start of a shown word.
    func testSingularCandidates() {
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("cookies").isSuperset(of: ["cookies", "cookie"]))
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("berries").contains("berry"))
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("chilies").contains("chili"))
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("loaves").contains("loaf"))
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("knives").contains("knife"))
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("tomatoes").contains("tomato"))
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("cases").contains("case"))
        XCTAssertTrue(OpenFoodFactsSearchWords.forms("glasses").contains("glass"))
        XCTAssertEqual(OpenFoodFactsSearchWords.forms("glass"), ["glass"])
        // "-es" comes off only where English adds it, so no short foreign word is guessed.
        XCTAssertEqual(OpenFoodFactsSearchWords.forms("cones"), ["cones", "cone"])
        XCTAssertEqual(OpenFoodFactsSearchWords.forms("ales"), ["ales", "ale"])
        XCTAssertEqual(OpenFoodFactsSearchWords.forms("milk"), ["milk"])
    }

    func testWordsAreWrittenTheSameWayOnBothSides() {
        XCTAssertEqual(OpenFoodFactsSearchWords.words("Ben & Jerry’s"), ["ben", "and", "jerrys"])
        XCTAssertEqual(OpenFoodFactsSearchWords.words("Kellogg's Corn-Flakes"), ["kelloggs", "corn", "flakes"])
        XCTAssertEqual(OpenFoodFactsSearchWords.words("Œufs Bœuf Smør Æbleskiver Straße"), ["oeufs", "boeuf", "smor", "aebleskiver", "strasse"])
        XCTAssertEqual(OpenFoodFactsSearchWords.words("Crème Brûlée 2%"), ["creme", "brulee", "2"])
        XCTAssertEqual(OpenFoodFactsSearchWords.words(".. %% ’’"), [])
        XCTAssertEqual(OpenFoodFactsSearchWords.words("ＫＩＴ　ＫＡＴ ５００ｍｌ"), ["kit", "kat", "500ml"])
    }

    /// Cases an independent review found: the row shows the typed words in its own notation and is kept,
    /// or it only shares a short stem and is dropped.
    func testRowsAreKeptWhenTheyShowTheWordsInTheirOwnNotation() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Macaroni & Cheese Dinner", "nutriments": {}},
          {"code": "2000000000022", "product_name": "Kelloggs Corn Flakes", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Œufs frais", "nutriments": {}},
          {"code": "2000000000046", "product_name": "希腊酸奶", "nutriments": {}},
          {"code": "2000000000053", "product_name": "นมถั่วเหลือง", "nutriments": {}},
          {"code": "2000000000060", "product_name": "Sourdough Loaf", "nutriments": {}},
          {"code": "2000000000077", "product_name": "Chili Garlic Sauce", "nutriments": {}},
          {"code": "2000000000084", "product_name": "Friendly Farms Oat Milk", "nutriments": {}},
          {"code": "2000000000091", "product_name": "Plum Jam", "nutriments": {}},
          {"code": "2000000000107", "product_name": "Cashew Nuts", "nutriments": {}},
          {"code": "2000000000114", "product_name": "Pencil Case Cookies", "nutriments": {}},
          {"code": "2000000000121", "product_name": "Ben & Jerry's Chunky Monkey", "nutriments": {}}
        ]}
        """.utf8)
        let cases: [(query: String, barcodes: [String])] = [
            ("mac and cheese", ["2000000000015"]),
            ("Kellogg's", ["2000000000022"]),
            ("oeufs", ["2000000000039"]),
            ("酸奶", ["2000000000046"]),
            ("ถั่วเหลือง", ["2000000000053"]),
            ("loaves", ["2000000000060"]),
            ("chilies", ["2000000000077"]),
            ("fries", []),
            ("plus", []),
            ("cases", ["2000000000114"]),
            ("ben and jerry's", ["2000000000121"]),
            ("ｍａｃ and cheese", ["2000000000015"]),
        ]
        for entry in cases {
            let outcome = await client(StubTransport(body: body)).search(query: entry.query)
            switch outcome {
            case .results(let rows): XCTAssertEqual(rows.map(\.barcode), entry.barcodes, entry.query)
            case .empty: XCTAssertEqual([], entry.barcodes, entry.query)
            default: XCTFail("unexpected \(outcome) for \(entry.query)")
            }
        }
    }

    func testShortGuessesDoNotKeepForeignWords() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Chili con carne", "nutriments": {}},
          {"code": "2000000000022", "product_name": "Pasta al pomodoro", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Waffle Cones", "nutriments": {}}
        ]}
        """.utf8)
        for (query, barcodes) in [("cones", ["2000000000039"]), ("ales", [String]())] {
            let outcome = await client(StubTransport(body: body)).search(query: query)
            switch outcome {
            case .results(let rows): XCTAssertEqual(rows.map(\.barcode), barcodes, query)
            case .empty: XCTAssertEqual([], barcodes, query)
            default: XCTFail("unexpected \(outcome) for \(query)")
            }
        }
    }

    func testTypedAmpersandStillRequiresAnd() async throws {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Mac Cheese Dinner", "nutriments": {}},
          {"code": "2000000000022", "product_name": "Mac & Cheese Dinner", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Mac and Cheese", "nutriments": {}}
        ]}
        """.utf8)
        let transport = StubTransport(body: body)
        let outcome = await client(transport).search(query: "mac & cheese")
        guard case .results(let rows) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(rows.map(\.barcode), ["2000000000022", "2000000000039"])
        let items = try queryItems(of: try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(items["q"], "mac and cheese")
    }

    func testBlankBrandIsNoBrand() async {
        let body = Data(#"{"hits": [{"code": "2000000000015", "product_name": "Oat Drink", "brands": "   ", "nutriments": {}}]}"#.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "oat")
        guard case .results(let rows) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertNil(rows.first?.brands)
    }

    func testTextWithNoWordsSendsNothing() async {
        let transport = StubTransport(body: twoProducts)
        for query in ["..", "%%", "’’", "__ __"] {
            let outcome = await client(transport).search(query: query)
            XCTAssertEqual(outcome, .empty, query)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCapIsAppliedAfterSyntaxIsRemoved() async throws {
        let transport = StubTransport(body: twoProducts)
        _ = await client(transport).search(query: String(repeating: "=", count: 80) + " milk")
        let items = try queryItems(of: try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(items["q"], "milk")
    }

    func testOneMalformedHitDoesNotDiscardTheReply() async {
        let body = Data("""
        {"hits": [
          null,
          {"code": "2000000000015", "product_name": "Oat Milk One", "nutriments": []},
          {"code": "2000000000022", "product_name": "Oat Milk Two", "brands": ["Example", null, 7, " Dairy "], "nutriments": {}},
          "not a hit"
        ]}
        """.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "oat milk")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000015", "2000000000022"])
        XCTAssertEqual(products.last?.brands, "Example, Dairy")
        XCTAssertEqual(products.first?.nutrients[OpenFoodFactsProduct.energyKcal], .unknown)
    }

    func testPluralSearchDoesNotKeepWordsSharingOnlyAStem() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Cooking Chocolate", "nutriments": {}},
          {"code": "2000000000022", "product_name": "Butter Cookie", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Spicy Chicken", "nutriments": {}},
          {"code": "2000000000046", "product_name": "Mixed Spice", "nutriments": {}},
          {"code": "2000000000053", "product_name": "Applesauce", "nutriments": {}},
          {"code": "2000000000060", "product_name": "Canned Peach Halves", "nutriments": {}}
        ]}
        """.utf8)
        let cases: [(query: String, barcodes: [String])] = [
            ("cookies", ["2000000000022"]),
            ("spices", ["2000000000046"]),
            ("apples", ["2000000000053"]),
            ("peaches", ["2000000000060"]),
        ]
        for entry in cases {
            let outcome = await client(StubTransport(body: body)).search(query: entry.query)
            guard case .results(let rows) = outcome else {
                XCTFail("expected results for \(entry.query), got \(outcome)")
                continue
            }
            XCTAssertEqual(rows.map(\.barcode), entry.barcodes, entry.query)
        }
    }

    /// A plural and its singular match in either direction.
    func testPluralEndingsAreRemovedOnBothSides() async {
        let body = Data("""
        {"hits": [
          {"code": "2000000000015", "product_name": "Mixed Berry Jam", "nutriments": {}},
          {"code": "2000000000022", "product_name": "Tomato Soup", "nutriments": {}},
          {"code": "2000000000039", "product_name": "Rolled Oats", "nutriments": {}},
          {"code": "2000000000046", "product_name": "Glass Noodles", "nutriments": {}},
          {"code": "2000000000053", "product_name": "Chocolate Chip Cookie", "nutriments": {}},
          {"code": "2000000000060", "product_name": "Blueberries", "nutriments": {}}
        ]}
        """.utf8)
        let cases: [(query: String, barcodes: [String])] = [
            ("berries", ["2000000000015"]),
            ("berry", ["2000000000015"]),
            ("tomatoes", ["2000000000022"]),
            ("oat", ["2000000000039"]),
            ("glass noodle", ["2000000000046"]),
            ("cookies", ["2000000000053"]),
            ("blueberry", ["2000000000060"]),
        ]
        for entry in cases {
            let outcome = await client(StubTransport(body: body)).search(query: entry.query)
            guard case .results(let rows) = outcome else {
                XCTFail("expected results for \(entry.query), got \(outcome)")
                continue
            }
            XCTAssertEqual(rows.map(\.barcode), entry.barcodes, entry.query)
        }
    }

    func testSearchWhereNoResultShowsTheWordsIsEmpty() async {
        let body = Data(#"{"hits": [{"code": "2000000000015", "product_name": "Perly", "brands": ["Example Dairy"], "nutriments": {}}]}"#.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "milk")
        XCTAssertEqual(outcome, .empty)
    }

    func testSearchWithOnlyUnnamedResultsIsEmpty() async {
        let body = Data(#"{"hits": [{"code": "2000000000015", "nutriments": {}}]}"#.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "oat")
        XCTAssertEqual(outcome, .empty)
    }

    func testSearchDropsProductsWithMalformedBarcodes() async throws {
        let body = Data("""
        {"count": 3, "hits": [
          {"code": "not-a-code", "product_name": "Bad Code", "nutriments": {}},
          {"code": "2000000000015", "product_name": "Oat Biscuit", "nutriments": {}},
          {"code": "2000000000016", "product_name": "Wrong Check Digit", "nutriments": {}},
          {"code": " 2000000000022 ", "product_name": "Padded Code", "nutriments": {}}
        ]}
        """.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "oat")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000015"])
    }

    func testSearchWithNoProductsIsEmpty() async {
        let transport = StubTransport(body: Data(#"{"count": 0, "hits": []}"#.utf8))
        let outcome = await client(transport).search(query: "zzqqxx")
        XCTAssertEqual(outcome, .empty)
    }

    func testSearchRateLimitedOn429() async {
        let transport = StubTransport(status: 429, headers: ["Retry-After": "30"])
        let outcome = await client(transport).search(query: "oat")
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 30))
    }

    func testSearchServerErrorIsTransport() async {
        let transport = StubTransport(status: 500)
        let outcome = await client(transport).search(query: "oat")
        guard case .transport = outcome else {
            return XCTFail("expected transport, got \(outcome)")
        }
    }

    func testQueryTooShortIsNotSent() async {
        let transport = StubTransport(body: twoProducts)
        let outcome = await client(transport).search(query: "  a  ")
        XCTAssertEqual(outcome, .empty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRequestGoesToTheSearchServiceWithOnlyTheTypedWords() async throws {
        let transport = StubTransport(body: twoProducts)
        _ = await client(transport).search(query: "  oat   honey 2%  ")
        let request = try XCTUnwrap(transport.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "search.openfoodfacts.org")
        XCTAssertEqual(url.path, "/search")
        let items = try queryItems(of: request)
        XCTAssertEqual(Set(items.keys), ["q", "page_size", "fields"])
        XCTAssertEqual(items["q"], "oat honey 2%")
        XCTAssertEqual(items["page_size"], "20")
        XCTAssertEqual(items["fields"], "code,product_name,brands,nutriments,last_modified_t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("HealthNutrition/1.0.0"), true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// The service reads `q` as a query language. Typed text must stay plain words: no field filters,
    /// operators, ranges, wildcards or negation can be formed from what a person types.
    func testQuerySyntaxCharactersAndOperatorWordsAreNeutralized() async throws {
        let cases: [(typed: String, sent: String)] = [
            ("c++ oat & honey", "c oat and honey"),
            ("countries_tags:\"en:france\"", "countries_tags en france"),
            ("milk AND NOT (soy OR oat)", "milk and not soy or oat"),
            ("-milk +oat", "milk oat"),
            ("half-and-half", "half and half"),
            ("code:[0 TO 9]", "code 0 to 9"),
            ("mil* ch?ese~2 oat^5", "mil ch ese 2 oat 5"),
            ("a\\b /regex/ {x} !y || z && w", "a b regex x y z w"),
            ("crème fraîche 2%", "crème fraîche 2%"),
        ]
        for entry in cases {
            let transport = StubTransport(body: twoProducts)
            _ = await client(transport).search(query: entry.typed)
            let items = try queryItems(of: try XCTUnwrap(transport.requests.first, entry.typed))
            XCTAssertEqual(items["q"], entry.sent, entry.typed)
        }
    }

    func testQueryThatIsOnlySyntaxIsNotSent() async {
        let transport = StubTransport(body: twoProducts)
        let outcome = await client(transport).search(query: "(*) && \"-\"")
        XCTAssertEqual(outcome, .empty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testEnvironmentWithoutASearchServiceSendsNothing() async {
        let transport = StubTransport(body: twoProducts)
        let model = OpenFoodFactsClient(
            environment: .staging(authorization: "Basic synthetic"), transport: transport, appVersion: "1.0.0")
        let outcome = await model.search(query: "oat")
        guard case .transport = outcome else {
            return XCTFail("expected transport, got \(outcome)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testQueryIsCappedAtEightyCharacters() async throws {
        let transport = StubTransport(body: twoProducts)
        let long = String(repeating: "b", count: 120)
        _ = await client(transport).search(query: long)
        let items = try queryItems(of: try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(items["q"], String(repeating: "b", count: 80))
    }

    func testSixSearchesPerMinuteThenRateLimited() async {
        let transport = StubTransport(body: twoProducts)
        let model = client(transport)
        for index in 0..<6 {
            guard case .results = await model.search(query: Self.distinctOatQueries[index]) else {
                return XCTFail("expected results inside the limit")
            }
        }
        let outcome = await model.search(query: Self.distinctOatQueries[6])
        guard case .rateLimited(let retryAfter) = outcome else {
            return XCTFail("expected rate limit, got \(outcome)")
        }
        XCTAssertEqual(retryAfter, 60)
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testRepeatedSearchIsAnsweredWithoutAnotherRequest() async {
        let transport = StubTransport(body: twoProducts)
        let model = client(transport)
        let first = await model.search(query: "oat")
        for _ in 0..<8 {
            let repeated = await model.search(query: "  oat ")
            XCTAssertEqual(repeated, first)
        }
        XCTAssertEqual(transport.requests.count, 1)
        // The repeats spent nothing: five more different searches still fit in the same minute.
        for index in 1...5 {
            guard case .results = await model.search(query: Self.distinctOatQueries[index]) else {
                return XCTFail("a repeated search spent a rate-limit slot")
            }
        }
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testRepeatedSearchIsSentAgainAfterTheWindow() async {
        let transport = StubTransport(body: twoProducts)
        let clock = TestClock()
        let model = client(transport, clock: clock)
        _ = await model.search(query: "oat")
        clock.advance(60)
        _ = await model.search(query: "oat")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testFailedSearchIsNotRemembered() async {
        let transport = StubTransport(status: 500)
        let model = client(transport)
        _ = await model.search(query: "oat")
        _ = await model.search(query: "oat")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testSameSearchWhileOneIsRunningSharesItsRequest() async {
        let transport = GatedTransport(body: twoProducts)
        let model = client(transport)
        async let first = model.search(query: "oat")
        await transport.waitForRequests(1)
        async let second = model.search(query: "oat")
        // Give the second call time to reach the client before the reply is released.
        for _ in 0..<50 { await Task.yield() }
        transport.release()
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes[0], outcomes[1])
        guard case .results = outcomes[0] else {
            return XCTFail("expected results, got \(outcomes[0])")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testCancelledCallerStillLetsARepeatUseTheReply() async {
        let transport = GatedTransport(body: twoProducts)
        let model = client(transport)
        let abandoned = Task { await model.search(query: "oat") }
        await transport.waitForRequests(1)
        abandoned.cancel()
        transport.release()
        _ = await abandoned.value
        guard case .results = await model.search(query: "oat") else {
            return XCTFail("expected the reply to the abandoned search to be reused")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testSearch503WithoutRetryAfterIsUnavailableNotRateLimited() async {
        let outcome = await client(StubTransport(status: 503)).search(query: "oat")
        guard case .transport = outcome else {
            return XCTFail("expected transport, got \(outcome)")
        }
    }

    func testSearch503WithRetryAfterIsRateLimited() async {
        let transport = StubTransport(status: 503, headers: ["Retry-After": "30"])
        let outcome = await client(transport).search(query: "oat")
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 30))
    }
}

/// Holds every request open until `release()` is called, so a test can act while a search is running.
private final class GatedTransport: OpenFoodFactsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var count = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(body: Data) {
        self.body = body
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func waitForRequests(_ wanted: Int) async {
        while requestCount < wanted { await Task.yield() }
    }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = lock.withLock { () -> Bool in
                count += 1
                if !released { waiting.append(continuation) }
                return released
            }
            if open { continuation.resume() }
        }
        try Task.checkCancellation()
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
