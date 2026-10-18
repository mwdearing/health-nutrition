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
    private var energyPartial: Bool { snapshot?.isPartial("energy") == true }
    private var kcal: String { WidgetFigure.calories(snapshot?.energyKcal, partial: energyPartial) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: snapshot?.energyFraction ?? 0) {
                Image(systemName: "fork.knife")
            } currentValueLabel: {
                Text(kcal)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel(WidgetFigure.caloriesSpoken(snapshot?.energyKcal, partial: energyPartial))
            .privacySensitive()
        case .accessoryCorner:
            Text(kcal)
                .accessibilityLabel(WidgetFigure.caloriesSpoken(snapshot?.energyKcal, partial: energyPartial))
                .widgetLabel {
                    Gauge(value: snapshot?.energyFraction ?? 0) { Image(systemName: "fork.knife") }
                }
                .privacySensitive()
        case .accessoryInline:
            Text(snapshot?.hasEntries == false ? "Nothing logged today" : kcal)
                .accessibilityLabel(
                    snapshot?.hasEntries == false ? "Nothing logged today" : WidgetFigure.caloriesSpoken(snapshot?.energyKcal, partial: energyPartial)
                )
                .privacySensitive()
        default:
            VStack(alignment: .leading) {
                Text("Today").font(.headline)
                if snapshot?.hasEntries == false {
                    Text("Nothing logged today").font(.footnote)
                } else {
                    Text("\(kcal) · \(WidgetFigure.water(snapshot?.waterMilliliters, usUnits: snapshot?.usUnits)) water")
                        .privacySensitive()
                    Text(
                        "P \(WidgetFigure.number(snapshot?.proteinGrams, partial: snapshot?.isPartial("protein") == true)) · C \(WidgetFigure.number(snapshot?.carbohydrateGrams, partial: snapshot?.isPartial("carbohydrate") == true)) · F \(WidgetFigure.number(snapshot?.fatGrams, partial: snapshot?.isPartial("fat") == true)) g"
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
