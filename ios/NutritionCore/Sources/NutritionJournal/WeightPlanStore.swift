import Foundation
import NutritionDomain

/// Where the weight plan is kept: one aim, an optional goal weight and an optional weekly pace.
///
/// There is at most one plan, so a second write replaces the first rather than leaving two plans to
/// choose between. A read that throws means the store cannot be trusted, never that the person has no
/// plan.
public protocol WeightPlanStore: AnyObject, Sendable {
    /// The stored plan, or nil when none is set.
    func weightPlan() throws -> WeightPlan?
    /// Writes the plan, replacing any plan already stored. A plan that fails `validate()` is not written.
    func setWeightPlan(_ plan: WeightPlan) throws
    /// Removes the stored plan. Removing when none is stored is not an error.
    func removeWeightPlan() throws
}

/// A weight plan held in memory, for tests and for a caller that has nowhere to persist to.
///
/// It answers exactly what it was given, so a test can hold a store that refuses a write or throws on
/// a read - states a real store reaches too.
public final class InMemoryWeightPlanStore: WeightPlanStore, @unchecked Sendable {
    private let lock = NSLock()
    private var plan: WeightPlan?
    private let failNextRead: Bool
    private let refusesWrites: Bool

    public init(plan: WeightPlan? = nil, failNextRead: Bool = false, refusesWrites: Bool = false) {
        self.plan = plan
        self.failNextRead = failNextRead
        self.refusesWrites = refusesWrites
    }

    private struct Unsupported: Error {}

    public func weightPlan() throws -> WeightPlan? {
        if failNextRead { throw Unsupported() }
        return lock.withLock { plan }
    }

    public func setWeightPlan(_ plan: WeightPlan) throws {
        if refusesWrites { throw Unsupported() }
        try plan.validate()
        lock.withLock { self.plan = plan }
    }

    public func removeWeightPlan() throws {
        if refusesWrites { throw Unsupported() }
        lock.withLock { plan = nil }
    }
}
