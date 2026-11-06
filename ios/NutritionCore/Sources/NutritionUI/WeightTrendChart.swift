import Charts
import Foundation
import NutritionDomain
import SwiftUI

/// The weight chart under the trend line: one line point for each day with a weigh-in in the window, and a
/// vertical rule on each day with a logged dose. Plain values only; the chart draws no goal or target line.
public struct WeightTrendChart: View {
    private let points: [WeightChartPoint]
    private let markers: [DoseDayMarker]
    @ScaledMetric(relativeTo: .body) private var scaledChartHeight: CGFloat = 120

    private var chartHeight: CGFloat { min(scaledChartHeight, 120 * 1.6) }

    /// Creates the chart from the window's daily averages and the dose-day markers.
    public init(points: [WeightChartPoint], markers: [DoseDayMarker]) {
        self.points = points
        self.markers = markers
    }

    public var body: some View {
        Chart {
            ForEach(points, id: \.day) { point in
                LineMark(
                    x: .value("Day", Self.position(of: point.day)),
                    y: .value("Weight", NSDecimalNumber(decimal: point.weight).doubleValue)
                )
                .foregroundStyle(TokenColors.accent)
                PointMark(
                    x: .value("Day", Self.position(of: point.day)),
                    y: .value("Weight", NSDecimalNumber(decimal: point.weight).doubleValue)
                )
                .foregroundStyle(TokenColors.accent)
            }
            ForEach(markers, id: \.day) { marker in
                RuleMark(x: .value("Dose day", Self.position(of: marker.day)))
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel(Text(BodyActivityViewModel.doseMarkerLabel(marker)))
            }
        }
        .environment(\.calendar, Self.axisCalendar)
        .environment(\.timeZone, Self.axisCalendar.timeZone)
        .frame(height: chartHeight)
        .accessibilityLabel(BodyActivityViewModel.weightChartLabel)
    }

    /// The calendar the axis places and labels days in. Gregorian UTC whatever the device, so the label under a
    /// point names the day it was weighed even where noon UTC already falls on the next local day.
    static let axisCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// The day as noon in the axis calendar, so every day maps to one fixed position on the axis.
    static func position(of day: CalendarDay) -> Date {
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
        return axisCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
