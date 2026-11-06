import Charts
import SwiftUI

/// Insights: a calm look at how consistently the week was logged, from the diary alone.
///
/// It reports counts of entries and days, says plainly that missing logs affect it, and makes no
/// medical claim.
public struct InsightsView: View {
    private let week: InsightsWeek
    private let skippedCount: Int
    private let averages: InsightsAverages
    @ScaledMetric(relativeTo: .body) private var scaledChartHeight: CGFloat = 120

    private var chartHeight: CGFloat { min(scaledChartHeight, 120 * 1.6) }

    public init(
        week: InsightsWeek, skippedCount: Int = 0, averages: InsightsAverages = InsightsAverages(lines: [])
    ) {
        self.week = week
        self.skippedCount = skippedCount
        self.averages = averages
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                if skippedCount > 0 {
                    InlineNotice(
                        "\(skippedCount) \(skippedCount == 1 ? "entry" : "entries") can't be shown and \(skippedCount == 1 ? "is" : "are") not counted here.",
                        tone: .waiting)
                }
                ContentCard {
                    VStack(alignment: .leading, spacing: DesignSpacing.m) {
                        Text(week.hasAnyEntry ? week.headline : "Nothing logged this week")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(TokenColors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Based on your diary entries")
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                        weekChart
                    }
                }
                if !averages.lines.isEmpty {
                    ContentCard {
                        VStack(alignment: .leading, spacing: DesignSpacing.s) {
                            Text("Last 30 days")
                                .font(.headline)
                                .foregroundStyle(TokenColors.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(averages.lines) { line in
                                Text(line.text).foregroundStyle(TokenColors.textPrimary)
                            }
                        }
                    }
                }
                ContentCard {
                    VStack(alignment: .leading, spacing: DesignSpacing.s) {
                        Text("What this is based on")
                            .font(.headline)
                            .foregroundStyle(TokenColors.textPrimary)
                        Text("Last 7 days").foregroundStyle(TokenColors.textPrimary)
                        Text(week.entriesText).foregroundStyle(TokenColors.textPrimary)
                        Text(week.emptyDaysText).foregroundStyle(TokenColors.textPrimary)
                        Text("Missing logs may affect this summary.")
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                    }
                }
                Text("For reflection, not medical advice")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, DesignSpacing.m)
            .padding(.vertical, DesignSpacing.s)
        }
        .background(TokenColors.page)
        .navigationTitle("Insights")
    }

    private static func entriesText(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    /// The seven days as bars. Each bar keeps its spoken label; the chart as a whole reads as one summary.
    private var weekChart: some View {
        Chart(week.days) { day in
            BarMark(
                x: .value("Day", day.id, unit: .day),
                y: .value("Entries", day.entryCount)
            )
            .foregroundStyle(TokenColors.mint)
            .accessibilityLabel("\(day.label), \(Self.entriesText(day.entryCount))")
        }
        .chartXAxis {
            AxisMarks(values: week.days.map(\.id)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self), let day = week.days.first(where: { WeightTrendChart.axisCalendar.isDate($0.id, inSameDayAs: date) }) {
                        Text(day.label).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .environment(\.calendar, WeightTrendChart.axisCalendar)
        .environment(\.timeZone, WeightTrendChart.axisCalendar.timeZone)
        .frame(height: chartHeight)
        .accessibilityLabel(week.days.map { "\($0.label), \(Self.entriesText($0.entryCount))" }.joined(separator: ". "))
    }
}
