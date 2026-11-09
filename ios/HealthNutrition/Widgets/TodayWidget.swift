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
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: TodayEntry

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    /// No summary could be read (not written yet, or the device has not been unlocked since a restart): the
    /// widget then states nothing about the day rather than claiming nothing was logged.
    /// On a locked device the figures are redacted; the ring and bars would otherwise still show their proportions.
    private var hidesFigures: Bool { redactionReasons.contains(.privacy) }
    /// What VoiceOver reads for the calories; no figures while they are hidden on a locked device.
    private var spokenCalories: String {
        hidesFigures ? "Today's calories, hidden while locked" : (snapshot?.calorieSpoken ?? "Calories unknown")
    }
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
            // With no summary the ring is dimmed, so it does not read as an empty day.
            .opacity(snapshot?.energyFraction == nil ? 0.3 : 1)
            .accessibilityLabel(spokenCalories)
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
                Text("\(snapshot?.remainingCaption ?? "Calories remaining") \(remaining)")
                    .accessibilityLabel(spokenCalories)
                    .privacySensitive()
            } else {
                Text("\(snapshot?.foodText ?? "—") Food")
                    .accessibilityLabel(spokenCalories)
                    .privacySensitive()
            }
        case .systemMedium:
            HStack(alignment: .center, spacing: 16) {
                heroRing
                if !isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        macroBar("Protein", grams: snapshot?.proteinGrams, share: snapshot?.macroShares?.protein,
                                 color: Color("macroProtein"), key: "protein")
                        macroBar("Carbohydrate", grams: snapshot?.carbohydrateGrams, share: snapshot?.macroShares?.carbohydrate,
                                 color: Color("macroCarbs"), key: "carbohydrate")
                        macroBar("Fat", grams: snapshot?.fatGrams, share: snapshot?.macroShares?.fat,
                                 color: Color("macroFat"), key: "fat")
                        Text("Water \(WidgetFigure.water(snapshot?.waterMilliliters, usUnits: snapshot?.usUnits, partial: snapshot?.isPartial("water") == true))")
                            .font(.footnote)
                            .foregroundStyle(Color("heroText"))
                        if snapshot?.partialFigures?.isEmpty == false {
                            Text("+ Some entries are missing nutrients").font(.caption2)
                                .foregroundStyle(Color("heroSecondaryText"))
                        }
                    }
                    .privacySensitive()
                }
            }
        default:
            heroRing
        }
    }

    /// The remaining figure inside a ring (mint on the track) with the captions beside or under it; one spoken label.
    private var heroRing: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEmpty {
                Text("Today").font(.headline).foregroundStyle(Color("heroText"))
                Text("Nothing logged today").font(.footnote).foregroundStyle(Color("heroSecondaryText"))
            } else {
                ZStack {
                    Circle().stroke(Color("heroTrack"), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: hidesFigures ? 0 : (snapshot?.energyFraction ?? 0))
                        .stroke(Color("RelayMint"), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(snapshot?.remainingDisplay ?? snapshot?.foodText ?? "—")
                            .font(.title3.weight(.semibold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .foregroundStyle(Color("heroText"))
                        Text(snapshot?.remainingDisplay == nil ? "Food" : (snapshot?.remainingCaption ?? "Calories remaining"))
                            .font(.caption2)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(Color("heroSecondaryText"))
                    }
                    .padding(12)
                }
                .frame(maxWidth: 96, maxHeight: 96)
                .privacySensitive()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenCalories)
                // Food and Burned stay as before; the ring's label above already speaks them.
                WidgetFoodBurned(snapshot: snapshot, vertical: true)
                    .foregroundStyle(Color("heroSecondaryText"))
                    .privacySensitive()
                    .accessibilityHidden(true)
            }
        }
    }

    /// One macro: its name and grams in white over a bar filled in the macro colour; one spoken label.
    private func macroBar(_ name: String, grams: Double?, share: Double?, color: Color, key: String) -> some View {
        let figure = WidgetFigure.figure(grams, unit: "g", partial: snapshot?.isPartial(key) == true)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(name) \(figure)").font(.footnote).foregroundStyle(Color("heroText"))
            Capsule().fill(Color("heroTrack")).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color).frame(width: proxy.size.width * (hidesFigures ? 0 : (share ?? 0)))
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hidesFigures ? "\(name), hidden" : "\(name) \(figure)")
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(Color("hero"), for: .widget)
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
