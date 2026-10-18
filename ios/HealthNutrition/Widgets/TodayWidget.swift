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

private func figure(_ value: Double?, unit: String) -> String {
    guard let text = WidgetFigure.wholeNumber(value) else { return "—" }
    return "\(text) \(unit)"
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
                Text(WidgetFigure.wholeNumber(snapshot?.energyKcal) ?? "—")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel(WidgetFigure.caloriesSpoken(snapshot?.energyKcal))
            .privacySensitive()
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Today").font(.headline)
                if isEmpty {
                    Text("Nothing logged today")
                } else {
                    Text(WidgetFigure.calories(snapshot?.energyKcal))
                        .accessibilityLabel(WidgetFigure.caloriesSpoken(snapshot?.energyKcal))
                    Text("Water \(WidgetFigure.water(snapshot?.waterMilliliters, usUnits: snapshot?.usUnits))")
                }
            }
            .privacySensitive()
        case .accessoryInline:
            Text(isEmpty ? "Nothing logged today" : WidgetFigure.calories(snapshot?.energyKcal))
                .accessibilityLabel(isEmpty ? "Nothing logged today" : WidgetFigure.caloriesSpoken(snapshot?.energyKcal))
                .privacySensitive()
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                summary
                if !isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Protein \(figure(snapshot?.proteinGrams, unit: "g"))")
                        Text("Carbohydrate \(figure(snapshot?.carbohydrateGrams, unit: "g"))")
                        Text("Fat \(figure(snapshot?.fatGrams, unit: "g"))")
                        Text("Water \(WidgetFigure.water(snapshot?.waterMilliliters, usUnits: snapshot?.usUnits))")
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
            Text("Today").font(.headline)
            if isEmpty {
                Text("Nothing logged today").font(.footnote)
            } else {
                Text(WidgetFigure.calories(snapshot?.energyKcal))
                    .accessibilityLabel(WidgetFigure.caloriesSpoken(snapshot?.energyKcal))
                    .font(.title2.weight(.semibold))
                    .privacySensitive()
                if let fraction = snapshot?.energyFraction {
                    ProgressView(value: fraction).privacySensitive()
                }
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
