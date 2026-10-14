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
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // The app asks for a reload whenever Today changes; this only covers the day rolling over.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func current() -> TodayEntry {
        TodayEntry(date: Date(), snapshot: WidgetSnapshotStore.appGroup()?.read())
    }
}

private func figure(_ value: Double?, unit: String) -> String {
    guard let value, value.isFinite else { return "—" }
    return "\(Int(value.rounded())) \(unit)"
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
                Text("kcal")
            } currentValueLabel: {
                Text(snapshot?.energyKcal.map { "\(Int($0.rounded()))" } ?? "—")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .privacySensitive()
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Today").font(.headline)
                if isEmpty {
                    Text("Nothing logged today")
                } else {
                    Text(figure(snapshot?.energyKcal, unit: "kcal"))
                    Text("Water \(figure(snapshot?.waterMilliliters, unit: "mL"))")
                }
            }
            .privacySensitive()
        case .accessoryInline:
            Text(isEmpty ? "Nothing logged today" : figure(snapshot?.energyKcal, unit: "kcal"))
                .privacySensitive()
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                summary
                if !isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Protein \(figure(snapshot?.proteinGrams, unit: "g"))")
                        Text("Carbohydrate \(figure(snapshot?.carbohydrateGrams, unit: "g"))")
                        Text("Fat \(figure(snapshot?.fatGrams, unit: "g"))")
                        Text("Water \(figure(snapshot?.waterMilliliters, unit: "mL"))")
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
                Text(figure(snapshot?.energyKcal, unit: "kcal"))
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
struct HealthNutritionWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}
