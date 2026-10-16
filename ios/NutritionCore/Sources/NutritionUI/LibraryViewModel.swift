import Foundation
import NutritionDomain
import NutritionProviders
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
    /// The units entries were logged in, read once per provider, so a template carries the unit its entry used.
    private let loggedUnits: [String: [String: MeasureUnit]]

    public init(store: JournalStore) {
        self.store = store
        self.loggedUnits = LoggedUnitIndex.load(from: store)
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
            result.append(RecentItem(id: key, template: template(intake: intake, revision: current), lastUsedAt: intake.occurredAt))
        }
        return result
    }

    /// The template that repeats one entry's current revision, titled as its Recents row is. Often logged
    /// items are built here too, so a Recent row and an Often logged row of one item never read apart.
    func template(intake: Intake, revision: IntakeRevision) -> RepeatTemplate {
        RepeatTemplate(
            displayName: displayName(of: revision), category: intake.category, meal: intake.meal,
            components: revision.components, productSnapshotID: revision.productSnapshotID,
            loggedUnits: loggedUnits[intake.id] ?? [:])
    }

    /// The row title for one revision. A quick add is always one serving of the same name, so its typed
    /// amounts are added to the title; without them two quick adds would read alike and a tap could repeat
    /// amounts the row does not show.
    private func displayName(of revision: IntakeRevision) -> String {
        let product = revision.productSnapshotID.flatMap { try? store.product(snapshotID: $0) }
        return QuickAddViewModel.rowTitle(components: revision.components, product: product)
    }

    /// Distinct products the person has logged from a lookup, a label scan or another source that stored a
    /// product snapshot. Typed-in entries (origin `manual`), quick adds (`quick_add`, amounts with no product
    /// behind them), recipes and water are left out.
    ///
    /// Read from every active entry rather than from `recents(limit:)`, so the Products segment is not capped at
    /// the Recents rows. One row per product (its lineage `productID`), built from the newest entry of that
    /// product, so the row repeats the snapshot that entry used. Sorted by the name the row shows, ignoring case.
    public func foods() throws -> [RecentItem] {
        var seenProducts = Set<String>()
        var result: [RecentItem] = []
        let intakes = try store.activeIntakes()
            .filter { $0.lifecycle == .active && $0.category != DailyTotalsBuilder.waterCategory }
            .sorted { $0.occurredAt > $1.occurredAt }
        // Entries logged with "Save to Library" off stay out of Products; they still appear in Recents.
        let keptOutOfLibrary = try (store as? JournalLibraryExclusions)?.intakeIDsNotSavedToLibrary() ?? []
        // Each snapshot is read once, however many entries used it: a product logged hundreds of times is one query.
        var productsBySnapshot: [String: ProductDefinition?] = [:]
        for intake in intakes where !keptOutOfLibrary.contains(intake.id) {
            guard let revisions = try? store.revisions(of: intake.id),
                let current = revisions.first(where: { $0.number == intake.currentRevision }),
                let snapshotID = current.productSnapshotID
            else { continue }
            let loaded: ProductDefinition?
            if let cached = productsBySnapshot[snapshotID] {
                loaded = cached
            } else {
                loaded = try? store.product(snapshotID: snapshotID)
                productsBySnapshot[snapshotID] = loaded
            }
            guard let product = loaded,
                product.catalogOrigin != Self.manualOrigin,
                product.catalogOrigin != IntakeContextFactCatalog.quickAddOrigin,
                product.catalogOrigin != RecipeLogger.catalogOrigin
            else { continue }
            // Catalog products share a lineage id across versions. A label capture's lineage id is the same
            // for every capture, so its content-derived snapshot id is what tells two labels apart.
            let identity = product.catalogOrigin == ProductOrigin.label_capture ? snapshotID : product.productID
            guard seenProducts.insert(identity).inserted else { continue }
            let key = Self.key(category: intake.category, revision: current, meal: intake.meal)
            result.append(RecentItem(
                id: key,
                template: RepeatTemplate(
                    displayName: AmountText.title(current.components), category: intake.category, meal: intake.meal,
                    components: current.components, productSnapshotID: snapshotID,
                    loggedUnits: loggedUnits[intake.id] ?? [:]),
                lastUsedAt: intake.occurredAt))
        }
        return result.sorted {
            let left = $0.template.displayName.lowercased()
            let right = $1.template.displayName.lowercased()
            return left == right ? $0.id < $1.id : left < right
        }
    }

    /// The origin a typed-in entry's product carries.
    static let manualOrigin = "manual"

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

    /// The counted meal part of a key, with the stored value normalized first.
    ///
    /// The value is free text in the export, so it reaches the store spelled however a person or another
    /// tool wrote it: `"Breakfast "` and `"breakfast"` are one meal, and keying them verbatim gave one
    /// favorite two identities — the second one added as if the first were not there, and a recent reading
    /// as un-favorited while a favorite stood in for it. Normalizing through `MealLabel.identityKeyPart` is
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

