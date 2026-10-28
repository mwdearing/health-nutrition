import Combine
import Foundation
import NutritionDomain
import SwiftUI

/// What Apple Health reports for today's activity and recent weight. Every value is optional: Health
/// never says whether read access was granted, so "no data" and "not allowed" look the same.
public struct BodyActivityReadings: Equatable, Sendable {
    public var steps: Decimal?
    public var activeEnergyKcal: Decimal?
    public var latestWeightKg: Decimal?
    public var latestWeightDate: Date?
    /// The newest height in Health, in centimeters, used only to prefill goal setup. Never stored.
    public var latestHeightCm: Decimal?
    /// Every weigh-in of the last 28 days, each on its local day, for the trend.
    public var weightSamples: [WeightSample]
    /// Today's nutrient totals from entries other apps wrote to Health, per canonical nutrient key, in
    /// each key's unit. Entries this app wrote are left out, so nothing is counted twice.
    public var outsideNutrients: [String: Decimal]
    /// True when reading other apps' entries failed, so the card says so instead of showing nothing.
    public var outsideReadFailed: Bool
    /// True only when the app target actually tried to read other apps' entries this time.
    public var outsideRead: Bool
    /// The canonical keys whose Health query succeeded this read. A key here with no value is a known zero.
    public var outsideReadKeys: Set<String>

    public init(
        steps: Decimal? = nil, activeEnergyKcal: Decimal? = nil, latestWeightKg: Decimal? = nil,
        latestWeightDate: Date? = nil, weightSamples: [WeightSample] = [],
        outsideNutrients: [String: Decimal] = [:], outsideReadFailed: Bool = false, outsideRead: Bool = false,
        outsideReadKeys: Set<String> = []
    ) {
        self.outsideNutrients = outsideNutrients
        self.outsideReadFailed = outsideReadFailed
        self.outsideRead = outsideRead
        self.outsideReadKeys = outsideReadKeys
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.latestWeightKg = latestWeightKg
        self.latestWeightDate = latestWeightDate
        self.weightSamples = weightSamples
    }

    public static let empty = BodyActivityReadings()
    public var isEmpty: Bool { self == .empty }

    /// Health's side of Today's totals, from this read.
    public var outsideIntake: HealthIntakeTotals.Outside {
        guard outsideRead else { return .notConnected }
        return .read(values: outsideNutrients, readKeys: outsideReadKeys)
    }
}

/// The app target's HealthKit reader. This package never imports HealthKit.
@MainActor
public protocol BodyActivityReading: AnyObject {
    /// Whether the person has been shown the read request on this device.
    var hasAskedForReadAccess: Bool { get }
    /// Asks Health for read access to steps, active energy and weight.
    func requestReadAccess() async
    /// Today's steps and active energy, the latest weight, and every weigh-in of the last 28 days for the trend.
    func read(now: Date) async -> BodyActivityReadings
}

/// The activity and weight card on Today.
@MainActor
public final class BodyActivityViewModel: ObservableObject {
    @Published public private(set) var readings: BodyActivityReadings = .empty
    @Published public private(set) var isBusy = false
    @Published public private(set) var hasAsked: Bool
    /// The planned pace beside the trend's pace and goal days, when the saved plan aims at a goal.
    @Published public private(set) var paceComparison: PaceComparison?
    private var trend: WeightTrendResult?
    private var plan: WeightPlan?
    private let reader: any BodyActivityReading
    private let unitSystem: () -> UnitSystem
    private let weightPlan: () -> WeightPlan?
    private let calendar: Calendar
    /// Called with every fresh read, so Today can count active energy toward the calorie goal.
    public var onRead: ((BodyActivityReadings) -> Void)?

    /// Pounds per kilogram, exact to the definition of the pound.
    static let poundsPerKilogram = Decimal(string: "2.20462262185")!

    public init(
        reader: any BodyActivityReading, unitSystem: @escaping () -> UnitSystem,
        weightPlan: @escaping () -> WeightPlan? = { nil }, calendar: Calendar = .current
    ) {
        self.reader = reader
        self.unitSystem = unitSystem
        self.weightPlan = weightPlan
        self.calendar = calendar
        self.hasAsked = reader.hasAskedForReadAccess
    }

