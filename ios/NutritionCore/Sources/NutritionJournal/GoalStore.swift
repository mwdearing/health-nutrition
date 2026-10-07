import Foundation
import NutritionDomain

/// What one nutrient's daily target is: the nutrient key the journal already uses, an exact decimal
/// target, and the metric unit it is counted in.
///
/// A goal is data, not a setting: it is stored, exported with nothing and erased with everything
/// else, because what a person eats against a target every day is theirs. There is one goal per
/// nutrient key, and no goal is a valid state - Today then shows the plain total.
public struct NutrientGoal: Sendable, Hashable {
    /// The nutrient key as the journal and the catalog name it, for example `protein`.
    public let nutrient: String
    /// The daily target, as an exact decimal.
    public let target: Decimal
    /// The unit the target is counted in, always one of the registry's metric units.
    public let unit: MeasureUnit

    public init(nutrient: String, target: Decimal, unit: MeasureUnit) {
        self.nutrient = nutrient
        self.target = target
        self.unit = unit
    }

    /// Rejects a goal a person could not act on: no nutrient, a target that is not a positive
    /// number, or a unit that is not the dimension the nutrient's total is read in. A target of zero
    /// would read as "already met" on every day, which is not a goal.
    ///
    /// The dimension check is what makes "2 g of energy" or "2000 kcal of water" impossible to store.
    /// Such a target compares against nothing: the total on screen is in kcal for energy and mL for
    /// water, and a number in another dimension beside it is a number the person set that the app
    /// cannot check and cannot show as met or missed. The expected dimension comes from the canonical
    /// nutrient mapping, so it is the same unit the totals provider and the HealthKit writer use. A
    /// nutrient no row maps has no dimension to check against, so only its amount is checked.
    public func validate() throws {
        let key = nutrient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw GoalStoreError.unknownNutrient
        }
        guard !target.isNaN, target > 0 else { throw GoalStoreError.invalidTarget }
        if let expected = HealthKitWritePlanner.mapping(for: key)?.unit,
            unit.dimension != expected.dimension
        {
            throw UnitError.dimensionMismatch(from: unit, to: expected)
        }
    }
}

public enum GoalStoreError: Error, Sendable, Equatable {
    case closed
    case unknownNutrient
    case invalidTarget
    /// A stored row that cannot be read: an unparseable decimal or a unit the registry rejects.
    case corruptRecord(String)
}

/// Where the daily targets are kept.
///
/// One goal per nutrient key, so a second write for a key replaces the first rather than leaving two
/// targets to choose between. A read that throws means the store cannot be trusted, never that the
/// person has no goals.
public protocol GoalStore: AnyObject, Sendable {
    /// Every stored goal, ordered by nutrient key.
    func goals() throws -> [NutrientGoal]
    /// The goal for one nutrient key, or nil when none is stored for it.
    func goal(for nutrient: String) throws -> NutrientGoal?
    /// Writes the goal, replacing any goal already stored for the same nutrient key.
    func setGoal(_ goal: NutrientGoal) throws
    /// Removes the goal for one nutrient key. Removing a key that has none is not an error.
    func removeGoal(nutrient: String) throws
    /// Releases the store; a new instance can reopen the same file.
    func close()
}

/// A goal store held in memory, for tests and for a caller that has nowhere to persist to.
///
/// It answers exactly what it was given, so a test can hold a store that refuses a write or throws
/// on a read - states a real store reaches too.
public final class InMemoryGoalStore: GoalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: NutrientGoal] = [:]
    private let failNextRead: Bool
    private let refusesWrites: Bool

    public init(goals: [NutrientGoal] = [], failNextRead: Bool = false, refusesWrites: Bool = false) {
        self.failNextRead = failNextRead
        self.refusesWrites = refusesWrites
        for goal in goals { stored[goal.nutrient] = goal }
    }

    private struct Unsupported: Error {}

    public func goals() throws -> [NutrientGoal] {
        if failNextRead { throw Unsupported() }
        return lock.withLock { stored.values.sorted { $0.nutrient < $1.nutrient } }
    }

    public func goal(for nutrient: String) throws -> NutrientGoal? {
        if failNextRead { throw Unsupported() }
        return lock.withLock { stored[nutrient] }
    }

    public func setGoal(_ goal: NutrientGoal) throws {
        if refusesWrites { throw Unsupported() }
        try goal.validate()
        lock.withLock { stored[goal.nutrient] = goal }
    }

    public func removeGoal(nutrient: String) throws {
        if refusesWrites { throw Unsupported() }
        lock.withLock { _ = stored.removeValue(forKey: nutrient) }
    }

    public func close() {
        lock.withLock { stored.removeAll() }
    }
}
