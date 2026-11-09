import SwiftUI

extension InsightsAverages {
    /// The Diary's days with what Health states for each, plus the days only Health knows (no Diary row, so no
    /// section), which carry no journal totals (#1268). Insights and the Trends cards both read it, so they count
    /// the same days.
    @MainActor
    static func days(from journal: JournalViewModel) -> [InsightsAverages.Day] {
        let outside = journal.outsideIntakeByDay
        var days = journal.sections.map {
            InsightsAverages.Day(
                key: $0.id, totals: $0.totals, isLogged: JournalViewModel.hasFoodEntries($0.rows),
                outside: outside[$0.id] ?? .notConnected)
        }
        let known = Set(journal.sections.map(\.id))
        for (key, read) in outside where !known.contains(key) {
            days.append(InsightsAverages.Day(key: key, totals: DailyTotals(totals: [:]), isLogged: false, outside: read))
        }
        return days
    }
}

/// Insights, loaded from the diary when it appears: the entries' times are read from the journal, so the
/// summary is the same days the Diary shows.
public struct InsightsHost: View {
    @ObservedObject var journal: JournalViewModel
    private let now: () -> Date
    private let zone: () -> TimeZone

    public init(
        journal: JournalViewModel, now: @escaping () -> Date = { Date() },
        zone: @escaping () -> TimeZone = { TimeZone.current }
    ) {
        self.journal = journal
        self.now = now
        self.zone = zone
    }

    private var averageDays: [InsightsAverages.Day] { InsightsAverages.days(from: journal) }

    private var state: InsightsLoadState {
        InsightsLoadState.resolve(
            errorMessage: journal.errorMessage, loadCount: journal.loadCount, skippedCount: journal.skippedCount,
            entries: journal.sections.flatMap(\.rows).map {
                InsightsWeek.Entry(
                    occurredAt: $0.occurredAt, timeZoneIdentifier: $0.timeZoneIdentifier,
                    countsAsLogged: JournalViewModel.hasFoodEntries([$0]))
            },
            days: averageDays,
            averageNutrients: Self.averagedNutrients, now: now(), zone: zone(),
            healthIntakeDayKeys: journal.healthIntakeDayKeys)
    }

    /// The energy and the three macros: the figures the Today ring and columns show.
    private static let averagedNutrients = ["energy", "protein", "carbohydrate", "fat"]

    public var body: some View {
        Group {
            switch state {
            case .ready(let week, let skipped, let averages):
                InsightsView(week: week, skippedCount: skipped, averages: averages)
            case .failed(let message):
                ScrollView {
                    InlineNotice(message, tone: .failed)
                        .padding(DesignSpacing.m)
                }
                .background(TokenColors.background)
                .navigationTitle("Insights")
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TokenColors.background)
                    .navigationTitle("Insights")
            }
        }
        .onAppear { journal.load(now: now()) }
        // Health knows days the Diary has no row for, so the week reads them too (#1267).
        .task { await journal.loadRecentHealthTotals(days: InsightsAverages.windowDays, now: now()) }
    }
}

/// The Trends tab: the two ways to look back, each a row that opens its screen in this tab's stack.
public struct TrendsView: View {
    /// The vitamins row's detail. It says what the row compares, without repeating the title (#537).
    static let vitaminsDetail = "Compared with published reference values"

    @ObservedObject private var today: TodayViewModel
    @ObservedObject private var journal: JournalViewModel
    private let now: () -> Date
    private let zone: () -> TimeZone
    @State private var range: TrendsRange = .week
    /// The most days of Health read so far; it grows with a wider range and never shrinks on a switch back.
    @State private var healthDays = TrendsRange.week.healthReadDays

    public init(
        today: TodayViewModel, journal: JournalViewModel, now: @escaping () -> Date = { Date() },
        zone: @escaping () -> TimeZone = { TimeZone.current }
    ) {
        self.today = today
        self.journal = journal
        self.now = now
        self.zone = zone
    }

    private var summary: TrendsSummary {
        TrendsSummary.make(
            days: InsightsAverages.days(from: journal), goal: today.calorieRemaining.goal, now: now(), zone: zone(),
            range: range)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                Picker("Range", selection: $range) {
                    ForEach(TrendsRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TrendsCaloriesCard(summary: summary)
                TrendsMacrosCard(summary: summary)
                row(
                    title: "Vitamins and minerals", detail: Self.vitaminsDetail,
                    systemImage: "leaf"
                ) {
                    NutrientGapsView(makeModel: { today.makeNutrientGaps() }, now: now)
                }
                row(
                    title: "Insights", detail: "How consistently the last seven days were logged",
                    systemImage: "chart.bar"
                ) {
                    InsightsHost(journal: journal, now: now)
                }
            }
            .padding(.horizontal, DesignSpacing.m)
            .padding(.vertical, DesignSpacing.s)
        }
        .background(TokenColors.page)
        .navigationTitle("Trends")
        .onAppear { journal.load(now: now()) }
        // Health knows days the Diary has none for, so the chosen range reads them, and reads again when it changes.
        .onChange(of: range) { _, new in healthDays = max(healthDays, new.healthReadDays) }
        .task(id: healthDays) { await journal.loadRecentHealthTotals(days: healthDays, now: now()) }
    }

    private func row<Destination: View>(
        title: String, detail: String, systemImage: String, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            ContentCard {
                HStack(spacing: DesignSpacing.m) {
                    IconWell(systemName: systemImage)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                        Text(title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                        Text(detail).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    }
                    Spacer(minLength: DesignSpacing.s)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}
