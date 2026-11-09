import Charts
import Foundation
import NutritionDomain
import SwiftUI

/// The figures behind the two Trends cards: the last seven local days ending today, averaged over exactly the
/// days Insights counts for its averages (a day with a food or drink entry, or with intake Health states): the same
/// days for the same window. Insights averages 30 days, the cards 7, so their figures can differ.
public struct TrendsSummary: Equatable {
    public static let windowDays = InsightsWeek.length
    public static let emptyText = "Nothing logged this week"

    public struct Bar: Equatable, Identifiable {
        public let id: Int
        /// "Mon", "Tue" in the locale.
        public let label: String
        /// The day's energy, or nil when nothing is known for the day.
        public let kcal: Decimal?
        public let isToday: Bool
        /// True when the day's energy is only partly known, so it is spoken as a minimum.
        public let isPartial: Bool

        /// What VoiceOver says for the day.
        public var spokenText: String {
            guard let kcal else { return "\(label), nothing logged" }
            return "\(label), \(isPartial ? "at least " : "")\(TrendsSummary.figureText(kcal)) calories"
        }
    }

    /// How the average compares with the daily goal. The figure is always positive; the words carry the direction.
    public enum GoalDifference: Equatable {
        case under(Int)
        case over(Int)
        case onGoal

        public var text: String {
            switch self {
            case .under(let amount): return "\(amount.formatted()) under goal"
            case .over(let amount): return "\(amount.formatted()) over goal"
            case .onGoal: return "On goal"
            }
        }
    }

    public struct MacroShares: Equatable {
        public let protein: Double
        public let carbs: Double
        public let fat: Double
    }

    public let bars: [Bar]
    public let averageKcal: Decimal?
    public let proteinGrams: Decimal?
    public let carbGrams: Decimal?
    public let fatGrams: Decimal?
    /// The daily energy goal; nil when there is none (a goal of zero is no goal).
    public let goal: Decimal?
    /// True when a counted day states only part of the figure, so Insights says "at least" and so do the cards.
    public let energyIsPartial: Bool
    public let proteinIsPartial: Bool
    public let carbsArePartial: Bool
    public let fatIsPartial: Bool

    public var hasData: Bool { averageKcal != nil }

    /// Positive figure under or over the goal, nil without a goal or without an average.
    public var difference: GoalDifference? {
        guard let goal, let averageKcal else { return nil }
        let average = Self.whole(averageKcal)
        let target = Self.whole(goal)
        if average == target { return .onGoal }
        return average < target ? .under(target - average) : .over(average - target)
    }

    /// Each macro's share of the calories the three macros make (4, 4 and 9 kcal per gram). Nil when no macro grams
    /// are known.
    public var macroShares: MacroShares? {
        let protein = Self.energy(proteinGrams, perGram: 4)
        let carbs = Self.energy(carbGrams, perGram: 4)
        let fat = Self.energy(fatGrams, perGram: 9)
        let total = protein + carbs + fat
        guard total > 0 else { return nil }
        return MacroShares(protein: protein / total, carbs: carbs / total, fat: fat / total)
    }

    public static func make(
        days: [InsightsAverages.Day], goal: Decimal?, now: Date, zone: TimeZone, locale: Locale = .current
    ) -> TrendsSummary {
        let inWindow = InsightsAverages.daysInWindow(days, now: now, zone: zone, length: windowDays)
        func average(_ nutrient: String, grams: Bool = false) -> (value: Decimal, partial: Bool)? {
            figure(nutrient, in: inWindow, unit: grams ? .g : .kcal)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let week = InsightsWeek.make(entries: [], now: now, zone: zone, locale: locale)
        let bars = week.days.enumerated().map { index, day -> Bar in
            let key = formatter.string(from: day.id)
            let own = inWindow.filter { $0.key == key }
            let dayFigure = figure("energy", in: own, unit: .kcal)
            return Bar(
                id: index, label: day.label, kcal: dayFigure?.value,
                isToday: index == week.days.count - 1, isPartial: dayFigure?.partial ?? false)
        }
        let usableGoal = goal.flatMap { $0 > 0 ? $0 : nil }
        let energy = average("energy")
        let protein = average("protein", grams: true)
        let carbs = average("carbohydrate", grams: true)
        let fat = average("fat", grams: true)
        return TrendsSummary(
            bars: bars, averageKcal: energy?.value, proteinGrams: protein?.value, carbGrams: carbs?.value,
            fatGrams: fat?.value, goal: usableGoal, energyIsPartial: energy?.partial ?? false,
            proteinIsPartial: protein?.partial ?? false, carbsArePartial: carbs?.partial ?? false,
            fatIsPartial: fat?.partial ?? false)
    }

    private static func figure(_ nutrient: String, in days: [InsightsAverages.Day], unit: MeasureUnit)
        -> (value: Decimal, partial: Bool)?
    {
        guard !days.isEmpty, let found = InsightsAverages.averageFigure(for: nutrient, in: days),
            let converted = try? Quantity(value: found.average, unit: found.unit).converted(to: unit).value
        else { return nil }
        return (converted, found.partialDays > 0)
    }

    private static func whole(_ value: Decimal) -> Int {
        NSDecimalNumber(decimal: DisplayRounding.rounded(value, fractionDigits: 0)).intValue
    }

    private static func energy(_ grams: Decimal?, perGram: Double) -> Double {
        guard let grams else { return 0 }
        return max(0, NSDecimalNumber(decimal: grams).doubleValue) * perGram
    }

    /// "1,820" for a calorie figure.
    static func figureText(_ value: Decimal) -> String { whole(value).formatted() }

    /// "42 g" for a gram figure.
    static func gramsText(_ value: Decimal?, partial: Bool = false) -> String {
        guard let value else { return "–" }
        return "\(partial ? "at least " : "")\(whole(value).formatted()) g"
    }
}

/// The calories card: the daily average on the hero, how it compares with the goal, and a bar per day.
public struct TrendsCaloriesCard: View {
    private let summary: TrendsSummary
    @ScaledMetric(relativeTo: .body) private var scaledChartHeight: CGFloat = 110