/// The segments of the Library screen. Recipes is a placeholder for now.
public enum LibrarySegment: String, CaseIterable, Identifiable {
    case favorites, recent, products, recipes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .products: return "Products"
        case .recipes: return "Recipes"
        }
    }
}

/// The words and symbol shown when a segment has nothing to list.
public struct LibraryEmptyText: Equatable {
    public let title: String
    public let message: String
    public let systemImage: String
}

/// What the Undo toast needs: the entry the quick add wrote, and the words it shows.
public struct LibraryUndoToken: Equatable {
    public let intakeID: String
    public let message: String
}

@MainActor
public final class LibraryViewModel: ObservableObject {
    /// Favorites first, then Products, then Recents.
    @Published public private(set) var sections: [LibrarySection] = []
    /// Every logged product, including those the Products segment lists as a standalone product row
    /// instead. Find products searches these, so a typed name still finds the logged amount and meal.
    @Published public private(set) var loggedProducts: [LibraryItem] = []
    /// Everything the person logs often, most often first (see `FrequentItemsProvider`), uncapped so a
    /// typed name finds any of them. Find products lists the first few as "Often logged"; the Library
    /// screen itself does not show them.
    @Published public private(set) var frequentItems: [LibraryItem] = []
    /// The saved meals Find products offers to log. Set once by the app; nil leaves them out.
    public var savedMeals: SavedMealsModel?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var standaloneProducts: [CustomProductRevision] = []
    @Published public var searchText = ""
    @Published public private(set) var deliveryRefresh = UUID()
    public let productSharing: CustomProductSharingModel?
    private let productStore: (any CustomProductStore)?
    @Published public var segment: LibrarySegment = .favorites
    @Published public private(set) var undoToken: LibraryUndoToken?
    /// The supplement list the Library links to. Set once by the app; nil leaves the link out.
    public var supplementStack: SupplementStackViewModel?

    private let store: JournalStore
    private let favorites: FavoritesStore
    private let repeater: IntakeRepeater
    private let preferences: DisplayPreferences

