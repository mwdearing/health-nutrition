import SwiftUI

/// Insights: a calm look at how consistently the week was logged, from the diary alone.
///
/// It reports counts of entries and days, says plainly that missing logs affect it, and makes no
/// medical claim.
public struct InsightsView: View {
    private let week: InsightsWeek

    public init(week: InsightsWeek) {
        self.week = week
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                Card {
                    VStack(alignment: .leading, spacing: DesignSpacing.m) {
                        Text(week.hasAnyEntry ? week.headline : "Nothing logged this week")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(TokenColors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Based on your diary entries")
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                        HStack(alignment: .bottom, spacing: DesignSpacing.s) {
                            ForEach(week.days) { day in
                                VStack(spacing: DesignSpacing.xs) {
                                    ZStack(alignment: .bottom) {
                                        Capsule().fill(TokenColors.track).frame(height: 96)
                                        if day.entryCount > 0 {
                                            Capsule()
                                                .fill(TokenColors.mint)
                                                .frame(height: max(8, 96 * week.barFraction(for: day)))
                                        }
                                    }
                                    Text(day.label)
                                        .font(.caption2)
                                        .foregroundStyle(TokenColors.textSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(
                                    "\(day.label), \(day.entryCount == 1 ? "1 entry" : "\(day.entryCount) entries")")
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: DesignSpacing.s) {
                        Text("What this is based on")
                            .font(.headline)
                            .foregroundStyle(TokenColors.textPrimary)
                        Text("7 days").foregroundStyle(TokenColors.textPrimary)
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
        .background(TokenColors.background)
        .navigationTitle("Insights")
    }
}