    public func load(now: Date) async {
        hasAsked = reader.hasAskedForReadAccess
        guard hasAsked else {
            readings = .empty
            applyWeightPlan(now: now)
            onRead?(readings)
            return
        }
        readings = await reader.read(now: now)
        applyWeightPlan(now: now)
        onRead?(readings)
    }

    /// Reads the saved plan, then the trend through the local day of `now`, then the plan beside the trend.
    /// The pace comparison needs a loss or gain plan with a goal and a pace, and a current weight from the
    /// trend or else the latest weigh-in. The day is read as a Gregorian date in the calendar's time zone,
    /// so a device set to another calendar gets the same day.
    private func applyWeightPlan(now: Date) {
        plan = weightPlan()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: now)
        guard let through = CalendarDay(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        else {
            trend = nil
            paceComparison = nil
            return
        }
        let aimsAtGoal = plan?.aim == .lose || plan?.aim == .gain
        let result = WeightTrend.compute(
            samples: readings.weightSamples, through: through,
            goalKilograms: aimsAtGoal ? plan?.goalKilograms : nil)
        trend = result
        guard aimsAtGoal, let plan, let goal = plan.goalKilograms, let pace = plan.weeklyPaceKilograms,
              let current = result.trendKilograms ?? readings.latestWeightKg
        else {
            paceComparison = nil
            return
        }
        paceComparison = PlanProjection.compare(
            aim: plan.aim, weeklyPaceKilograms: pace, currentKilograms: current, goalKilograms: goal,
            trend: result)
    }

    /// Shows Health's read request, then reads.
    public func connect(now: Date) async {
        guard !isBusy else { return }
        isBusy = true
        await reader.requestReadAccess()
        isBusy = false
        await load(now: now)
    }

    public static let title = "Activity and weight"
    public static let connectTitle = "Show steps, activity and weight"
    public static let connectDetail =
        "Reads today's steps, active energy and your weight from the Health app on this device. "
        + "Nothing is sent anywhere."
    /// Health hides whether read access was granted, so an empty card names both reasons.
    public static let emptyDetail =
        "No steps, activity or weight in Health yet. If you did not allow reading, open the Health app, "
        + "tap Sharing, then Apps, then HealthNutrition."

    public var showsConnect: Bool { !hasAsked }

    public var stepsText: String? {
        readings.steps.map { "\(Self.whole($0)) steps" }
    }

    public var activeEnergyText: String? {
        readings.activeEnergyKcal.map { "\(Self.whole($0)) Calories active" }
    }

    public var weightText: String? {
        readings.latestWeightKg.map { weight($0) }
    }

    /// "From other apps: 620 kcal, 48 g protein, 16 fl oz water", naming only what other apps logged today.
    public var outsideText: String? {
        // A partial failure still shows the values that were read; the failure copy is only for a read with nothing.
        var parts: [String] = []
        // One check for every nutrient: a value is shown only when its read completed.
        func completed(_ key: String) -> Decimal? {
            readings.outsideReadKeys.contains(key) ? readings.outsideNutrients[key] : nil
        }
        if let energy = completed("energy") { parts.append("\(Self.whole(energy)) Calories") }
        if let protein = completed("protein") { parts.append("\(Self.whole(protein)) g protein") }
        if let water = completed("water") {
            if unitSystem() == .usCustomary {
                parts.append("\(Self.whole(water / Self.millilitersPerFluidOunce)) fl oz water")
            } else {
                parts.append("\(Self.whole(water)) mL water")
            }
        }
        guard !parts.isEmpty else {
            // Nothing was read: a failed query and no successful query and no value.
            return readings.outsideReadFailed && readings.outsideReadKeys.isEmpty ? "From other apps: could not be read" : nil
        }
        return "From other apps: " + parts.joined(separator: ", ")
    }

    /// Milliliters per US fluid ounce, exact to the definition.
    static let millilitersPerFluidOunce = Decimal(string: "29.5735295625")!

    /// "Trend: down 0.5 kg a week", "Trend: up 1.1 lb a week", or "Trend: no change" when the weekly change
    /// rounds to zero at two places; nil without a trend.
    public var weightTrendText: String? {
        guard let weekly = trend?.weeklyChangeKilograms else { return nil }
        if Self.rounded(converted(abs(weekly)), toPlaces: 2) == 0 { return "Trend: no change" }
        return "Trend: " + (weekly < 0 ? "down " : "up ") + weeklyChange(abs(weekly))
    }

