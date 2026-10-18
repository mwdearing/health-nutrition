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

    /// FDC nutrient IDs (the `nutrientId` field of a search record) mapped to the intake form's keys.
    /// `nutrientNumber` is a legacy code (203, 208, ...) and is not read.
    static let nutrientKeys: [Int: (key: String, unit: MeasureUnit)] = [
        1008: ("energyKcal", .kcal),
        1003: ("protein", .g),
        1005: ("carbohydrates", .g),
        2000: ("sugars", .g),
        1004: ("fat", .g),
        1258: ("saturatedFat", .g),
        1079: ("fiber", .g),
        1093: ("sodium", .mg),
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
        // Values are encoded by hand: URLComponents leaves "+" alone, and FDC reads a bare "+" as a space.
        let valueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? ""
        let encodedTypes = Self.dataTypes
            .map { $0.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? "" }
            .joined(separator: ",")
        var components = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedQueryItems = [
            URLQueryItem(name: "query", value: encodedQuery),
            URLQueryItem(name: "dataType", value: encodedTypes),
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
            guard data.count <= Self.maxResponseBytes else {
                return .transport("response exceeded the local size limit")
            }
        } catch BoundedResponseError.responseTooLarge {
            return .transport("response exceeded the local size limit")
        } catch {
            return .transport("the USDA search could not be reached")
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 429:
            return .rateLimited(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
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

    /// The household measures a USDA food lists with a gram weight: grams for one cup, tablespoon and teaspoon.
    /// A unit the record does not list is absent, and a failed request yields nothing, so logging never waits on it.
    public func listedPortions(fdcId: Int) async -> [MeasureUnit: Decimal] {
        guard let url = URL(string: "https://api.nal.usda.gov/fdc/v1/food/\(fdcId)") else { return [:] }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let reply: (Data, HTTPURLResponse)
        do {
            reply = try await transport.get(request, maxBytes: Self.maxResponseBytes)
        } catch {
            return [:]
        }
        let (data, response) = reply
        guard (200..<300).contains(response.statusCode) else { return [:] }
        return (try? Self.parsePortions(data)) ?? [:]
    }

    /// Reads foodPortions into grams per unit. Only cup, tablespoon and teaspoon are kept, the first listing of each.
    static func parsePortions(_ data: Data) throws -> [MeasureUnit: Decimal] {
        let reply = try JSONDecoder().decode(DetailReply.self, from: data)
        var grams: [MeasureUnit: Decimal] = [:]
        for portion in reply.foodPortions ?? [] {
            guard let weight = portion.gramWeight, weight > 0 else { continue }
            let amount = portion.amount ?? 1
            guard amount > 0 else { continue }
            let text = (portion.modifier ?? portion.measureUnit?.name ?? "").lowercased()
            let word = text.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
            let unit: MeasureUnit
            switch word {
            case "cup", "cups": unit = .cup
            case "tbsp", "tablespoon", "tablespoons": unit = .tablespoon
            case "tsp", "teaspoon", "teaspoons": unit = .teaspoon
            default: continue
            }
            if grams[unit] == nil { grams[unit] = weight / amount }
        }
        return grams
    }

    private struct DetailReply: Decodable {
        let foodPortions: [Portion]?
    }

    private struct Portion: Decodable {
        let amount: Decimal?
        let gramWeight: Decimal?
        let modifier: String?
        let measureUnit: MeasureUnitName?
    }

    private struct MeasureUnitName: Decodable {
        let name: String?
    }

    /// Retry-After is either delta-seconds or an HTTP date (RFC 9110). Negative, infinite or unreadable
    /// values give nil; a date already past gives zero.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(text) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }

    /// Turns a search reply into foods. Records without a description or FDC id are dropped.
    static func parse(_ data: Data) throws -> [USDAFood] {
        let reply = try JSONDecoder().decode(SearchReply.self, from: data)
        return (reply.foods ?? []).compactMap { food in
            guard let fdcId = food.fdcId else {
                return nil
            }
            guard let description = food.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty else {
                return nil
            }
            var nutrients: [String: NutrientValue] = [:]
            for nutrient in food.foodNutrients ?? [] {
                guard let id = nutrient.nutrientId,
                      let mapping = nutrientKeys[id],
                      let value = nutrient.value else {
                    continue
                }
                nutrients[mapping.key] = .known(value, mapping.unit)
            }
            let grams = food.servingSize.flatMap { $0 > 0 && food.servingSizeUnit?.lowercased() == "g" ? $0 : nil }
            let household = food.householdServingFullText?.trimmingCharacters(in: .whitespacesAndNewlines)
            return USDAFood(
                fdcId: fdcId,
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
        let fdcId: Int?
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
        let nutrientId: Int?
        let value: Decimal?
    }
}
