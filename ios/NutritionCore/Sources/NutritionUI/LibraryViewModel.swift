import Foundation
import NutritionDomain
import NutritionJournal

/// A recent item, derived from the journal and not stored.
public struct RecentItem: Equatable, Identifiable {
    /// Product snapshot id, else category plus component names.
    public let id: String
    public let template: RepeatTemplate
    public let lastUsedAt: Date
}

/// Distinct recent items, newest first.
public struct RecentItemsProvider {
    public static let defaultLimit = 20
    private let store: JournalStore

    public init(store: JournalStore) {
        self.store = store
    }

    public func recents(limit: Int = RecentItemsProvider.defaultLimit) throws -> [RecentItem] {
        var seen = Set<String>()
        var result: [RecentItem] = []
        let intakes = try store.activeIntakes().filter { $0.lifecycle == .active }.sorted { $0.occurredAt > $1.occurredAt }
        for intake in intakes {
            guard result.count < limit else { break }
            guard let revisions = try? store.revisions(of: intake.id),
                let current = revisions.first(where: { $0.number == intake.currentRevision })
            else { continue }
            let key = Self.key(category: intake.category, revision: current)
            guard seen.insert(key).inserted else { continue }
            result.append(RecentItem(
                id: key,
                template: RepeatTemplate(
                    displayName: AmountText.title(current.components), category: intake.category, meal: intake.meal,
                    components: current.components, productSnapshotID: current.productSnapshotID),
                lastUsedAt: intake.occurredAt))
        }
        return result
    }

    static func key(category: String, revision: IntakeRevision) -> String {
        identityKey(category: category, snapshotID: revision.productSnapshotID, names: revision.components.map { $0.name })
    }

    /// Injective key: lengths prefix every text part, so no join character can collide.
    static func identityKey(category: String, snapshotID: String?, names: [String]) -> String {
        if let snapshotID { return "product:\(snapshotID.count):\(snapshotID)" }
        let parts = names.map { $0.lowercased() }.sorted().map { "\($0.count):\($0)" }.joined()
        return "category:\(category.count):\(category)|components:\(names.count)|\(parts)"
    }
}

public struct LibraryItem: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let isFavorite: Bool
    public let template: RepeatTemplate
}

public struct LibrarySection: Equatable, Identifiable {
    public var id: String { title }
    public let title: String
    public let items: [LibraryItem]
}

@MainActor
public final class LibraryViewModel: ObservableObject {
    /// Favorites first, then Recents.
    @Published public private(set) var sections: [LibrarySection] = []
    @Published public private(set) var errorMessage: String?

    private let store: JournalStore
    private let favorites: FavoritesStore
    private let repeater: IntakeRepeater

    public init(
        store: JournalStore,
        favorites: FavoritesStore,
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.favorites = favorites
        self.repeater = IntakeRepeater(
            store: store, timeZoneProvider: IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider),
            makeID: makeID)
    }

    public func load() {
        do {
            let stored = try favorites.list()
            let favoriteKeys = Set(stored.map(Self.key(of:)))
            let favoriteItems = stored.map { favorite -> LibraryItem in
                // A malformed favorite shows as unknown and cannot be repeated.
                let template = RepeatTemplate(favorite: favorite) ?? RepeatTemplate(
                    displayName: favorite.displayName, category: favorite.category, meal: favorite.meal, components: [],
                    productSnapshotID: favorite.productSnapshotID)
                return LibraryItem(
                    id: "favorite:\(favorite.id)", title: favorite.displayName,
                    detail: AmountText.summary(template.components), isFavorite: true, template: template)
            }
            let recentItems = try RecentItemsProvider(store: store).recents().map { recent in
                LibraryItem(
                    id: "recent:\(recent.id)", title: recent.template.displayName,
                    detail: AmountText.summary(recent.template.components),
                    isFavorite: favoriteKeys.contains(recent.id), template: recent.template)
            }
            sections = [
                LibrarySection(title: "Favorites", items: favoriteItems),
                LibrarySection(title: "Recents", items: recentItems),
            ]
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the library."
        }
    }

    /// Repeats the item as a new intake: one `create`.
    @discardableResult
    public func select(_ item: LibraryItem, now: Date) -> String? {
        guard !item.template.components.isEmpty else {
            errorMessage = "This item has no amounts to repeat."
            return nil
        }
        do {
            let id = try repeater.create(from: item.template, now: now)
            errorMessage = nil
            return id
        } catch IntakeRepeatError.productUnavailable {
            errorMessage = IntakeRepeatError.productUnavailableMessage
            return nil
        } catch {
            errorMessage = "Could not add the item."
            return nil
        }
    }

    private static func key(of favorite: FavoriteTemplate) -> String {
        RecentItemsProvider.identityKey(
            category: favorite.category, snapshotID: favorite.productSnapshotID, names: favorite.components.map { $0.name })
    }

    private static func key(of template: RepeatTemplate) -> String {
        RecentItemsProvider.identityKey(
            category: template.category, snapshotID: template.productSnapshotID, names: template.components.map { $0.name })
    }

    /// Saves the item as a favorite template (a copy, not a link to the intake). Already favorited is a no-op.
    public func addFavorite(_ item: LibraryItem) {
        guard !item.template.components.contains(where: { $0.amount.isNaN }) else {
            errorMessage = "This item has an unknown amount and cannot be saved as a favorite."
            return
        }
        guard item.template.components.allSatisfy({ AmountParser.parse(DecimalFormatting.text($0.amount)) != nil }) else {
            errorMessage = "This item has an amount that cannot be saved as a favorite."
            return
        }
        let components = item.template.components.map {
            FavoriteComponent(
                componentID: $0.componentID, name: $0.name, amountText: DecimalFormatting.text($0.amount),
                unitSymbol: $0.unit.symbol)
        }
        let favorite = FavoriteTemplate(
            id: UUID().uuidString.lowercased(), displayName: item.title, category: item.template.category,
            components: components, productSnapshotID: item.template.productSnapshotID, meal: item.template.meal)
        do {
            let key = Self.key(of: favorite)
            if try favorites.list().contains(where: { Self.key(of: $0) == key }) {
                load()
                return
            }
            try favorites.add(favorite)
            load()
        } catch {
            errorMessage = "Could not save the favorite."
        }
    }

    /// Removes the favorite: by id for a favorite row, by identity for a recent that is favorited.
    public func removeFavorite(_ item: LibraryItem) {
        guard item.isFavorite else { return }
        do {
            if item.id.hasPrefix("favorite:") {
                try favorites.remove(id: String(item.id.dropFirst("favorite:".count)))
            } else {
                let key = Self.key(of: item.template)
                for favorite in try favorites.list() where Self.key(of: favorite) == key {
                    try favorites.remove(id: favorite.id)
                }
            }
            load()
        } catch {
            errorMessage = "Could not remove the favorite."
        }
    }
}
