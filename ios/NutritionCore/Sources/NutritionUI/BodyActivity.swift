import Combine
import Foundation
import SwiftUI

/// What Apple Health reports for today's activity and recent weight. Every value is optional: Health
/// never says whether read access was granted, so "no data" and "not allowed" look the same.
public struct BodyActivityReadings: Equatable, Sendable {
    public var steps: Decimal?
    public var activeEnergyKcal: Decimal?
    public var latestWeightKg: Decimal?
    public var latestWeightDate: Date?
    /// The newest weight at least 30 days older than `latestWeightDate`, for the trend line.
    public var earlierWeightKg: Decimal?
    public var earlierWeightDate: Date?
    /// Today's nutrient totals from entries other apps wrote to Health, per canonical nutrient key, in
    /// each key's unit. Entries this app wrote are left out, so nothing is counted twice.
    public var outsideNutrients: [String: Decimal]
    /// True when reading other apps' entries failed, so the card says so instead of showing nothing.
    public var outsideReadFailed: Bool

    public init(
        steps: Decimal? = nil, activeEnergyKcal: Decimal? = nil, latestWeightKg: Decimal? = nil,
        latestWeightDate: Date? = nil, earlierWeightKg: Decimal? = nil, earlierWeightDate: Date? = nil,
        outsideNutrients: [String: Decimal] = [:], outsideReadFailed: Bool = false
    ) {
        self.outsideNutrients = outsideNutrients
        self.outsideReadFailed = outsideReadFailed
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.latestWeightKg = latestWeightKg
        self.latestWeightDate = latestWeightDate
        self.earlierWeightKg = earlierWeightKg
        self.earlierWeightDate = earlierWeightDate
    }

    public static let empty = BodyActivityReadings()
    public var isEmpty: Bool { self == .empty }
}

/// The app target's HealthKit reader. This package never imports HealthKit.
@MainActor
public protocol BodyActivityReading: AnyObject {
    /// Whether the person has been shown the read request on this device.
    var hasAskedForReadAccess: Bool { get }
    /// Asks Health for read access to steps, active energy and weight.
    func requestReadAccess() async
    /// Today's steps and active energy, and the latest weight with an earlier one for the trend.
    func read(now: Date) async -> BodyActivityReadings
}

/// The activity and weight card on Today.
@MainActor
public final class BodyActivityViewModel: ObservableObject {
    @Published public private(set) var readings: BodyActivityReadings = .empty
    @Published public private(set) var isBusy = false
    @Published public private(set) var hasAsked: Bool
    private let reader: any BodyActivityReading
    private let unitSystem: () -> UnitSystem
    /// Called with every fresh read, so Today can count active energy toward the calorie goal.
    public var onRead: ((BodyActivityReadings) -> Void)?

    /// Pounds per kilogram, exact to the definition of the pound.
    static let poundsPerKilogram = Decimal(string: "2.20462262185")!

    public init(reader: any BodyActivityReading, unitSystem: @escaping () -> UnitSystem) {
        self.reader = reader
        self.unitSystem = unitSystem
        self.hasAsked = reader.hasAskedForReadAccess
    }

    public func load(now: Date) async {
        hasAsked = reader.hasAskedForReadAccess
        guard hasAsked else {
            readings = .empty
            onRead?(readings)
            return
        }
        readings = await reader.read(now: now)
        onRead?(readings)
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
        "Reads today's steps, active energy and your weight from the Health app on this phone. "
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
        if readings.outsideReadFailed { return "From other apps: could not be read" }
        var parts: [String] = []
        if let energy = readings.outsideNutrients["energy"] { parts.append("\(Self.whole(energy)) Calories") }
        if let protein = readings.outsideNutrients["protein"] { parts.append("\(Self.whole(protein)) g protein") }
        if let water = readings.outsideNutrients["water"] {
            if unitSystem() == .usCustomary {
                parts.append("\(Self.whole(water / Self.millilitersPerFluidOunce)) fl oz water")
            } else {
                parts.append("\(Self.whole(water)) mL water")
            }
        }
        guard !parts.isEmpty else { return nil }
        return "From other apps: " + parts.joined(separator: ", ")
    }

    /// Milliliters per US fluid ounce, exact to the definition.
    static let millilitersPerFluidOunce = Decimal(string: "29.5735295625")!

    /// "Down 2.1 lb over 34 days", "Up …", or "No change over 34 days", naming the actual interval
    /// between the two samples; nil without both weights and dates.
    public var weightTrendText: String? {
        guard let latest = readings.latestWeightKg, let earlier = readings.earlierWeightKg,
              let latestDate = readings.latestWeightDate, let earlierDate = readings.earlierWeightDate
        else { return nil }
        let days = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: earlierDate),
            to: Calendar.current.startOfDay(for: latestDate)).day ?? 0
        let interval = " over \(days) days"
        let change = latest - earlier
        if Self.roundedToTenth(converted(abs(change))) == 0 { return "No change" + interval }
        return (change < 0 ? "Down " : "Up ") + weight(abs(change)) + interval
    }

    /// Rounded to one decimal place, compared as a number so the test does not depend on the locale's
    /// digits.
    static func roundedToTenth(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 1, .plain)
        return result
    }

    private func converted(_ kilograms: Decimal) -> Decimal {
        unitSystem() == .usCustomary ? kilograms * Self.poundsPerKilogram : kilograms
    }

    private func weight(_ kilograms: Decimal) -> String {
        Self.oneDecimal(converted(kilograms)) + (unitSystem() == .usCustomary ? " lb" : " kg")
    }

    static func whole(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    static func oneDecimal(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
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
                HStack {
                    Text("Weight \(weight)")
                    if let trend = model.weightTrendText {
                        Text(trend).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    }
                }
            }
            if let outside = model.outsideText {
                Text(outside).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
        }
    }
}
