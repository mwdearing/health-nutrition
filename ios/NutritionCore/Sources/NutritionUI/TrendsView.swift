import SwiftUI

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

    private var state: InsightsLoadState {
        InsightsLoadState.resolve(
            errorMessage: journal.errorMessage, loadCount: journal.loadCount,
            entries: journal.sections.flatMap(\.rows).map {
                InsightsWeek.Entry(occurredAt: $0.occurredAt, timeZoneIdentifier: $0.timeZoneIdentifier)
            },
            now: now(), zone: zone())
    }

    public var body: some View {
        Group {
            switch state {
            case .ready(let week):
                InsightsView(week: week)
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
    }
}

/// The Trends tab: the two ways to look back, each a row that opens its screen in this tab's stack.
public struct TrendsView: View {
    private let today: TodayViewModel
    private let journal: JournalViewModel
    private let now: () -> Date

    public init(today: TodayViewModel, journal: JournalViewModel, now: @escaping () -> Date = { Date() }) {
        self.today = today
        self.journal = journal
        self.now = now
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                row(
                    title: "Nutrients", detail: "Vitamins and minerals against published reference values",
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
        .background(TokenColors.background)
        .navigationTitle("Trends")
    }

    private func row<Destination: View>(
        title: String, detail: String, systemImage: String, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Card {
                HStack(spacing: DesignSpacing.m) {
                    Image(systemName: systemImage)
                        .foregroundStyle(TokenColors.accent)
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
    }
}
