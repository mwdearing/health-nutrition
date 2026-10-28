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
        return try rows.filter { !$0.nutrient.hasPrefix(Self.receiptPrefix) }.map(Self.decode)
    }

    /// A restore receipt is a row of this same table under a prefix no nutrient key can start with, so it is
    /// written in the same store and erased with the goals, and the reads above skip it. On "restore-receipt:"
    /// rows only, `targetText` holds JSON (the planned goals), not a decimal; only the receipt helpers read it, and
    /// an unreadable one throws, so the caller fails closed instead of guessing at keys.
    private static let receiptPrefix = "restore-receipt:"

    private struct ReceiptEntry: Codable {
        let nutrient: String
        let target: String
        let unit: String
    }

    public func recordGoalRestoreReceipt(_ receipt: String, goals: [NutrientGoal]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let id = Self.receiptPrefix + receipt
        let entries = goals.map {
            ReceiptEntry(nutrient: $0.nutrient, target: DecimalText.encode($0.target), unit: $0.unit.symbol)
        }
        let text = try Self.encodeReceipt(ReceiptPayload(done: false, goals: entries, written: []))
        let context = ModelContext(try openContainer())
        for old in try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == id })) {
            context.delete(old)
        }
        context.insert(NutrientGoalRecord(nutrient: id, targetText: text, unitSymbol: ""))
        try context.save()
    }

    /// Marks the restore's goals as all written, so a resume that finds this receipt does not add any of them again.
    /// A goal the person deleted after this point stays deleted.
    public func markGoalRestoreReceiptDone(_ receipt: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let id = Self.receiptPrefix + receipt
        let context = ModelContext(try openContainer())
        guard let row = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == id })).first else {
            // A receipt is recorded before its goals are written, so one that is missing here is a store that lost it.
            throw JournalImportError.corrupt("the goal restore receipt is missing")
        }
        let payload = try Self.decodeReceipt(row.targetText)
        // A receipt still listing goals is not all written; marking it done would let a resume skip them.
        row.targetText = try Self.encodeReceipt(ReceiptPayload(done: true, goals: payload.goals, written: payload.written ?? []))
        try context.save()
    }

    /// Writes one restored goal and drops it from the receipt in the same save, so a stop cannot leave the goal written
    /// while its receipt entry still says it is pending. A goal the person already holds is left as it is, and the entry
    /// is dropped all the same. Returns whether this call wrote the goal.
    public func writeRestoredGoal(_ goal: NutrientGoal, receipt: String) throws -> Bool {
        try goal.validate()
        guard !goal.nutrient.hasPrefix(Self.receiptPrefix) else { throw GoalStoreError.unknownNutrient }
        writeLock.lock()
        defer { writeLock.unlock() }
        let id = Self.receiptPrefix + receipt
        let nutrient = goal.nutrient
        let context = ModelContext(try openContainer())
        guard let receiptRow = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == id })).first else {
            throw JournalImportError.corrupt("the goal restore receipt is missing")
        }
        let payload = try Self.decodeReceipt(receiptRow.targetText)
        let existing = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == nutrient }))
        let written = existing.isEmpty
        if written {
            context.insert(NutrientGoalRecord(
                nutrient: nutrient, targetText: DecimalText.encode(goal.target), unitSymbol: goal.unit.symbol))
        }
        // The entry leaves the pending list, and a goal this call wrote joins the ledger, in the same save as the write.
        let ledger = written ? (payload.written ?? []) + [ReceiptEntry(
            nutrient: nutrient, target: DecimalText.encode(goal.target), unit: goal.unit.symbol)] : (payload.written ?? [])
        receiptRow.targetText = try Self.encodeReceipt(ReceiptPayload(
            done: payload.done, goals: payload.goals.filter { $0.nutrient != nutrient }, written: ledger))
        try context.save()
        return written
    }

    public func goalRestoreReceiptDone(_ receipt: String) throws -> Bool? {
        let id = Self.receiptPrefix + receipt
        let context = ModelContext(try openContainer())
        guard let row = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == id })).first else { return nil }
        return try Self.decodeReceipt(row.targetText).done
    }

    /// `goals` is what is still to be written; `written` is every goal this restore wrote, from any run, so an undo can
    /// remove exactly those. A receipt from before the ledger has no `written`, which reads as none.
    private struct ReceiptPayload: Codable {
        let done: Bool
        let goals: [ReceiptEntry]
        let written: [ReceiptEntry]?
    }

    /// The goals this restore wrote, from any run, as the receipt's ledger holds them. Empty when there is no receipt.
    public func goalRestoreWrittenGoals(_ receipt: String) throws -> [NutrientGoal] {
        let id = Self.receiptPrefix + receipt
        let context = ModelContext(try openContainer())
        guard let row = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == id })).first else { return [] }
        return try (Self.decodeReceipt(row.targetText).written ?? []).map { entry in
            guard let target = DecimalText.decode(entry.target), let unit = try? MeasureUnit(symbol: entry.unit)
            else { throw JournalImportError.corrupt("the goal restore receipt holds a target this build cannot read") }
            return NutrientGoal(nutrient: entry.nutrient, target: target, unit: unit)
        }
    }

    private static func encodeReceipt(_ payload: ReceiptPayload) throws -> String {
        String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    private static func decodeReceipt(_ text: String) throws -> ReceiptPayload {
        try JSONDecoder().decode(ReceiptPayload.self, from: Data(text.utf8))
    }

    public func goalRestoreReceipt(_ receipt: String) throws -> [NutrientGoal]? {
        let id = Self.receiptPrefix + receipt
        let context = ModelContext(try openContainer())
        guard let row = try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == id })).first else { return nil }
        let entries = try Self.decodeReceipt(row.targetText).goals
        return try entries.map { entry in
            guard let target = DecimalText.decode(entry.target), let unit = try? MeasureUnit(symbol: entry.unit)
            else { throw JournalImportError.corrupt("the goal restore receipt holds a target this build cannot read") }
            return NutrientGoal(nutrient: entry.nutrient, target: target, unit: unit)
        }
    }

    public func removeGoalRestoreReceipt(_ receipt: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let id = Self.receiptPrefix + receipt
        let context = ModelContext(try openContainer())
        for old in try context.fetch(FetchDescriptor<NutrientGoalRecord>(
            predicate: #Predicate<NutrientGoalRecord> { $0.nutrient == id })) {
            context.delete(old)
        }
        try context.save()
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
        // The receipt namespace is the store's own: a goal under it would be hidden from reads and could overwrite a live
        // receipt. The receipt writers insert their rows directly, so they never reach this check.
        guard !goal.nutrient.hasPrefix(Self.receiptPrefix) else { throw GoalStoreError.unknownNutrient }
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

    /// Adds a second plan row beside the stored one. `setWeightPlan` replaces the row it finds, so the
    /// store's own API never leaves two; a test of the read path plants them through this hook.
    func insertExtraPlanForTesting(_ plan: WeightPlan) throws {
        let context = ModelContext(try openContainer())
        context.insert(WeightPlanRecord(
            aimText: plan.aim.storageText,
            goalText: plan.goalKilograms.map { DecimalText.encode($0) },
            paceText: plan.weeklyPaceKilograms.map { DecimalText.encode($0) }))
        try context.save()
    }
}
