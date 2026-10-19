import Foundation
import NutritionDomain
import NutritionProviders
import NutritionUI

/// Name search for Find products over USDA FoodData Central and Open Food Facts together. Each source runs on
/// its own; a source that fails or is rate limited does not hide the other source's results.
struct FoodDatabaseSearch: ProductNameSearching {
    /// Results shown at most, across both sources.
    static let maxResults = 30

    private let openFoodFacts: any ProductNameSearching
    private let usda: (any ProductNameSearching)?

    init(openFoodFacts: any ProductNameSearching, usda: (any ProductNameSearching)?) {
        self.openFoodFacts = openFoodFacts
        self.usda = usda
    }

    func search(query: String) async -> ProductNameSearchOutcome {
        guard let usda else {
            return await openFoodFacts.search(query: query)
        }
        async let usdaOutcome = usda.search(query: query)
        async let offOutcome = openFoodFacts.search(query: query)
        let (usdaResult, offResult) = await (usdaOutcome, offOutcome)
        return Self.merge(usda: usdaResult, openFoodFacts: offResult)
    }

    /// Each source keeps half of the cap, so a broad USDA match cannot hide every Open Food Facts row. A
    /// source with fewer rows than its half leaves the spare slots to the other, USDA first. Within the
    /// result USDA rows come first. Duplicates are not removed; the two sources share no identifiers.
    static func merge(usda: ProductNameSearchOutcome, openFoodFacts: ProductNameSearchOutcome) -> ProductNameSearchOutcome {
        let usdaRows = rows(from: usda)
        let offRows = rows(from: openFoodFacts)
        // Open Food Facts keeps at most half the cap; USDA takes what remains, so USDA rows stay first
        // and no more than maxResults rows are returned.
        let offCount = min(offRows.count, maxResults / 2)
        let usdaCount = min(usdaRows.count, maxResults - offCount)
        let merged = Array(usdaRows.prefix(usdaCount)) + Array(offRows.prefix(maxResults - usdaCount))
        if !merged.isEmpty {
            return .results(merged)
        }
        for outcome in [usda, openFoodFacts] {
            switch outcome {
            case .rateLimited, .failed:
                return outcome
            case .results, .empty:
                continue
            }
        }
        return .empty
    }

    private static func rows(from outcome: ProductNameSearchOutcome) -> [LookedUpProduct] {
        if case .results(let products) = outcome { return products }
        return []
    }
}

extension USDAFoodDataClient: HouseholdPortionLookup {}

/// Adapts the USDA client to the name-search protocol. USDA has no barcodes, so rows carry an empty barcode,
/// which the draft stores as none.
struct USDAProductNameSearch: ProductNameSearching {
    static let attributionText = "Source: USDA FoodData Central, public domain."
    static let attributionURL = "https://fdc.nal.usda.gov/"
    static let catalogOrigin = "usda-fdc"
    static let gramsPerOunce = Decimal(string: "28.349523125")!

    private let client: USDAFoodDataClient

    init(client: USDAFoodDataClient) {
        self.client = client
    }

    func search(query: String) async -> ProductNameSearchOutcome {
        switch await client.search(query: query) {
        case .results(let foods):
            return .results(foods.map(Self.product(from:)))
        case .empty:
            return .empty
        case .queryTooLong:
            return .failed("That search is too long.")
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfterSeconds: retryAfter.map { max(1, Int(min($0, 86_400).rounded(.up))) })
        case .transport(let reason):
            return .failed(reason)
        }
    }

    static func product(from food: USDAFood) -> LookedUpProduct {
        LookedUpProduct(
            barcode: "",
            name: food.description,
            brand: food.brand,
            basis: .per100g,
            nutrients: food.nutrientsPer100g,
            attribution: ProductAttribution(source: catalogOrigin, text: attributionText, url: attributionURL),
            // The default serving is imperial: grams are converted to ounces for display and the amount stays
            // per 100 g internally.
            serving: food.servingGrams.map { ServingDefinition(quantity: $0 / Self.gramsPerOunce, unit: .oz, text: food.servingText) }
                ?? food.servingText.map { ServingDefinition(quantity: nil, unit: nil, text: $0) },
            version: nil,
            sourceID: String(food.fdcId))
    }
}
