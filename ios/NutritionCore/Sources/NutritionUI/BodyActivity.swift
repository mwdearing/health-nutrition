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

    public init(
        steps: Decimal? = nil, activeEnergyKcal: Decimal? = nil, latestWeightKg: Decimal? = nil,
        latestWeightDate: Date? = nil, earlierWeightKg: Decimal? = nil
    ) {
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.latestWeightKg = latestWeightKg
        self.latestWeightDate = latestWeightDate
        self.earlierWeightKg = earlierWeightKg
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
            return
        }
        readings = await reader.read(now: now)
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
        readings.activeEnergyKcal.map { "\(Self.whole($0)) kcal active" }
    }

    public var weightText: String? {
        readings.latestWeightKg.map { weight($0) }
    }

    /// "Down 2.1 lb over 30 days", "Up …", or "No change over 30 days"; nil without an earlier weight.
    public var weightTrendText: String? {
        guard let latest = readings.latestWeightKg, let earlier = readings.earlierWeightKg else { return nil }
        let change = latest - earlier
        let shown = weight(abs(change))
        if Self.oneDecimal(converted(abs(change))) == "0" { return "No change over 30 days" }
        return (change < 0 ? "Down " : "Up ") + shown + " over 30 days"
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
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                Text(BodyActivityViewModel.title).font(.headline)
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
        }
    }
}
