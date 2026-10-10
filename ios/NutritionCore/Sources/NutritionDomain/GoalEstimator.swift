import Foundation

/// The sex a goal estimate is computed for. A person who prefers not to say gets the midpoint constant.
public enum GoalSex: Sendable, Equatable {
    case female, male, unspecified
}

/// How much a person moves in a usual week, which sets the multiplier on resting energy.
public enum ActivityLevel: Sendable, Equatable, CaseIterable {
    case sedentary, light, moderate, veryActive

    /// The multiplier on resting energy for this level.
    public var multiplier: Decimal {
        switch self {
        case .sedentary: return GoalEstimator.sedentaryMultiplier
        case .light: return GoalEstimator.lightMultiplier
        case .moderate: return GoalEstimator.moderateMultiplier
        case .veryActive: return GoalEstimator.veryActiveMultiplier
        }
    }

    /// The plain words a person picks from.
    public var summary: String {
        switch self {
        case .sedentary: return "Little or no exercise"
        case .light: return "Light exercise 1 to 3 days a week"
        case .moderate: return "Moderate exercise 3 to 5 days a week"
        case .veryActive: return "Hard exercise 6 to 7 days a week"
        }
    }
}

/// What a person wants the targets to do.
public enum GoalAim: Sendable, Equatable {
    case lose, maintain, gain
    /// No targets: the person only wants to see their day.
    case justTrack
}

/// The answers the estimate is computed from. Nothing here is stored: the estimate is a calculation
/// on the answers, and the answers live only as long as the setup screen does.
public struct GoalProfile: Sendable, Equatable {
    public let sex: GoalSex
    public let ageYears: Int
    public let heightCentimeters: Decimal
    public let weightKilograms: Decimal
    public let activity: ActivityLevel
    public let aim: GoalAim
    /// The pace in kilograms a week. Read only when losing or gaining.
    public let weeklyChangeKilograms: Decimal

    public init(
        sex: GoalSex, ageYears: Int, heightCentimeters: Decimal, weightKilograms: Decimal,
        activity: ActivityLevel, aim: GoalAim, weeklyChangeKilograms: Decimal
    ) {
        self.sex = sex
        self.ageYears = ageYears
        self.heightCentimeters = heightCentimeters
        self.weightKilograms = weightKilograms
        self.activity = activity
        self.aim = aim
        self.weeklyChangeKilograms = weeklyChangeKilograms
    }
}

/// The input a goal estimate will not compute from.
public enum GoalEstimateField: Sendable, Equatable {
    case age, height, weight, weeklyChange
}

public enum GoalEstimateError: Error, Sendable, Equatable {
    /// The estimate is for adults only.
    case underAge
    /// A value outside the range the estimate is written for.
    case outOfRange(GoalEstimateField)
}

/// The daily targets an estimate gives. Energy is in kcal; the rest are grams, and fiber is grams too.
public struct GoalEstimate: Sendable, Equatable {
    public let energyKcal: Decimal
    public let carbohydrateGrams: Decimal
    public let proteinGrams: Decimal
    public let fatGrams: Decimal
    public let fiberGrams: Decimal
    /// Set when a floor or the daily cap changed the energy, so the screen can say so.
    public let adjustmentNote: String?

    public init(
        energyKcal: Decimal, carbohydrateGrams: Decimal, proteinGrams: Decimal,
        fatGrams: Decimal, fiberGrams: Decimal, adjustmentNote: String?
    ) {
        self.energyKcal = energyKcal
        self.carbohydrateGrams = carbohydrateGrams
        self.proteinGrams = proteinGrams
        self.fatGrams = fatGrams
        self.fiberGrams = fiberGrams
        self.adjustmentNote = adjustmentNote
    }
}

/// Turns a few answers into daily targets. Decimal arithmetic throughout, so no target depends on a
/// floating-point error, and no UI import, so the rules can be tested on their own.
///
/// The formula is Mifflin-St Jeor: resting energy is `10 * kg + 6.25 * cm - 5 * age + s`, with `s` of
/// +5 for a man, -161 for a woman and -78 (the midpoint) when the sex is not given. Daily energy is
/// resting energy times the activity multiplier. Losing or gaining adds or takes away the weekly pace
/// spread over the week: a kilogram of body change is about 7700 kcal, so a pace of `w` kilograms a
/// week is `w * 7700 / 7` kcal a day. That daily change is capped at 1000 kcal, and a loss never takes
/// the energy below 1500 kcal for a man or 1200 kcal for anyone else.
public enum GoalEstimator {
    /// The estimate is for adults, between these ages.
    public static let minimumAge = 18
    public static let maximumAge = 100

