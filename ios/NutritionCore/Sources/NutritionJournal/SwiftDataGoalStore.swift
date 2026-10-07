import Foundation
import NutritionDomain
import SwiftData

/// One stored target. The decimal is kept as text rather than as a number column, because a target is
/// an exact amount and a rounded one would state a number the person never entered.
@Model
final class NutrientGoalRecord {
    /// The nutrient key, as the journal records it. One record per key.
    var nutrient: String
    /// Exact decimal text, POSIX.
    var targetText: String
    /// The registry symbol of the unit the target is stated in.
    var unitSymbol: String

    init(nutrient: String, targetText: String, unitSymbol: String) {
        self.nutrient = nutrient
        self.targetText = targetText
        self.unitSymbol = unitSymbol
    }
}

/// Goals in their own store file, `goals.store`, opened beside the journal, the favorites and the
/// recipes. Nothing here is shared or synced: a target is the person's own number.
public final class SwiftDataGoalStore: GoalStore, JournalErasing, @unchecked Sendable {
    private let lock = NSLock()
    /// Held across each whole write, so a save and an erase cannot read the same rows at once.
    private let writeLock = NSLock()
    private var container: ModelContainer?

    public init(url: URL) throws {
        let schema = Schema([NutrientGoalRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: configuration)
    }

    public func close() {
        lock.withLock { container = nil }
    }

    private func openContainer() throws -> ModelContainer {
        try lock.withLock {
            guard let container else { throw GoalStoreError.closed }
            return container
        }
    }

    /// Every readable target, ordered by nutrient key. A row that cannot be read is left out rather
    /// than reported as a target the person can trust: an unreadable decimal or an unknown unit is not
    /// a number, and a progress line against one would be a number of the wrong kind.
    public func goals() throws -> [NutrientGoal] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            sortBy: [SortDescriptor(\.nutrient)]))
        return rows.compactMap { try? Self.decode($0) }
    }

    public func goal(for nutrient: String) throws -> NutrientGoal? {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == nutrient }))
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// Writes the target for one key, replacing whatever was stored for it. One key is one target, so
    /// the old row is removed in the same save that writes the new one: a half-applied edit would
    /// otherwise leave the screen showing a target the store does not hold.
    public func setGoal(_ goal: NutrientGoal) throws {
        try goal.validate()
        let nutrient = goal.nutrient
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        let existing = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == nutrient }))
        for row in existing { context.delete(row) }
        context.insert(NutrientGoalRecord(
            nutrient: goal.nutrient, targetText: DecimalText.encode(goal.target),
            unitSymbol: goal.unit.symbol))
        try context.save()
    }

    public func removeGoal(nutrient: String) throws {
        let key = nutrient
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        let existing = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == key }))
        guard !existing.isEmpty else { return }
        for row in existing { context.delete(row) }
        try context.save()
    }

    /// Removes every target. A target is the person's own number, so it goes with everything else on
    /// "Erase all data"; the rows are deleted one at a time rather than with the batch delete, which
    /// runs against the persistent store immediately and so cannot be rolled back with the save. The
    /// store stays open, so targets can be set again straight away.
    public func eraseAll() throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        for row in try context.fetch(FetchDescriptor<NutrientGoalRecord>()) { context.delete(row) }
        try context.save()
    }

    private static func decode(_ row: NutrientGoalRecord) throws -> NutrientGoal {
        guard let target = DecimalText.decode(row.targetText), !target.isNaN, target > 0,
            let unit = try? UnitRegistry.unit(for: row.unitSymbol)
        else {
            throw GoalStoreError.corruptRecord(row.nutrient)
        }
        return NutrientGoal(nutrient: row.nutrient, target: target, unit: unit)
    }
}