    private var chartHeight: CGFloat { min(scaledChartHeight, 110 * 1.6) }

    public init(summary: TrendsSummary) {
        self.summary = summary
    }

    public var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                Text("Calories, daily average")
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.heroSecondaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundStyle(TokenColors.heroSecondaryText)
                if let average = summary.averageKcal {
                    if summary.energyIsPartial {
                        Text("At least")
                            .font(.subheadline)
                            .foregroundStyle(TokenColors.heroSecondaryText)
                    }
                    Text(TrendsSummary.figureText(average))
                        .font(.largeTitle.bold())
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .foregroundStyle(TokenColors.heroText)
                    if let difference = summary.difference {
                        Text(difference.text)
                            .font(.subheadline)
                            .foregroundStyle(TokenColors.heroSecondaryText)
                    }
                    chart
                } else {
                    Text(TrendsSummary.emptyText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TokenColors.heroText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var chart: some View {
        let keys = summary.bars.map { String($0.id) }
        let tallest = summary.bars.compactMap(\.kcal).max() ?? 0
        let top = max(tallest, summary.goal ?? 0)
        return Chart {
            ForEach(summary.bars) { bar in
                if let kcal = bar.kcal {
                    BarMark(
                        x: .value("Day", String(bar.id)),
                        y: .value("Calories", NSDecimalNumber(decimal: kcal).doubleValue)
                    )
                    .foregroundStyle(bar.isToday ? TokenColors.heroTrack : TokenColors.mint)
                }
            }
            if let goal = summary.goal {
                RuleMark(y: .value("Goal", NSDecimalNumber(decimal: goal).doubleValue))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(TokenColors.heroSecondaryText)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Goal \(TrendsSummary.figureText(goal))")
                            .font(.caption2)
                            .foregroundStyle(TokenColors.heroSecondaryText)
                    }
            }
        }
        .chartXScale(domain: keys)
        .chartYScale(domain: 0...(NSDecimalNumber(decimal: top).doubleValue * 1.25 + 1))
        .chartXAxis {
            AxisMarks(values: keys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let index = Int(key), summary.bars.indices.contains(index) {
                        let bar = summary.bars[index]
                        Text(String(bar.label.prefix(1)))
                            .font(.caption2)
                            .fontWeight(bar.isToday ? .bold : .regular)
                            .foregroundStyle(TokenColors.heroSecondaryText)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: chartHeight)
        .accessibilityHidden(true)
    }

    private var spokenLabel: String {
        guard let average = summary.averageKcal else { return "Calories, daily average. \(TrendsSummary.emptyText)" }
        var parts = ["Calories, daily average, last 7 days, \(summary.energyIsPartial ? "at least " : "")\(TrendsSummary.figureText(average)) calories"]
        if let difference = summary.difference { parts.append(difference.text) }
        let days = summary.bars.map(\.spokenText)
        parts.append(days.joined(separator: ", "))
        return parts.joined(separator: ". ")
    }
}

/// The macros card: one capsule split by each macro's share of the averaged calories, and a legend with grams.
public struct TrendsMacrosCard: View {
    private let summary: TrendsSummary

    public init(summary: TrendsSummary) {
        self.summary = summary
    }

    public var body: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                Text("Macros, daily average")
                    .font(.headline)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundStyle(TokenColors.textSecondary)
                if let shares = summary.macroShares {
                    splitBar(shares)
                    HStack(alignment: .top, spacing: DesignSpacing.m) {
                        legend("Protein", grams: summary.proteinGrams, partial: summary.proteinIsPartial, color: TokenColors.macroProtein)
                        legend("Carbs", grams: summary.carbGrams, partial: summary.carbsArePartial, color: TokenColors.macroCarbs)
                        legend("Fat", grams: summary.fatGrams, partial: summary.fatIsPartial, color: TokenColors.macroFat)
                    }
                } else {
                    Text(TrendsSummary.emptyText)
                        .font(.subheadline)
                        .foregroundStyle(TokenColors.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private func splitBar(_ shares: TrendsSummary.MacroShares) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                segment(TokenColors.macroProtein, share: shares.protein, width: proxy.size.width)
                segment(TokenColors.macroCarbs, share: shares.carbs, width: proxy.size.width)
                segment(TokenColors.macroFat, share: shares.fat, width: proxy.size.width)
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func segment(_ color: Color, share: Double, width: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: max(0, (width - 4) * share))
    }

    private func legend(_ name: String, grams: Decimal?, partial: Bool, color: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            HStack(spacing: DesignSpacing.xs) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(name).font(.caption).foregroundStyle(TokenColors.textSecondary)
            }
            Text(TrendsSummary.gramsText(grams, partial: partial))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(TokenColors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spokenLabel: String {
        guard summary.macroShares != nil else { return "Macros, daily average. \(TrendsSummary.emptyText)" }
        return "Macros, daily average, last 7 days. Protein, \(TrendsSummary.gramsText(summary.proteinGrams, partial: summary.proteinIsPartial)). "
            + "Carbs, \(TrendsSummary.gramsText(summary.carbGrams, partial: summary.carbsArePartial)). "
            + "Fat, \(TrendsSummary.gramsText(summary.fatGrams, partial: summary.fatIsPartial))."
    }
}
