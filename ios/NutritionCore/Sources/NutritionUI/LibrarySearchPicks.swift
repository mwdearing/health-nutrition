import Foundation
import NutritionDomain

/// One group of the person's own items on the Find products screen.
public struct LibrarySearchGroup: Equatable, Identifiable {
    public var id: String { title }
    public let title: String
    public let items: [LibraryItem]
}

extension LibraryViewModel {
    /// How many rows each group shows before anything is typed.
    public static let searchPicksLimit = 5
    /// How many matching rows the screen lists while the person types.
    public static let searchMatchesLimit = 8

    /// The person's own favorites, recents and logged products (`loggedProducts`, every product logged,
    /// standalone ones included) for the Find products screen, built from
    /// what `load()` last read. It reads no store and sends nothing anywhere, so it can run on every
    /// keystroke. It never sets `searchText` or `segment`: this model is shared with the Library screen,
    /// and a filter set here would stay applied there.
    ///
    /// With no query: "Recent", the newest recents, then "Favorites" not already listed, each capped at
    /// `searchPicksLimit`; a group with nothing in it is left out. With a query: one "Your foods" group of
    /// the distinct items whose title contains it, ignoring case, with titles that start with it first,
    /// capped at `searchMatchesLimit`. That group is returned even when nothing matches, so the screen can
    /// say so, but only when the person has something in the Library at all.
    ///
    /// One item shows once: two rows are the same item when they share the Library's identity key
    /// (category, snapshot, component names and meal). Favorites are taken before recents and products.
    /// An item with no amounts, such as a malformed favorite, is left out, since it cannot be opened.
    ///
    /// A `kind` keeps only items of that kind, as the screen's Kind control does for products: an item
    /// with a product snapshot is the kind its snapshot states (the kind its row marks), and one without
    /// is the kind its category names. Water names no kind, so it shows only under all kinds.
    public func searchGroups(matching query: String, kind: ProductKind? = nil) -> [LibrarySearchGroup] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let favorites = items(inSection: "Favorites")
        let recents = items(inSection: "Recents")
        // Not the Products section: it leaves out a logged product it lists as a standalone row instead.
        let products = loggedProducts
        var seen = Set<String>()
        func take(_ items: [LibraryItem], limit: Int, where matches: (LibraryItem) -> Bool) -> [LibraryItem] {
            var picked: [LibraryItem] = []
            for item in items {
                guard picked.count < limit else { break }
                // An item with no amounts cannot open the details form, so it is not offered here.
                guard !item.template.components.isEmpty, kind == nil || Self.kind(of: item) == kind, matches(item),
                      seen.insert(Self.searchIdentity(of: item)).inserted else { continue }
                picked.append(item)
            }
            return picked
        }
        guard !text.isEmpty else {
            let recent = take(recents, limit: Self.searchPicksLimit) { _ in true }
            let favorite = take(favorites, limit: Self.searchPicksLimit) { _ in true }
            return [
                LibrarySearchGroup(title: "Recent", items: recent),
                LibrarySearchGroup(title: "Favorites", items: favorite),
            ].filter { !$0.items.isEmpty }
        }
        guard !(favorites.isEmpty && recents.isEmpty && products.isEmpty) else { return [] }
        let matches = take(favorites + recents + products, limit: Int.max) {
            $0.title.localizedCaseInsensitiveContains(text)
        }
        let startsWith = matches.filter { Self.titleStarts($0.title, with: text) }
        let contains = matches.filter { !Self.titleStarts($0.title, with: text) }
        return [LibrarySearchGroup(title: "Your foods", items: Array((startsWith + contains).prefix(Self.searchMatchesLimit)))]
    }

    private func items(inSection title: String) -> [LibraryItem] {
        sections.first { $0.title == title }?.items ?? []
    }

    private static func searchIdentity(of item: LibraryItem) -> String {
        RecentItemsProvider.identityKey(
            category: item.template.category, snapshotID: item.template.productSnapshotID,
            names: item.template.components.map { $0.name }, meal: item.template.meal)
    }

    private static func kind(of item: LibraryItem) -> ProductKind? {
        item.template.productSnapshotID == nil ? ProductKind(rawValue: item.template.category) : item.kind
    }

    private static func titleStarts(_ title: String, with text: String) -> Bool {
        title.range(of: text, options: [.caseInsensitive, .anchored], range: nil, locale: .current) != nil
    }
}
