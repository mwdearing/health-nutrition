import Foundation

/// Why a weight plan is not usable as entered.
public enum WeightPlanError: Error, Sendable, Equatable {
    /// Just tracking has no targets to check.
    case noPlanForJustTrack
    /// A loss or gain plan has no goal weight.
    case missingGoal
    /// A loss or gain plan has no weekly pace.
    case missingPace
    /// A maintain plan carries a goal weight.
    case unexpectedGoal
    /// A maintain plan carries a weekly pace.
    case unexpectedPace
    /// The goal weight is outside the range the estimate accepts.
    case goalOutOfRange
    /// The weekly pace is outside the range the estimate accepts.
    case paceOutOfRange
    /// A loss plan's goal is not below the current weight.
    case goalNotBelowCurrent
    /// A gain plan's goal is not above the current weight.
    case goalNotAboveCurrent
}

/// The targets a person sets for their weight: the aim, and for a loss or gain the goal weight and the
/// weekly pace. The checks here cover the shape of the plan; the estimate uses the values as entered.
public struct WeightPlan: Sendable, Equatable {
    /// What the person is working towards.
    public let aim: GoalAim
    /// The goal weight in kilograms, when the aim has one.
    public let goalKilograms: Decimal?
    /// The weekly change in kilograms, when the aim has one.
    public let weeklyPaceKilograms: Decimal?

    /// A plan with the given aim and targets. Nothing is checked until `validate()` is called.
    public init(aim: GoalAim, goalKilograms: Decimal?, weeklyPaceKilograms: Decimal?) {
        self.aim = aim
        self.goalKilograms = goalKilograms
        self.weeklyPaceKilograms = weeklyPaceKilograms
    }

    /// Checks the targets against the aim, in this order: the aim must have a plan, the targets it needs
    /// must be present and not the ones it forbids, then each value must fall in its range.
    public func validate() throws {
        switch aim {
        case .justTrack:
            throw WeightPlanError.noPlanForJustTrack
        case .maintain:
            if goalKilograms != nil {
                throw WeightPlanError.unexpectedGoal
            }
            if weeklyPaceKilograms != nil {
                throw WeightPlanError.unexpectedPace
            }
        case .lose, .gain:
            guard let goalKilograms else {
                throw WeightPlanError.missingGoal
            }
            guard let weeklyPaceKilograms else {
                throw WeightPlanError.missingPace
            }
            if !GoalEstimator.weightRangeKilograms.contains(goalKilograms) {
                throw WeightPlanError.goalOutOfRange
            }
            if !GoalEstimator.paceRangeKilograms.contains(weeklyPaceKilograms) {
                throw WeightPlanError.paceOutOfRange
            }
        }
    }

    /// `validate()`, then the goal must lie in the direction the aim points from `currentKilograms`:
    /// below it for a loss, above it for a gain. A maintain plan needs nothing more.
    public func validate(currentKilograms: Decimal) throws {
        try validate()
        switch aim {
        case .lose:
            if let goalKilograms, goalKilograms >= currentKilograms {
                throw WeightPlanError.goalNotBelowCurrent
            }
        case .gain:
            if let goalKilograms, goalKilograms <= currentKilograms {
                throw WeightPlanError.goalNotAboveCurrent
            }
        case .maintain, .justTrack:
            break
        }
    }
}

extension GoalAim {
    /// The fixed text the aim is stored as. Storage reads it back with `init?(storageText:)`.
    public var storageText: String {
        switch self {
        case .lose: "lose"
        case .maintain: "maintain"
        case .gain: "gain"
        case .justTrack: "just-track"
        }
    }

    /// The aim with this stored text, or nil for any other text (the match is exact, including case).
    public init?(storageText: String) {
        switch storageText {
        case "lose": self = .lose
        case "maintain": self = .maintain
        case "gain": self = .gain
        case "just-track": self = .justTrack
        default: return nil
        }
    }
}
