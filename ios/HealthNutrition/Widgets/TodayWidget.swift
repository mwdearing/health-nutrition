import SwiftUI
import WidgetKit

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(current(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // The app asks for a reload whenever Today changes; this covers the day rolling over with the app closed:
        // refresh shortly after local midnight at the latest, when `current()` stops showing yesterday's summary.
        let now = Date()
        let next = min(now.addingTimeInterval(30 * 60), WidgetSnapshot.refreshAfterMidnight(from: now))
        // The timeline itself carries the flip: an entry at the next midnight shows dashes (no summary can be from
        // that day yet) even if the system is late to ask for a reload.
        let midnight = TodayEntry(date: WidgetSnapshot.nextMidnight(from: now), snapshot: nil)
        completion(Timeline(entries: [current(at: now), midnight], policy: .after(next)))
    }

    /// Today's summary, or nil when none was written today: the widget then shows dashes rather than the
    /// previous day's figures under "Today".
    private func current(at now: Date) -> TodayEntry {
        let snapshot = WidgetSnapshotStore.appGroup()?.read().flatMap { $0.isCurrent(on: now) ? $0 : nil }
        return TodayEntry(date: now, snapshot: snapshot)
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    /// No summary could be read (not written yet, or the device has not been unlocked since a restart): the
    /// widget then states nothing about the day rather than claiming nothing was logged.
    private var isEmpty: Bool { snapshot?.hasEntries == false }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: snapshot?.energyFraction ?? 0) {
                Image(systemName: "fork.knife")
            } currentValueLabel: {
                Text(snapshot?.gaugeHeadline ?? "—")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel(snapshot?.calorieSpoken ?? "Calories unknown")
            .privacySensitive()
        case .accessoryRectangular:
            if isEmpty {
                Text("Nothing logged today")
            } else {
                WidgetCalorieSummary(snapshot: snapshot)
            }
        case .accessoryInline:
            if isEmpty {
                Text("Nothing logged today")
            } else if let remaining = snapshot?.remainingInlineText {
                Text("Calories remaining \(remaining)")
                    .accessibilityLabel(snapshot?.calorieSpoken ?? "Calories unknown")
                    .privacySensitive()
            } else {
                Text("\(snapshot?.foodText ?? "—") Food")
                    .accessibilityLabel(snapshot?.calorieSpoken ?? "Calories unknown")
                    .privacySensitive()
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                summary
                if !isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Protein \(WidgetFigure.figure(snapshot?.proteinGrams, unit: "g", partial: snapshot?.isPartial("protein") == true))")
                        Text("Carbohydrate \(WidgetFigure.figure(snapshot?.carbohydrateGrams, unit: "g", partial: snapshot?.isPartial("carbohydrate") == true))")
                        Text("Fat \(WidgetFigure.figure(snapshot?.fatGrams, unit: "g", partial: snapshot?.isPartial("fat") == true))")
                        Text("Water \(WidgetFigure.water(snapshot?.waterMilliliters, usUnits: snapshot?.usUnits))")
                        if snapshot?.partialFigures?.isEmpty == false {
                            Text("+ Some entries are missing nutrients").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                    .privacySensitive()
                }
            }
        default:
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEmpty {
                Text("Today").font(.headline)
                Text("Nothing logged today").font(.footnote)
            } else {
                WidgetCalorieSummary(snapshot: snapshot, verticalDetails: true)
            }
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .supportedFamilies([
            .systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

@main
struct TodayWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}
