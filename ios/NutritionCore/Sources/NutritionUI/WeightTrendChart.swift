import Charts
import Foundation
import NutritionDomain
import SwiftUI

/// The weight chart under the trend line: one line point for each day with a weigh-in in the window, and a
/// vertical rule on each day with a logged dose. Plain values only; the chart draws no goal or target line.
public struct WeightTrendChart: View {
    private let points: [WeightChartPoint]
    private let markers: [DoseDayMarker]

    /// Creates the chart from the window's daily averages and the dose-day markers.
    public init(points: [WeightChartPoint], markers: [DoseDayMarker]) {
        self.points = points
        self.markers = markers
    }

    public var body: some View {
        Chart {
            ForEach(points, id: \.day) { point in
                LineMark(
                    x: .value("Day", Self.date(point.day)),
                    y: .value("Weight", NSDecimalNumber(decimal: point.weight).doubleValue)
                )
                .foregroundStyle(TokenColors.accent)
                PointMark(
                    x: .value("Day", Self.date(point.day)),
                    y: .value("Weight", NSDecimalNumber(decimal: point.weight).doubleValue)
                )
                .foregroundStyle(TokenColors.accent)
            }
            ForEach(markers, id: \.day) { marker in
                RuleMark(x: .value("Dose day", Self.date(marker.day)))
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel(Text(BodyActivityViewModel.doseMarkerLabel(marker)))
            }
        }
        .frame(height: 120)
        .accessibilityLabel(BodyActivityViewModel.weightChartLabel)
    }

    /// The day as noon UTC, so every day maps to one fixed position on the axis whatever the device time zone.
    private static func date(_ day: CalendarDay) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