    /// The ranges the other answers must fall in, inclusive.
    public static let heightRangeCentimeters: ClosedRange<Decimal> = 120...230
    public static let weightRangeKilograms: ClosedRange<Decimal> = 30...300
    public static let paceRangeKilograms: ClosedRange<Decimal> = Decimal(string: "0.1")!...Decimal(string: "1.0")!

    /// The energy a kilogram of body change is worth, and the largest daily change the estimate makes.
    public static let kcalPerKilogram: Decimal = 7700
    public static let dailyChangeCapKcal: Decimal = 1000

    /// Exact decimal factors, written as text so no binary float is involved.
    static let sedentaryMultiplier = Decimal(string: "1.2")!
    static let lightMultiplier = Decimal(string: "1.375")!
    static let moderateMultiplier = Decimal(string: "1.55")!
    static let veryActiveMultiplier = Decimal(string: "1.725")!
    static let heightFactor = Decimal(string: "6.25")!
    static let carbohydrateShare = Decimal(string: "0.5")!
    static let proteinShare = Decimal(string: "0.2")!
    static let fatShare = Decimal(string: "0.3")!
    /// Fiber is 14 g per 1000 kcal, so 14 / 1000 of each kcal.
    static let fiberGramsPerKcal = Decimal(string: "0.014")!

    /// The lowest energy a loss is allowed to reach.
    public static let lossFloorMaleKcal: Decimal = 1500
    public static let lossFloorOtherKcal: Decimal = 1200

    /// The notes the screen shows when a floor or the cap changed the energy.
    public static let floorNote = "We raised your daily calories to the minimum we suggest."
    public static let capNote = "We limited the daily change to 1,000 calories."

    /// Mifflin-St Jeor resting energy, before any rounding.
    public static func restingEnergy(_ profile: GoalProfile) -> Decimal {
        let constant: Decimal
        switch profile.sex {
        case .male: constant = 5
        case .female: constant = -161
        case .unspecified: constant = -78
        }
        return 10 * profile.weightKilograms
            + heightFactor * profile.heightCentimeters
            - 5 * Decimal(profile.ageYears)
            + constant
    }

    /// Resting energy times the activity multiplier, before the aim and before any rounding.
    public static func dailyEnergy(_ profile: GoalProfile) -> Decimal {
        restingEnergy(profile) * profile.activity.multiplier
    }

    /// The targets for the answers, or nil for "just track", which computes none.
    ///
    /// Throws for an age under 18 and for any value outside the ranges above. A pace is checked only when
    /// losing or gaining, because it is not asked for otherwise.
    public static func estimate(_ profile: GoalProfile) throws -> GoalEstimate? {
        if profile.aim == .justTrack { return nil }
        try validate(profile)

        var energy = dailyEnergy(profile)
        var notes: [String] = []
        if profile.aim == .lose || profile.aim == .gain {
            var change = profile.weeklyChangeKilograms * kcalPerKilogram / 7
            if change > dailyChangeCapKcal {
                change = dailyChangeCapKcal
                notes.append(capNote)
            }
            energy = profile.aim == .lose ? energy - change : energy + change
            if profile.aim == .lose {
                let floor = profile.sex == .male ? lossFloorMaleKcal : lossFloorOtherKcal
                if energy < floor {
                    energy = floor
                    notes.append(floorNote)
                }
            }
        }

        // Energy to the nearest 10 kcal. Every macro is worked from the rounded figure, so the grams and
        // the calories a person sees agree.
        let kcal = roundedTo(energy, step: 10)
        return GoalEstimate(
            energyKcal: kcal,
            carbohydrateGrams: roundedTo(kcal * carbohydrateShare / 4, step: 5),
            proteinGrams: roundedTo(kcal * proteinShare / 4, step: 5),
            fatGrams: roundedTo(kcal * fatShare / 9, step: 5),
            fiberGrams: roundedTo(kcal * fiberGramsPerKcal, step: 1),
            adjustmentNote: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func validate(_ profile: GoalProfile) throws {
        if profile.ageYears < minimumAge { throw GoalEstimateError.underAge }
        if profile.ageYears > maximumAge { throw GoalEstimateError.outOfRange(.age) }
        if !heightRangeCentimeters.contains(profile.heightCentimeters) {
            throw GoalEstimateError.outOfRange(.height)
        }
        if !weightRangeKilograms.contains(profile.weightKilograms) {
            throw GoalEstimateError.outOfRange(.weight)
        }
        if profile.aim == .lose || profile.aim == .gain,
            !paceRangeKilograms.contains(profile.weeklyChangeKilograms)
        {
            throw GoalEstimateError.outOfRange(.weeklyChange)
        }
    }

    /// `value` to the nearest multiple of `step`, halves rounded away from zero.
    private static func roundedTo(_ value: Decimal, step: Decimal) -> Decimal {
        var quotient = value / step
        var whole = Decimal()
        NSDecimalRound(&whole, &quotient, 0, .plain)
        return whole * step
    }
}
