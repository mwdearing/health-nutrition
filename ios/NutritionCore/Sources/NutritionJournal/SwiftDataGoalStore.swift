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

/// The one stored weight plan. The decimals are kept as text for the same reason as a target: each is
/// an exact amount, and a rounded one would state a number the person never entered.
@Model
final class WeightPlanRecord {
    /// The aim's storage text, one of the four aims the plan can hold.
    var aimText: String
    /// The goal weight in kilograms as exact decimal text, or nil when no goal weight is set.
    var goalText: String?
    /// The weekly pace in kilograms as exact decimal text, or nil when no pace is set.
    var paceText: String?

    init(aimText: String, goalText: String?, paceText: String?) {
        self.aimText = aimText
        self.goalText = goalText
        self.paceText = paceText
    }
}

/// Goals and the weight plan in their own store file, `goals.store`, opened beside the journal, the
/// favorites and the recipes. Nothing here is shared or synced: a target is the person's own number.
public final class SwiftDataGoalStore: GoalStore, WeightPlanStore, JournalErasing, @unchecked Sendable {
    private let lock = NSLock()
    /// Held across each whole write, so a save and an erase cannot read the same rows at once.
    private let writeLock = NSLock()
    private var container: ModelContainer?

    public init(url: URL) throws {
        let schema = Schema([NutrientGoalRecord.self, WeightPlanRecord.self])
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

    /// Every readable target, ordered by nutrient key.
    ///
    /// A row that cannot be read fails the whole read rather than being left out. `goal(for:)` already
    /// throws for such a row, and dropping one here made the two disagree about the same store: this
    /// returned a shorter list that looked complete, so a corrupt row read as "no goal set for this
    /// nutrient" rather than as a store that needs attention. A caller that cannot get a trustworthy
    /// list cannot tell that one, and its own read-failure state is the only honest place for it to
    /// land — the goals screen already shows one, and Today reports the store as unreadable.
    public func goals() throws -> [NutrientGoal] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            sortBy: [SortDescriptor(\.nutrient)]))
        return try rows.map(Self.decode)
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

    /// The stored plan, or nil when none is stored. A row that cannot be read fails the read rather than
    /// reading as no plan: a corrupt plan is a store that needs attention, not an empty one.
    public func weightPlan() throws -> WeightPlan? {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<WeightPlanRecord>())
        guard let row = rows.first else { return nil }
        // One plan at most: a second row means the store no longer says which plan the person set.
        guard rows.count == 1 else { throw GoalStoreError.corruptRecord("weight plan") }
        return try Self.decode(row)
    }

    /// Writes the plan, replacing whatever plan was stored. The plan is validated before anything is
    /// written, so a refused plan leaves the stored one in place. The old row is removed in the same
    /// save that writes the new one, as a goal's is.
    public func setWeightPlan(_ plan: WeightPlan) throws {
        try plan.validate()
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        for row in try context.fetch(FetchDescriptor<WeightPlanRecord>()) { context.delete(row) }
        context.insert(WeightPlanRecord(
            aimText: plan.aim.storageText,
            goalText: plan.goalKilograms.map { DecimalText.encode($0) },
            paceText: plan.weeklyPaceKilograms.map { DecimalText.encode($0) }))
        try context.save()
    }

    /// Removes the stored plan. A save happens only when there was a row to remove.
    public func removeWeightPlan() throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        let existing = try context.fetch(FetchDescriptor<WeightPlanRecord>())
        guard !existing.isEmpty else { return }
        for row in existing { context.delete(row) }
        try context.save()
    }

    public var erasureName: String { "goals" }

    /// Removes every target and the weight plan. Both are the person's own numbers, so they go with
    /// everything else on "Erase all data"; the rows are deleted one at a time rather than with the batch
    /// delete, which runs against the persistent store immediately and so cannot be rolled back with the
    /// save. The store stays open, so targets and a plan can be set again straight away.
    public func eraseAll() throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        for row in try context.fetch(FetchDescriptor<NutrientGoalRecord>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<WeightPlanRecord>()) { context.delete(row) }
        try context.save()
    }

    private static func decode(_ row: NutrientGoalRecord) throws -> NutrientGoal {
        // `Decimal(string:)` reads a leading number out of "6O g"; the stored text must be a whole decimal.
        guard DecimalText.isValidDecimalText(row.targetText), let target = DecimalText.decode(row.targetText),
            !target.isNaN, target > 0,
            let unit = try? UnitRegistry.unit(for: row.unitSymbol)
        else {
            throw GoalStoreError.corruptRecord(row.nutrient)
        }
        return NutrientGoal(nutrient: row.nutrient, target: target, unit: unit)
    }

    /// Reads the stored plan back. Any field that cannot be read, or a plan that fails `validate()`, is a
    /// corrupt row: none of it is returned as a partial plan.
    private static func decode(_ row: WeightPlanRecord) throws -> WeightPlan {
        guard let aim = GoalAim(storageText: row.aimText) else {
            throw GoalStoreError.corruptRecord("weight plan")
        }
        let goalKilograms = try decodeKilograms(row.goalText)
        let weeklyPaceKilograms = try decodeKilograms(row.paceText)
        let plan = WeightPlan(
            aim: aim, goalKilograms: goalKilograms, weeklyPaceKilograms: weeklyPaceKilograms)
        do {
            try plan.validate()
        } catch {
            throw GoalStoreError.corruptRecord("weight plan")
        }
        return plan
    }

    /// An optional kilogram field: nil stays nil, and text must be a whole decimal to be read.
    private static func decodeKilograms(_ text: String?) throws -> Decimal? {
        guard let text else { return nil }
        guard DecimalText.isValidDecimalText(text), let value = DecimalText.decode(text), !value.isNaN else {
            throw GoalStoreError.corruptRecord("weight plan")
        }
        return value
    }

    /// Rewrites a stored target into a shape the read path cannot decode: an unparseable decimal, or a
    /// unit symbol the registry does not hold.
    ///
    /// `setGoal` validates before it writes, so the store's own API cannot produce such a row and a
    /// test of the read path needs to plant one. This is the same shape of hook the journal store
    /// exposes for rows its writer could not have written — a truncated write, a store written by a
    /// build that stored a unit this registry no longer holds.
    func writeCorruptTargetForTesting(
        nutrient: String, targetText: String? = nil, unitSymbol: String? = nil
    ) throws {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == nutrient }))
        guard let row = rows.first else { throw GoalStoreError.corruptRecord(nutrient) }
        if let targetText { row.targetText = targetText }
        if let unitSymbol { row.unitSymbol = unitSymbol }
        try context.save()
    }

    /// Rewrites the stored plan's fields into shapes the read path cannot decode: an aim outside the four
    /// storage texts, or decimal text that is not a whole decimal.
    ///
    /// `setWeightPlan` validates before it writes, so the store's own API cannot produce such a row. A test
    /// of the read path plants one through this hook, as `writeCorruptTargetForTesting` does for goals.
    func writeCorruptPlanForTesting(
        aimText: String? = nil, goalText: String? = nil, paceText: String? = nil
    ) throws {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<WeightPlanRecord>())
        guard let row = rows.first else { throw GoalStoreError.corruptRecord("weight plan") }
        if let aimText { row.aimText = aimText }
        if let goalText { row.goalText = goalText }
        if let paceText { row.paceText = paceText }
        try context.save()
    }
}
