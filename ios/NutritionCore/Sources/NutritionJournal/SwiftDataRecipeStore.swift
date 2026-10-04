import Foundation
import NutritionDomain
import SwiftData

@Model
final class RecipeVersionRecord {
    var recipeID: String
    var number: Int
    var title: String
    var notes: String
    /// JSON of the ingredients and yield; every decimal is POSIX text.
    var payloadJSON: String
    var createdAt: Date

    init(recipeID: String, number: Int, title: String, notes: String, payloadJSON: String, createdAt: Date) {
        self.recipeID = recipeID
        self.number = number
        self.title = title
        self.notes = notes
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

@Model
final class RecipeTombstoneRecord {
    var recipeID: String
    var deletedAt: Date

    init(recipeID: String, deletedAt: Date) {
        self.recipeID = recipeID
        self.deletedAt = deletedAt
    }
}

private struct NutrientDTO: Codable {
    var id: String
    /// "known", "unknown", "notApplicable" or "belowThreshold".
    var state: String
    var valueText: String?
    var unitSymbol: String?
}

private struct IngredientDTO: Codable {
    var id: String
    var name: String
    var amountText: String
    var unitSymbol: String
    var basisSymbol: String?
    var densityText: String?
    var sourceNote: String?
    var nutrients: [NutrientDTO]
}

private struct YieldDTO: Codable {
    /// "servings" or "total".
    var kind: String
    var amountText: String
    var unitSymbol: String?
}

private struct PayloadDTO: Codable {
    var ingredients: [IngredientDTO]
    var yield: YieldDTO
}

/// Recipes in their own store file; the URL is injected. Nothing here is shared or synced.
public final class SwiftDataRecipeStore: RecipeStore, @unchecked Sendable {
    private let lock = NSLock()
    /// Held across each whole write so two saves never read the same latest number.
    private let writeLock = NSLock()
    private var container: ModelContainer?

    public init(url: URL) throws {
        let schema = Schema([RecipeVersionRecord.self, RecipeTombstoneRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: configuration)
    }

    public func close() {
        lock.withLock { container = nil }
    }

    private func openContainer() throws -> ModelContainer {
        try lock.withLock {
            guard let container else { throw RecipeStoreError.closed }
            return container
        }
    }

    public func saveNewVersion(_ version: RecipeVersion) throws {
        try version.validate()
        let payload = try Self.encodePayload(version)
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        let id = version.recipeID
        let tombstones = try context.fetch(FetchDescriptor<RecipeTombstoneRecord>(
            predicate: #Predicate<RecipeTombstoneRecord> { $0.recipeID == id }))
        guard tombstones.isEmpty else { throw RecipeStoreError.recipeDeleted(id) }
        let rows = try context.fetch(FetchDescriptor<RecipeVersionRecord>(
            predicate: #Predicate<RecipeVersionRecord> { $0.recipeID == id }))
        let latest = rows.map { $0.number }.max() ?? 0
        guard version.number == latest + 1 else {
            throw RecipeStoreError.versionConflict(expected: latest + 1, got: version.number)
        }
        context.insert(RecipeVersionRecord(
            recipeID: id, number: version.number, title: version.title, notes: version.notes,
            payloadJSON: payload, createdAt: version.createdAt))
        try context.save()
    }

    /// Every stored version is decoded, not only the newest one of each recipe: a row that cannot be
    /// read is skipped and counted wherever it sits in a recipe's history, because editing a recipe
    /// reads every version. The recipe stays visible on its newest version that can be read.
    public func list() throws -> RecipeListResult {
        let context = ModelContext(try openContainer())
        let tombstones = try context.fetch(FetchDescriptor<RecipeTombstoneRecord>())
        let hidden = Set(tombstones.map { $0.recipeID })
        let rows = try context.fetch(FetchDescriptor<RecipeVersionRecord>())
        var latestByRecipe: [String: RecipeVersion] = [:]
        var skipped = 0
        for row in rows where !hidden.contains(row.recipeID) {
            guard let decoded = try? Self.decode(row) else {
                skipped += 1
                continue
            }
            if let current = latestByRecipe[decoded.recipeID], current.number >= decoded.number { continue }
            latestByRecipe[decoded.recipeID] = decoded
        }
        var recipes = Array(latestByRecipe.values)
        recipes.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.recipeID < $1.recipeID
        }
        return RecipeListResult(recipes: recipes, skippedCount: skipped)
    }

    public func version(recipeID: String, number: Int) throws -> RecipeVersion? {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<RecipeVersionRecord>(
            predicate: #Predicate<RecipeVersionRecord> { $0.recipeID == recipeID && $0.number == number }))
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// Every readable version, oldest first. A row that cannot be decoded is skipped like everywhere
    /// else, so one damaged version in a recipe's history does not stop the next one from being
    /// written; `list()` counts the rows it skips.
    public func versions(of recipeID: String) throws -> [RecipeVersion] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<RecipeVersionRecord>(
            predicate: #Predicate<RecipeVersionRecord> { $0.recipeID == recipeID },
            sortBy: [SortDescriptor(\.number)]))
        return rows.compactMap { try? Self.decode($0) }
    }

    public func deleteRecipe(id: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        let existing = try context.fetch(FetchDescriptor<RecipeTombstoneRecord>(
            predicate: #Predicate<RecipeTombstoneRecord> { $0.recipeID == id }))
        guard existing.isEmpty else { return }
        context.insert(RecipeTombstoneRecord(recipeID: id, deletedAt: Date()))
        try context.save()
    }

    /// Writes a row as given, bypassing validation, so tests can hold stored data the app would never write.
    func insertRawRowForTesting(recipeID: String, number: Int, title: String, payloadJSON: String, createdAt: Date) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        context.insert(RecipeVersionRecord(
            recipeID: recipeID, number: number, title: title, notes: "", payloadJSON: payloadJSON, createdAt: createdAt))
        try context.save()
    }

    // MARK: Encoding

    private static func encodePayload(_ version: RecipeVersion) throws -> String {
        let ingredients = version.ingredients.map { ingredient -> IngredientDTO in
            let nutrients = ingredient.perUnit.keys.sorted().map { key -> NutrientDTO in
                switch ingredient.perUnit[key] ?? .unknown {
                case .known(let amount, let unit):
                    return NutrientDTO(id: key, state: "known", valueText: DecimalText.encode(amount), unitSymbol: unit.symbol)
                case .unknown:
                    return NutrientDTO(id: key, state: "unknown", valueText: nil, unitSymbol: nil)
                case .notApplicable:
                    return NutrientDTO(id: key, state: "notApplicable", valueText: nil, unitSymbol: nil)
                case .belowReportingThreshold(let unit):
                    return NutrientDTO(id: key, state: "belowThreshold", valueText: nil, unitSymbol: unit?.symbol)
                }
            }
            return IngredientDTO(
                id: ingredient.id, name: ingredient.name,
                amountText: DecimalText.encode(ingredient.quantity.value), unitSymbol: ingredient.quantity.unit.symbol,
                basisSymbol: ingredient.basisUnit?.symbol,
                densityText: ingredient.density.map { DecimalText.encode($0) },
                sourceNote: ingredient.sourceNote, nutrients: nutrients)
        }
        let yieldDTO: YieldDTO
        switch version.yield {
        case .servings(let count):
            yieldDTO = YieldDTO(kind: "servings", amountText: DecimalText.encode(count), unitSymbol: nil)
        case .total(let quantity):
            yieldDTO = YieldDTO(kind: "total", amountText: DecimalText.encode(quantity.value), unitSymbol: quantity.unit.symbol)
        }
        let data = try JSONEncoder().encode(PayloadDTO(ingredients: ingredients, yield: yieldDTO))
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ row: RecipeVersionRecord) throws -> RecipeVersion {
        let corrupt = RecipeStoreError.corruptRecord("\(row.recipeID):\(row.number)")
        guard let payload = try? JSONDecoder().decode(PayloadDTO.self, from: Data(row.payloadJSON.utf8)) else {
            throw corrupt
        }
        var ingredients: [RecipeIngredient] = []
        for item in payload.ingredients {
            guard let amount = DecimalText.decode(item.amountText),
                let unit = try? UnitRegistry.unit(for: item.unitSymbol)
            else { throw corrupt }
            var basis: MeasureUnit?
            if let symbol = item.basisSymbol {
                guard let found = try? UnitRegistry.unit(for: symbol) else { throw corrupt }
                basis = found
            }
            var density: Decimal?
            if let text = item.densityText {
                guard let parsed = DecimalText.decode(text) else { throw corrupt }
                density = parsed
            }
            var perUnit: [String: NutrientValue] = [:]
            for nutrient in item.nutrients {
                switch nutrient.state {
                case "known":
                    guard let text = nutrient.valueText, let value = DecimalText.decode(text),
                        let symbol = nutrient.unitSymbol, let nutrientUnit = try? UnitRegistry.unit(for: symbol)
                    else { throw corrupt }
                    perUnit[nutrient.id] = .known(value, nutrientUnit)
                case "unknown":
                    perUnit[nutrient.id] = .unknown
                case "notApplicable":
                    perUnit[nutrient.id] = .notApplicable
                case "belowThreshold":
                    if let symbol = nutrient.unitSymbol {
                        guard let nutrientUnit = try? UnitRegistry.unit(for: symbol) else { throw corrupt }
                        perUnit[nutrient.id] = .belowReportingThreshold(nutrientUnit)
                    } else {
                        perUnit[nutrient.id] = .belowReportingThreshold(nil)
                    }
                default:
                    throw corrupt
                }
            }
            ingredients.append(RecipeIngredient(
                id: item.id, name: item.name, quantity: Quantity(value: amount, unit: unit), perUnit: perUnit,
                density: density, sourceNote: item.sourceNote, basisUnit: basis))
        }
        guard let yieldAmount = DecimalText.decode(payload.yield.amountText) else { throw corrupt }
        let yieldValue: RecipeYield
        switch payload.yield.kind {
        case "servings":
            yieldValue = .servings(yieldAmount)
        case "total":
            guard let symbol = payload.yield.unitSymbol, let unit = try? UnitRegistry.unit(for: symbol) else { throw corrupt }
            yieldValue = .total(Quantity(value: yieldAmount, unit: unit))
        default:
            throw corrupt
        }
        let version = RecipeVersion(
            recipeID: row.recipeID, number: row.number, title: row.title, ingredients: ingredients,
            yield: yieldValue, notes: row.notes, createdAt: row.createdAt)
        do {
            try version.validate()
        } catch {
            throw corrupt
        }
        return version
    }
}
