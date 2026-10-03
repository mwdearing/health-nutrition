import Foundation
import SwiftData

/// One component of a favorite: exact decimal text and a unit symbol, never a binary float.
public struct FavoriteComponent: Sendable, Hashable, Codable {
    public var componentID: String
    public var name: String
    /// Exact decimal text in the POSIX format, for example "250" or "0.5".
    public var amountText: String
    public var unitSymbol: String

    public init(componentID: String, name: String, amountText: String, unitSymbol: String) {
        self.componentID = componentID
        self.name = name
        self.amountText = amountText
        self.unitSymbol = unitSymbol
    }
}

/// A favorite is a template: it copies what was eaten, and is not a link to a live intake.
public struct FavoriteTemplate: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var category: String
    public var components: [FavoriteComponent]
    public var productSnapshotID: String?
    public var meal: String?

    public init(
        id: String, displayName: String, category: String, components: [FavoriteComponent],
        productSnapshotID: String? = nil, meal: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.components = components
        self.productSnapshotID = productSnapshotID
        self.meal = meal
    }
}

public protocol FavoritesStore: AnyObject, Sendable {
    /// Adds the favorite, or replaces the one with the same id.
    func add(_ favorite: FavoriteTemplate) throws
    func remove(id: String) throws
    /// Newest first.
    func list() throws -> [FavoriteTemplate]
    func contains(id: String) throws -> Bool
    func close()
}

public enum FavoritesError: Error, Sendable, Equatable {
    case closed
    case corruptRecord(String)
}

@Model
final class FavoriteRecord {
    var favoriteID: String
    var displayName: String
    var category: String
    /// JSON array of `FavoriteComponent`.
    var componentsJSON: String
    var productSnapshotID: String?
    var addedAt: Date
    var meal: String?

    init(
        favoriteID: String, displayName: String, category: String, componentsJSON: String,
        productSnapshotID: String?, addedAt: Date, meal: String? = nil
    ) {
        self.favoriteID = favoriteID
        self.displayName = displayName
        self.category = category
        self.componentsJSON = componentsJSON
        self.productSnapshotID = productSnapshotID
        self.addedAt = addedAt
        self.meal = meal
    }
}

/// Favorites in their own store file, next to the journal file; the URL is injected.
public final class SwiftDataFavoritesStore: FavoritesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var container: ModelContainer?

    public init(url: URL) throws {
        let configuration = ModelConfiguration(schema: Schema([FavoriteRecord.self]), url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: FavoriteRecord.self, configurations: configuration)
    }

    public func close() {
        lock.withLock { container = nil }
    }

    private func openContainer() throws -> ModelContainer {
        try lock.withLock {
            guard let container else { throw FavoritesError.closed }
            return container
        }
    }

    public func add(_ favorite: FavoriteTemplate) throws {
        let context = ModelContext(try openContainer())
        let id = favorite.id
        let existing = try context.fetch(FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate<FavoriteRecord> { $0.favoriteID == id }))
        for row in existing { context.delete(row) }
        let data = try JSONEncoder().encode(favorite.components)
        context.insert(FavoriteRecord(
            favoriteID: favorite.id, displayName: favorite.displayName, category: favorite.category,
            componentsJSON: String(decoding: data, as: UTF8.self),
            productSnapshotID: favorite.productSnapshotID, addedAt: Date(), meal: favorite.meal))
        try context.save()
    }

    public func remove(id: String) throws {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate<FavoriteRecord> { $0.favoriteID == id }))
        for row in rows { context.delete(row) }
        try context.save()
    }

    public func list() throws -> [FavoriteTemplate] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<FavoriteRecord>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
        return try rows.map { row in
            guard let components = try? JSONDecoder().decode([FavoriteComponent].self, from: Data(row.componentsJSON.utf8)) else {
                throw FavoritesError.corruptRecord(row.favoriteID)
            }
            return FavoriteTemplate(
                id: row.favoriteID, displayName: row.displayName, category: row.category,
                components: components, productSnapshotID: row.productSnapshotID, meal: row.meal)
        }
    }

    public func contains(id: String) throws -> Bool {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate<FavoriteRecord> { $0.favoriteID == id }))
        return !rows.isEmpty
    }
}
