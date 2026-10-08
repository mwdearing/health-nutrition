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
            let key = Self.key(category: intake.category, revision: current, meal: intake.meal)
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

    /// **The meal is part of the identity.** A recent item is a template to add again, and "again" means
    /// the same thing a person last ate: the same oats at breakfast and the same oats at dinner are two
    /// different entries they would add again separately, and a favorite is a copy of one of them.
    ///
    /// It was left out, and that made one entry stand in for the other in three places at once: a Dinner
    /// entry whose Breakfast twin was favorited read as already favorited, `addFavorite` refused to save it
    /// as a second favorite, and removing the Breakfast one removed the Dinner row too — through a key that
    /// named only the product. Every part of the identity is spelled out, meal included, so the three agree
    /// on which entry they are talking about.
    static func key(category: String, revision: IntakeRevision, meal: String?) -> String {
        identityKey(
            category: category, snapshotID: revision.productSnapshotID,
            names: revision.components.map { $0.name }, meal: meal)
    }

    /// Injective key: lengths prefix every text part, so no join character can collide.
    ///
    /// The meal is written as its own counted part, and a nil meal as a counted empty one, so an entry that
    /// states no meal can never collide with one that states an empty string. A snapshot id still short
    /// circuits: a snapshot names one product, but the meal is what the person is repeating, so it is kept.
    static func identityKey(category: String, snapshotID: String?, names: [String], meal: String?) -> String {
        let mealPart = Self.mealIdentityPart(meal)
        if let snapshotID { return "product:\(snapshotID.count):\(snapshotID)|\(mealPart)" }
        let parts = names.map { $0.lowercased() }.sorted().map { "\($0.count):\($0)" }.joined()
        return "category:\(category.count):\(category)|components:\(names.count)|\(parts)|\(mealPart)"
    }

    /// The counted meal part of a key, with the stored value normalised first.
    ///
    /// The value is free text in the export, so it reaches the store spelled however a person or another
    /// tool wrote it: `"Breakfast "` and `"breakfast"` are one meal, and keying them verbatim gave one
    /// favorite two identities — the second one added as if the first were not there, and a recent reading
    /// as un-favorited while a favorite stood in for it. Normalising through `MealLabel.identityKeyPart` is
    /// the same rule `MealLabel.displayName(for:)` shows a meal by, so what a screen calls one meal is one
    /// entry in the Library.
    ///
    /// A value that states no meal still keys as a counted empty part rather than as nothing, so an entry
    /// stating none can never collide with one stating an empty string.
    static func mealIdentityPart(_ meal: String?) -> String {
        let normalized = MealLabel.identityKeyPart(for: meal)
        return "meal:\(normalized?.count ?? 0):\(normalized ?? "")"
    }
}

public struct LibraryItem: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let isFavorite: Bool
    public let template: RepeatTemplate
    /// What kind of product the item is, read from the snapshot it repeats. A template with no snapshot
    /// states no product at all and is the food it was recorded as; only a supplement is marked.
    public let kind: ProductKind

    public var accessibilityLabel: String {
        let label = "Add \(title), \(detail)"
        return kind == .supplement ? label + ", " + kind.displayName : label
    }

    public func accessibilityLabel(forPick: Bool) -> String {
        guard forPick else { return accessibilityLabel }
        let label = "\(title), opens details"
        return kind == .supplement ? label + ", " + kind.displayName : label
    }

    public init(
        id: String, title: String, detail: String, isFavorite: Bool, template: RepeatTemplate,
        kind: ProductKind = .food
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isFavorite = isFavorite
        self.template = template
        self.kind = kind
    }
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

    /// The amounts, then the meal when the template states one: two rows that differ only by meal
    /// (a Breakfast and a Dinner of the same food) have to be told apart on the row itself.
    static func detail(_ template: RepeatTemplate) -> String {
        let amounts = AmountText.summary(template.components)
        guard let meal = MealLabel.displayName(for: template.meal) else { return amounts }
        return "\(amounts) · \(meal)"
    }

    public func load() {
        do {
            let stored = try favorites.list()
            let favoriteKeys = Set(stored.map(Self.key(of:)))
            let recents = try RecentItemsProvider(store: store).recents()
            let favoriteTemplates: [RepeatTemplate] = stored.map { favorite in
                // A malformed favorite shows as unknown and cannot be repeated.
                RepeatTemplate(favorite: favorite) ?? RepeatTemplate(
                    displayName: favorite.displayName, category: favorite.category, meal: favorite.meal, components: [],
                    productSnapshotID: favorite.productSnapshotID)
            }
            // What each product the screen names is, read once per snapshot rather than once per row: a
            // favorite and a recent can repeat the same product, and each read is a store query. A
            // template with no snapshot states no product at all and is the food it was recorded as.
            let snapshotIDs = Set(
                (favoriteTemplates + recents.map(\.template)).compactMap(\.productSnapshotID))
            var kinds: [String: ProductKind] = [:]
            for snapshotID in snapshotIDs {
                kinds[snapshotID] = (try? store.product(snapshotID: snapshotID))?.kind ?? .food
            }
            func kind(of template: RepeatTemplate) -> ProductKind {
                guard let snapshotID = template.productSnapshotID else { return .food }
                return kinds[snapshotID] ?? .food
            }
            let favoriteItems = stored.enumerated().map { index, favorite -> LibraryItem in
                let template = favoriteTemplates[index]
                return LibraryItem(
                    id: "favorite:\(favorite.id)", title: favorite.displayName,
                    detail: Self.detail(template), isFavorite: true, template: template,
                    kind: kind(of: template))
            }
            let recentItems = recents.map { recent -> LibraryItem in
                LibraryItem(
                    id: "recent:\(recent.id)", title: recent.template.displayName,
                    detail: Self.detail(recent.template),
                    isFavorite: favoriteKeys.contains(recent.id), template: recent.template,
                    kind: kind(of: recent.template))
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
            category: favorite.category, snapshotID: favorite.productSnapshotID,
            names: favorite.components.map { $0.name }, meal: favorite.meal)
    }

    private static func key(of template: RepeatTemplate) -> String {
        RecentItemsProvider.identityKey(
            category: template.category, snapshotID: template.productSnapshotID,
            names: template.components.map { $0.name }, meal: template.meal)
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
