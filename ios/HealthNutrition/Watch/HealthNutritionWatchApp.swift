import SwiftUI
import WatchConnectivity
import WidgetKit

/// The Watch app: it receives the Today summary the phone sends, keeps it where the Watch widgets read it, and
/// shows it. It has no feature of its own and logs nothing.
@main
struct HealthNutritionWatchApp: App {
    @StateObject private var model = WatchSummaryModel()

    var body: some Scene {
        WindowGroup {
            WatchTodayView(snapshot: model.snapshot)
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

    /// What is stored, if it is from today.
    private func refresh() {
        let now = Date()
        let stored = store?.read().flatMap { $0.isCurrent(on: now) ? $0 : nil }
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Today").font(.headline)
            if snapshot?.hasEntries == false {
                Text("Nothing logged today").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(figure(snapshot?.energyKcal, "kcal")).font(.title3).privacySensitive()
                Text(
                    "P \(WidgetFigure.wholeNumber(snapshot?.proteinGrams) ?? "—") · C \(WidgetFigure.wholeNumber(snapshot?.carbohydrateGrams) ?? "—") · F \(WidgetFigure.wholeNumber(snapshot?.fatGrams) ?? "—") g"
                ).font(.footnote).privacySensitive()
                Text(figure(snapshot?.waterMilliliters, "mL water")).font(.footnote).privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
