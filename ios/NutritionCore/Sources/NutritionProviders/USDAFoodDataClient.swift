import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NutritionDomain

/// One food from a USDA FoodData Central name search. Nutrients are keyed by the nutrient keys the intake
/// form already uses; a nutrient FDC does not give is absent, which the caller reads as unknown.
public struct USDAFood: Sendable, Equatable {
    public let fdcId: Int
    public let description: String
    public let brand: String?
    public let dataType: String
    public let nutrientsPer100g: [String: NutrientValue]
    /// The gram weight of one labelled serving, when the record gives one (Branded foods do).
    public let servingGrams: Decimal?
    /// The source's own household wording, such as "1 cup" or "1 medium".
    public let servingText: String?
}

/// What a USDA name search returned. A query too short to search is answered `.empty` with no request sent.
public enum USDAFoodSearchOutcome: Sendable, Equatable {
    case results([USDAFood])
    case empty
    /// The query is longer than the search accepts; nothing was sent.
    case queryTooLong
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
}

/// Name search against USDA FoodData Central. The API key is sent in a header, never in the URL, so it
/// cannot end up in a logged or cached request line.
public actor USDAFoodDataClient {
    public static let searchURL = URL(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!
    /// Public-domain data sets only. Branded is included because it carries US label data.
    public static let dataTypes = ["Foundation", "SR Legacy", "Branded"]
    public static let searchPageSize = 20
    public static let searchMinimumCharacters = 2
    public static let searchMaximumCharacters = 80
    /// Search replies are small; a larger body is refused rather than parsed.
    public static let maxResponseBytes = 1 * 1_024 * 1_024

    /// FDC nutrient numbers mapped to the intake form's nutrient keys.
    static let nutrientKeys: [String: (key: String, unit: MeasureUnit)] = [
        "1008": ("energyKcal", .kcal),
        "1003": ("protein", .g),
        "1005": ("carbohydrates", .g),
        "2000": ("sugars", .g),
        "1004": ("fat", .g),
        "1258": ("saturatedFat", .g),
        "1079": ("fiber", .g),
        "1093": ("sodium", .mg),
    ]

    private let apiKey: String
    private let transport: OpenFoodFactsTransport

    public init(apiKey: String, transport: OpenFoodFactsTransport = URLSessionOpenFoodFactsTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func search(query: String) async -> USDAFoodSearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.searchMinimumCharacters else {
            return .empty
        }
        guard trimmed.count <= Self.searchMaximumCharacters else {
            return .queryTooLong
        }
        var components = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "dataType", value: Self.dataTypes.joined(separator: ",")),
            URLQueryItem(name: "pageSize", value: String(Self.searchPageSize)),
        ]
        guard let url = components?.url else {
            return .transport("could not build the request")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.get(request, maxBytes: Self.maxResponseBytes)
        } catch BoundedResponseError.responseTooLarge {
            return .transport("response exceeded the local size limit")
        } catch {
            return .transport("the USDA search could not be reached")
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
                .flatMap { $0 >= 0 ? $0 : nil }
            return .rateLimited(retryAfter: retry)
        case 401, 403:
            return .transport("the USDA key was refused")
        default:
            return .transport("HTTP \(response.statusCode)")
        }
        do {
            let foods = try Self.parse(data)
            return foods.isEmpty ? .empty : .results(foods)
        } catch {
            return .transport("the USDA reply could not be read")
        }
    }

    /// Turns a search reply into foods. Records without a description or FDC id are dropped.
    static func parse(_ data: Data) throws -> [USDAFood] {
        let reply = try JSONDecoder().decode(SearchReply.self, from: data)
        return (reply.foods ?? []).compactMap { food in
            guard let description = food.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty else {
                return nil
            }
            var nutrients: [String: NutrientValue] = [:]
            for nutrient in food.foodNutrients ?? [] {
                guard let number = nutrient.nutrientNumber,
                      let mapping = nutrientKeys[number],
                      let value = nutrient.value else {
                    continue
                }
                nutrients[mapping.key] = .known(value, mapping.unit)
            }
            let grams = food.servingSize.flatMap { $0 > 0 && food.servingSizeUnit?.lowercased() == "g" ? $0 : nil }
            let household = food.householdServingFullText?.trimmingCharacters(in: .whitespacesAndNewlines)
            return USDAFood(
                fdcId: food.fdcId,
                description: description,
                brand: [food.brandName, food.brandOwner]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty },
                dataType: food.dataType ?? "",
                nutrientsPer100g: nutrients,
                servingGrams: grams,
                servingText: household?.isEmpty == false ? household : nil)
        }
    }

    private struct SearchReply: Decodable {
        let foods: [Food]?
    }

    private struct Food: Decodable {
        let fdcId: Int
        let description: String?
        let dataType: String?
        let brandOwner: String?
        let brandName: String?
        let servingSize: Decimal?
        let servingSizeUnit: String?
        let householdServingFullText: String?
        let foodNutrients: [Nutrient]?
    }

    private struct Nutrient: Decodable {
        let nutrientNumber: String?
        let value: Decimal?
    }
}
