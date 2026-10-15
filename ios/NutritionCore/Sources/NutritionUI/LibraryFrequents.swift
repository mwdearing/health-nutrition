import Foundation
import NutritionDomain
import NutritionJournal

/// An item the person logs often, derived from the journal and not stored.
public struct FrequentItem: Equatable, Identifiable {
    /// The Library's identity key, the same one a recent item carries.
    public let id: String
    /// Built from the newest entry of the item, so it repeats what was last logged.
    public let template: RepeatTemplate
    /// How many of the counted entries are this item.
    public let count: Int
    public let lastUsedAt: Date
}

/// Items logged at least `minimumCount` times among the newest active entries, most often first.
///
/// Counted over the newest `window` entries rather than a span of days, so the list follows what the person
/// logs now without a clock: at about 15 entries a day the window is two weeks, at 5 a day about six weeks.
/// An item is identified as a recent is (snapshot or category and component names, and the meal), so the
/// same oats at breakfast and at dinner are counted apart. Water is left out: it has its own quick add, and
/// counted here it would push every food off the list. Ties go to the item used most recently.
public struct FrequentItemsProvider {
    public static let window = 200
    public static let minimumCount = 2
    public static let defaultLimit = 10
    private let store: JournalStore

    public init(store: JournalStore) {
        self.store = store
    }

    public func frequents(
        limit: Int = FrequentItemsProvider.defaultLimit, window: Int = FrequentItemsProvider.window
    ) throws -> [FrequentItem] {
        let intakes = try store.activeIntakes()
            .filter { $0.lifecycle == .active && $0.category != DailyTotalsBuilder.waterCategory }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(window)
        var counts: [String: Int] = [:]
        // The newest entry of each item, kept as read: a template (which may read a product) is built only
        // for an item that turns out to be logged often, not for every item seen once.
        var newest: [String: (intake: Intake, revision: IntakeRevision)] = [:]
        for intake in intakes {
            // An entry with no amounts cannot be repeated, so it is not counted toward anything.
            guard let revisions = try? store.revisions(of: intake.id),
                let current = revisions.first(where: { $0.number == intake.currentRevision }),
                !current.components.isEmpty
            else { continue }
            let key = RecentItemsProvider.key(category: intake.category, revision: current, meal: intake.meal)
            counts[key, default: 0] += 1
            // Entries come newest first, so the first one seen is the one the item repeats.
            guard newest[key] == nil else { continue }
            newest[key] = (intake: intake, revision: current)
        }
        let provider = RecentItemsProvider(store: store)
        var items: [FrequentItem] = []
        for (key, value) in newest {
            guard let count = counts[key], count >= Self.minimumCount else { continue }
            items.append(FrequentItem(
                id: key, template: provider.template(intake: value.intake, revision: value.revision), count: count,
                lastUsedAt: value.intake.occurredAt))
        }
        return Array(items.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.id < $1.id
        }.prefix(limit))
    }
}
