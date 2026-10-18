import SwiftUI
import WatchConnectivity
import WidgetKit

/// The Watch app: it receives the Today summary the phone sends, keeps it where the Watch widgets read it, and
/// shows it. It has no feature of its own and logs nothing.
@main
struct HealthNutritionWatchApp: App {
    @StateObject private var model = WatchSummaryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchTodayView(snapshot: model.snapshot)
        }
        // A process that stayed alive in the background re-reads what is stored when the app is opened again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }
}

final class WatchSummaryModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: WidgetSnapshot?
    private let store = WidgetSnapshotStore.appGroup()
    private lazy var receiver = WatchSnapshotReceiver(store: store) {
        WidgetCenter.shared.reloadAllTimelines()
    }

    override init() {
        super.init()
        refresh()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// What is stored. Whether it is from today is decided by the view, against the clock it is drawn with, so a
    /// summary does not stay on screen past midnight.
    func refresh() {
        let stored = store?.read()
        DispatchQueue.main.async { self.snapshot = stored }
    }

    private func apply(_ context: [String: Any]) {
        guard !context.isEmpty else { return }
        receiver.receive(context: context)
        refresh()
    }

    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        // The last context the phone sent is delivered here after a launch, with no callback of its own.
        if activationState == .activated { apply(session.receivedApplicationContext) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }
}

struct WatchTodayView: View {
    let snapshot: WidgetSnapshot?

    private func figure(_ value: Double?, _ unit: String) -> String {
        guard let text = WidgetFigure.wholeNumber(value) else { return "—" }
        return "\(text) \(unit)"
    }

    var body: some View {
        // Redrawn every minute, so the day changing drops yesterday's figures to dashes without any new data.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(for: snapshot.flatMap { $0.isCurrent(on: context.date) ? $0 : nil })
        }
    }

    private func content(for snapshot: WidgetSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today").font(.headline)
            if snapshot?.hasEntries == false {
                Text("Nothing logged today").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(WidgetFigure.calories(snapshot?.energyKcal)).font(.title3).privacySensitive()
                    .accessibilityLabel(WidgetFigure.caloriesSpoken(snapshot?.energyKcal))
                Text(
                    "P \(WidgetFigure.wholeNumber(snapshot?.proteinGrams) ?? "—") · C \(WidgetFigure.wholeNumber(snapshot?.carbohydrateGrams) ?? "—") · F \(WidgetFigure.wholeNumber(snapshot?.fatGrams) ?? "—") g"
                ).font(.footnote).privacySensitive()
                Text("\(WidgetFigure.water(snapshot?.waterMilliliters, usUnits: snapshot?.usUnits)) water").font(.footnote).privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
