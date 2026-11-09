import Charts
import Foundation
import NutritionDomain
import SwiftUI

/// How far back the Trends cards look.
public enum TrendsRange: CaseIterable, Identifiable {
    case week
    case month
    case sixMonths

    public var id: Self { self }

    /// The picker's segment.
    public var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .sixMonths: return "6 months"
        }
    }

    /// What the cards say they cover.
    public var cardTitle: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .sixMonths: return "Last 6 months"
        }
    }

    /// The local days ending today that the range covers.
    public var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .sixMonths: return 182
        }
    }

    /// What the cards say when the range holds nothing.
    var emptyText: String {
        switch self {
        case .week: return TrendsSummary.emptyText
        case .month: return "Nothing logged this month"
        case .sixMonths: return "Nothing logged in 6 months"
        }
    }

    /// Days in one bar: a day, or a week of days for 6 months.
    var daysPerBar: Int { self == .sixMonths ? 7 : 1 }

    /// A label under every n-th bar, counting back from the newest, for the ranges too wide to label each bar.
    var axisStep: Int {
        switch self {
        case .week: return 1
        case .month: return 7
        case .sixMonths: return 6
        }
    }
}

/// The figures behind the two Trends cards: the chosen range's local days ending today (a week by default), averaged over exactly the
/// days Insights counts for its averages (a day with a food or drink entry, or with intake Health states): the same
/// days for the same window. Insights averages 30 days, the cards the chosen range, so their figures can differ.
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
        /// True when a counted day in the bar states only part of the energy.
        public let isPartial: Bool
        /// What the bar says aloud: the day (or "Week of" the first day) and its calories.
        public let spoken: String
        /// Whether the axis labels this bar; a month or 6 months labels about one bar in several.
        public let showsAxisLabel: Bool
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

    public let range: TrendsRange
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

    public var emptyMessage: String { range.emptyText }

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
        days: [InsightsAverages.Day], goal: Decimal?, now: Date, zone: TimeZone, locale: Locale = .current,
        range: TrendsRange = .week
    ) -> TrendsSummary {
        let inWindow = InsightsAverages.daysInWindow(days, now: now, zone: zone, length: range.days)
        func average(_ nutrient: String, grams: Bool = false) -> (value: Decimal, partial: Bool)? {
            figure(nutrient, in: inWindow, unit: grams ? .g : .kcal)
        }
        let bars = makeBars(inWindow, range: range, now: now, zone: zone, locale: locale)
        let usableGoal = goal.flatMap { $0 > 0 ? $0 : nil }
        let energy = average("energy")
        let protein = average("protein", grams: true)
        let carbs = average("carbohydrate", grams: true)
        let fat = average("fat", grams: true)
        return TrendsSummary(
            range: range, bars: bars, averageKcal: energy?.value, proteinGrams: protein?.value,
            carbGrams: carbs?.value, fatGrams: fat?.value, goal: usableGoal,
            energyIsPartial: energy?.partial ?? false, proteinIsPartial: protein?.partial ?? false,
            carbsArePartial: carbs?.partial ?? false, fatIsPartial: fat?.partial ?? false)
    }

    /// One bar per day (a week, a month) or per seven days (6 months), oldest first, the last holding today.
    /// A bar is the average of its counted days, so a week with two logged days is not diluted by five empty ones.
    private static func makeBars(
        _ inWindow: [InsightsAverages.Day], range: TrendsRange, now: Date, zone: TimeZone, locale: Locale
    ) -> [Bar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let keyFormatter = DateFormatter()
        keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.timeZone = zone
        keyFormatter.dateFormat = "yyyy-MM-dd"
        let labelFormatter = DateFormatter()
        labelFormatter.locale = locale
        labelFormatter.timeZone = zone
        labelFormatter.setLocalizedDateFormatFromTemplate(range == .week ? "EEE" : "MMMd")
        let size = range.daysPerBar
        let count = range.days / size
        return (0..<count).map { index in
            let fromNewest = count - 1 - index
            let ages = (0..<size).map { fromNewest * size + $0 }
            let keys = Set(
                ages.compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.map(keyFormatter.string))
            let first = calendar.date(byAdding: .day, value: -(fromNewest * size + size - 1), to: today) ?? today
            let label = labelFormatter.string(from: first)
            let found = figure("energy", in: inWindow.filter { keys.contains($0.key) }, unit: .kcal)
            let name = range == .sixMonths ? "Week of \(label)" : label
            let amount = found.map {
                "\($0.partial ? "at least " : "")\(figureText($0.value)) calories"
            } ?? "nothing logged"
            return Bar(
                id: index, label: label, kcal: found?.value, isToday: fromNewest == 0,
                isPartial: found?.partial ?? false, spoken: "\(name), \(amount)",
                showsAxisLabel: fromNewest % range.axisStep == 0)
        }
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
                Text(summary.range.cardTitle)
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
                    Text(summary.emptyMessage)
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
            AxisMarks(values: summary.bars.filter(\.showsAxisLabel).map { String($0.id) }) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let index = Int(key), summary.bars.indices.contains(index) {
                        let bar = summary.bars[index]
                        Text(summary.range == .week ? String(bar.label.prefix(1)) : bar.label)
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
        guard let average = summary.averageKcal else { return "Calories, daily average. \(summary.emptyMessage)" }
        var parts = ["Calories, daily average, \(summary.range.cardTitle.lowercased()), \(summary.energyIsPartial ? "at least " : "")\(TrendsSummary.figureText(average)) calories"]
        if let difference = summary.difference { parts.append(difference.text) }
        let days = summary.bars.map(\.spoken)
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
                Text(summary.range.cardTitle)
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
                    Text(summary.emptyMessage)
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
        guard summary.macroShares != nil else { return "Macros, daily average. \(summary.emptyMessage)" }
        return "Macros, daily average, \(summary.range.cardTitle.lowercased()). Protein, \(TrendsSummary.gramsText(summary.proteinGrams, partial: summary.proteinIsPartial)). "
            + "Carbs, \(TrendsSummary.gramsText(summary.carbGrams, partial: summary.carbsArePartial)). "
            + "Fat, \(TrendsSummary.gramsText(summary.fatGrams, partial: summary.fatIsPartial))."
    }
}
