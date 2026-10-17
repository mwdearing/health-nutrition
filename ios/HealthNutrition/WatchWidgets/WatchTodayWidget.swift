import SwiftUI
import WidgetKit

/// The Today summary as a Watch face complication and in the Smart Stack. It reads only the summary the Watch app
/// stores from what the phone sends (Shared/WidgetSnapshot.swift); it links no package and has no network access.
struct WatchTodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    /// Smart Stack hint: higher around the usual meal times, so the card rises when logging is likely.
    var relevance: TimelineEntryRelevance? {
        let hour = Calendar.current.component(.hour, from: date)
        let mealtime = [7...9, 12...14, 18...20].contains { $0.contains(hour) }
        return TimelineEntryRelevance(score: mealtime ? 10 : 2)
    }
}

struct WatchTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchTodayEntry {
        WatchTodayEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchTodayEntry) -> Void) {
        completion(current(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchTodayEntry>) -> Void) {
        let now = Date()
        let next = min(now.addingTimeInterval(30 * 60), WidgetSnapshot.refreshAfterMidnight(from: now))
        // An entry at the next midnight shows dashes (no summary can be from that day yet) even if the system is
        // late to ask for a reload.
        let midnight = WatchTodayEntry(date: WidgetSnapshot.nextMidnight(from: now), snapshot: nil)
        completion(Timeline(entries: [current(at: now), midnight], policy: .after(next)))
    }

    private func current(at now: Date) -> WatchTodayEntry {
        let snapshot = WidgetSnapshotStore.appGroup()?.read().flatMap { $0.isCurrent(on: now) ? $0 : nil }
        return WatchTodayEntry(date: now, snapshot: snapshot)
    }
}

struct WatchTodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchTodayEntry

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var kcal: String { WidgetFigure.wholeNumber(snapshot?.energyKcal) ?? "—" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: snapshot?.energyFraction ?? 0) {
                Text("kcal")
            } currentValueLabel: {
                Text(kcal)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .privacySensitive()
        case .accessoryCorner:
            Text(kcal)
                .widgetLabel {
                    Gauge(value: snapshot?.energyFraction ?? 0) { Text("kcal") }
                }
                .privacySensitive()
        case .accessoryInline:
            Text(snapshot?.hasEntries == false ? "Nothing logged today" : "\(kcal) kcal")
                .privacySensitive()
        default:
            VStack(alignment: .leading) {
                Text("Today").font(.headline)
                if snapshot?.hasEntries == false {
                    Text("Nothing logged today").font(.footnote)
                } else {
                    Text("\(kcal) kcal · \(WidgetFigure.wholeNumber(snapshot?.waterMilliliters) ?? "—") mL water")
                        .privacySensitive()
                    Text(
                        "P \(WidgetFigure.wholeNumber(snapshot?.proteinGrams) ?? "—") · C \(WidgetFigure.wholeNumber(snapshot?.carbohydrateGrams) ?? "—") · F \(WidgetFigure.wholeNumber(snapshot?.fatGrams) ?? "—") g"
                    ).font(.footnote).privacySensitive()
                }
            }
        }
    }
}

struct WatchTodayWidget: Widget {
    let kind = "TodayWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchTodayProvider()) { entry in
            WatchTodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Calories, macros and water for today.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct WatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WatchTodayWidget()
    }
}