    /// "Plan: down 0.25 kg a week", or "Plan: up 1 lb a week" for a gain; nil unless the saved plan is a
    /// loss or gain with a pace.
    public var planPaceText: String? {
        guard let plan, plan.aim == .lose || plan.aim == .gain, let pace = plan.weeklyPaceKilograms
        else { return nil }
        return "Plan: " + (plan.aim == .lose ? "down " : "up ") + weeklyChange(pace)
    }

    /// "Plan reaches 80 kg on Dec 23, 2026", from the planned pace.
    public var planGoalDayText: String? {
        guard let day = paceComparison?.plannedGoalDay, let goal = plan?.goalKilograms else { return nil }
        return "Plan reaches \(weight(goal)) on \(Self.dayText(day))"
    }

    /// "Trend reaches 80 kg on Aug 19, 2026", from the trend's projected goal day.
    public var trendGoalDayText: String? {
        guard let day = paceComparison?.trendGoalDay, let goal = plan?.goalKilograms else { return nil }
        return "Trend reaches \(weight(goal)) on \(Self.dayText(day))"
    }

    /// "Jan 5, 2027": English month names, no locale.
    public static func dayText(_ day: CalendarDay) -> String {
        "\(monthNames[day.month - 1]) \(day.day), \(day.year)"
    }

    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Rounded to `places` decimal places, compared as a number so the test does not depend on the locale's
    /// digits.
    static func rounded(_ value: Decimal, toPlaces places: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, places, .plain)
        return result
    }

    private func converted(_ kilograms: Decimal) -> Decimal {
        unitSystem() == .usCustomary ? kilograms * Self.poundsPerKilogram : kilograms
    }

    private func weight(_ kilograms: Decimal) -> String {
        Self.oneDecimal(converted(kilograms)) + (unitSystem() == .usCustomary ? " lb" : " kg")
    }

    /// A weekly change in the display unit, e.g. "0.5 kg a week".
    private func weeklyChange(_ kilograms: Decimal) -> String {
        Self.twoDecimals(converted(kilograms)) + (unitSystem() == .usCustomary ? " lb" : " kg") + " a week"
    }

    static func whole(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    static func oneDecimal(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func twoDecimals(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// The card itself. Shows a connect button until the read request has been shown once.
public struct BodyActivityCard: View {
    @ObservedObject var model: BodyActivityViewModel
    private let now: () -> Date

    public init(model: BodyActivityViewModel, now: @escaping () -> Date = { Date() }) {
        self.model = model
        self.now = now
    }

    public var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                HStack {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(TokenColors.accent)
                        .accessibilityHidden(true)
                    Text(BodyActivityViewModel.title)
                        .font(.headline)
                        .foregroundStyle(TokenColors.textPrimary)
                    Spacer(minLength: DesignSpacing.s)
                }
                content
            }
        }
        .accessibilityElement(children: .contain)
        .task { await model.load(now: now()) }
    }

    @ViewBuilder
    private var content: some View {
        if model.showsConnect {
            Text(BodyActivityViewModel.connectDetail)
                .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            Button(BodyActivityViewModel.connectTitle) {
                Task { await self.model.connect(now: self.now()) }
            }
            .disabled(model.isBusy)
        } else if model.readings.isEmpty {
            Text(BodyActivityViewModel.emptyDetail)
                .font(.footnote).foregroundStyle(TokenColors.textSecondary)
        } else {
            HStack(spacing: DesignSpacing.m) {
                if let steps = model.stepsText { Text(steps) }
                if let energy = model.activeEnergyText { Text(energy) }
            }
            if let weight = model.weightText {
                Text("Weight \(weight)")
            }
            if let trend = model.weightTrendText {
                Text(trend).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            if let plan = model.planPaceText {
                Text(plan).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            if let planDay = model.planGoalDayText {
                Text(planDay).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            if let trendDay = model.trendGoalDayText {
                Text(trendDay).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            if let outside = model.outsideText {
                Text(outside).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
        }
    }
}