    public init(
        store: JournalStore,
        favorites: FavoritesStore,
        productStore: (any CustomProductStore)? = nil,
        productSharing: CustomProductSharingModel? = nil,
        preferences: DisplayPreferences = InMemoryDisplayPreferences(),
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.favorites = favorites
        self.productStore = productStore
        self.productSharing = productSharing
        self.preferences = preferences
        self.repeater = IntakeRepeater(
            store: store, timeZoneProvider: IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider),
            makeID: makeID)
    }

    /// The amounts, then the meal when the template states one: two rows that differ only by meal
    /// (a Breakfast and a Dinner of the same food) have to be told apart on the row itself.
    static func detail(
        _ template: RepeatTemplate, unitSystem: UnitSystem = .metric, isSupplement: Bool = false
    ) -> String {
        // Only a supplement reads back in the unit it was logged in; a drink keeps the unit system's.
        let amounts = AmountText.summary(
            template.components, unitSystem: unitSystem, loggedUnits: isSupplement ? template.loggedUnits : [:])
        guard let meal = MealLabel.displayName(for: template.meal) else { return amounts }
        return "\(amounts) · \(meal)"
    }

    public func load() {
        do {
            standaloneProducts = try productStore?.customProducts() ?? []
            let stored = try favorites.list()
            let favoriteKeys = Set(stored.map(Self.key(of:)))
            let recents = try RecentItemsProvider(store: store).recents()
            let foods = try RecentItemsProvider(store: store).foods()
            let frequents = try FrequentItemsProvider(store: store).frequents(limit: .max)
            let loggedUnitIndex = LoggedUnitIndex.load(from: store)
            let favoriteTemplates: [RepeatTemplate] = stored.map { favorite in
                // A malformed favorite shows as unknown and cannot be repeated.
                RepeatTemplate(favorite: favorite, loggedUnitIndex: loggedUnitIndex) ?? RepeatTemplate(
                    displayName: favorite.displayName, category: favorite.category, meal: favorite.meal, components: [],
                    productSnapshotID: favorite.productSnapshotID)
            }
            // What each product the screen names is, read once per snapshot rather than once per row: a
            // favorite and a recent can repeat the same product, and each read is a store query. A
            // template with no snapshot states no product at all and is the food it was recorded as.
            let snapshotIDs = Set(
                (favoriteTemplates + recents.map(\.template) + foods.map(\.template) + frequents.map(\.template))
                    .compactMap(\.productSnapshotID))
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
                    detail: Self.detail(template, unitSystem: preferences.unitSystem, isSupplement: kind(of: template) == .supplement), isFavorite: true, template: template,
                    kind: kind(of: template))
            }
            let recentItems = recents.map { recent -> LibraryItem in
                LibraryItem(
                    id: "recent:\(recent.id)", title: recent.template.displayName,
                    detail: Self.detail(recent.template, unitSystem: preferences.unitSystem, isSupplement: kind(of: recent.template) == .supplement),
                    isFavorite: favoriteKeys.contains(recent.id), template: recent.template,
                    kind: kind(of: recent.template))
            }
            let standaloneIDs = Set(standaloneProducts.map(\.localProductID))
            let legacyFoods = foods.filter { food in
                guard let snapshotID = food.template.productSnapshotID,
                      let product = try? store.product(snapshotID: snapshotID),
                      let id = UUID(uuidString: product.productID) else { return true }
                return !standaloneIDs.contains(id)
            }
            func foodItem(_ food: RecentItem) -> LibraryItem {
                LibraryItem(
                    id: "food:\(food.id)", title: food.template.displayName,
                    detail: Self.detail(food.template, unitSystem: preferences.unitSystem, isSupplement: kind(of: food.template) == .supplement),
                    isFavorite: favoriteKeys.contains(food.id), template: food.template,
                    kind: kind(of: food.template))
            }
            let foodItems = legacyFoods.map(foodItem)
            loggedProducts = foods.map(foodItem)
            frequentItems = frequents.map { frequent -> LibraryItem in
                LibraryItem(
                    id: "frequent:\(frequent.id)", title: frequent.template.displayName,
                    detail: Self.detail(frequent.template, unitSystem: preferences.unitSystem, isSupplement: kind(of: frequent.template) == .supplement),
                    isFavorite: favoriteKeys.contains(frequent.id), template: frequent.template,
                    kind: kind(of: frequent.template))
            }
            sections = [
                LibrarySection(title: "Favorites", items: favoriteItems),
                LibrarySection(title: "Products", items: foodItems),
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

    /// The items the current segment lists. Recipes lists nothing yet.
    public var filteredProducts: [CustomProductRevision] {
        standaloneProducts.filter { searchText.isEmpty || $0.content.name.localizedCaseInsensitiveContains(searchText) }
    }
    public func observeProductStatus() async {
        while !Task.isCancelled {
            if productSharing?.refreshFromStore() == true { deliveryRefresh = UUID() }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    public func standaloneProduct(for item: LibraryItem) throws -> CustomProductRevision? {
        guard let snapshotID = item.template.productSnapshotID,
              let snapshot = try store.product(snapshotID: snapshotID),
              let localID = UUID(uuidString: snapshot.productID) else { return nil }
        return try productStore?.customProducts().first { $0.localProductID == localID }
    }
    public func canCompleteProduct(_ item: LibraryItem) -> Bool {
        // A quick add is amounts with no product behind them, so there is no product to edit.
        if let id = item.template.productSnapshotID,
           (try? store.product(snapshotID: id))?.catalogOrigin == IntakeContextFactCatalog.quickAddOrigin {
            return false
        }
        return item.template.productSnapshotID != nil || ["food", "supplement"].contains(item.template.category)
    }
    public func legacyDraft(_ item: LibraryItem) throws -> LegacyCustomProductDraft {
        if item.template.productSnapshotID == nil { return try CustomProductMapping.legacyDraft(from: item.template) }
        guard let id = item.template.productSnapshotID, let product = try store.product(snapshotID: id) else { throw IntakeRepeatError.productUnavailable }
        return try CustomProductMapping.legacyDraft(from: product)
    }
    public var visibleItems: [LibraryItem] {
        segmentItems.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
    }
    private var segmentItems: [LibraryItem] {
        switch segment {
        case .favorites: return sections.first { $0.title == "Favorites" }?.items ?? []
        case .recent: return sections.first { $0.title == "Recents" }?.items ?? []
        case .products: return sections.first { $0.title == "Products" }?.items ?? []
        case .recipes: return []
        }
    }

    public func emptyText(for segment: LibrarySegment) -> LibraryEmptyText {
        switch segment {
        case .favorites:
            return LibraryEmptyText(
                title: "No favorites yet", message: "Star anything you log often.", systemImage: "star")
        case .recent:
            return LibraryEmptyText(
                title: "Nothing logged yet", message: "Things you log will show up here.", systemImage: "clock")
        case .products:
            return LibraryEmptyText(
                title: "No products yet", message: "Foods, drinks and supplements you save, scan or look up appear here.",
                systemImage: "barcode.viewfinder")
        case .recipes:
            return LibraryEmptyText(
                title: "No recipes yet", message: "Recipes you write are kept here.", systemImage: "book")
        }
    }

    /// Repeats the item as a new entry at once and offers Undo. False, with no token, when nothing was added.
    @discardableResult
    public func quickAdd(_ item: LibraryItem, now: Date) -> Bool {
        // An earlier offer is dropped first: if this add fails, its Undo must not stay on screen.
        undoToken = nil
        guard let id = select(item, now: now) else { return false }
        undoToken = LibraryUndoToken(intakeID: id, message: "Added \(item.title)")
        load()
        return true
    }

    /// Deletes the entry the last quick add wrote. False when there is nothing to undo.
    /// An entry that is already gone clears the offer without an error, since there is nothing left to undo.
    /// Any other failure keeps the offer, so the person can try again.
    @discardableResult
    public func undo(now: Date) -> Bool {
        guard let token = undoToken else { return false }
        do {
            try store.delete(intakeID: token.intakeID, now: now)
            undoToken = nil
            load()
            return true
        } catch JournalError.intakeDeleted(_) {
            // The entry is already gone: there is nothing left to undo.
            undoToken = nil
            load()
            return false
        } catch {
            errorMessage = "Could not undo. Try again."
            return false
        }
    }

    /// Clears the token when the Undo window ends, but only if it is still the current one.
    public func expireUndo(_ token: LibraryUndoToken) {
        if undoToken == token { undoToken = nil }
    }

    /// Reports that an item cannot be opened as details, because its saved product is gone.
    public func reportOpenFailure() {
        errorMessage = "This item can't be opened. Its saved product is no longer available."
    }

    /// The meal an item was recorded under, when it names one of the meals the app offers.
    public static func mealLabel(for template: RepeatTemplate) -> MealLabel? {
        MealLabel.identityKeyPart(for: template.meal).flatMap { MealLabel(rawValue: $0) }
    }

    /// Drops any pending Undo offer, for when the Library screen goes away.
    public func clearUndo() {
        undoToken = nil
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
            // The units the entry was logged in follow it into the favorite, keyed by the favorite's own id.
            if let units = store as? JournalLoggedUnits {
                for component in item.template.components where component.unit == .mL {
                    guard let loggedUnit = item.template.loggedUnits[component.componentID] else { continue }
                    try units.recordLoggedUnit(JournalLoggedUnit(
                        intakeID: favorite.id, componentID: component.componentID, unit: loggedUnit))
                }
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

/// Verification and completeness are independent of this account's delivery status.
public struct LibraryProductPresentation {
    public let verificationText: String
    public let missingFacts: Bool
    public init(_ product: CustomProductRevision) {
        missingFacts = !product.content.facts.map(ProductFactInput.init).contains(where: \.hasReportedValue)
        if let evidence = product.importVerification, evidence.content == product.content, evidence.source == product.source {
            verificationText = evidence.ownerReviewed ? "Verified by owner review at import" : "Not verified at import"
        } else {
            verificationText = "Verification not checked"
        }
    }
}
