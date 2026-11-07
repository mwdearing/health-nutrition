import SwiftUI
import WatchConnectivity
import WidgetKit

/// The Watch app: it receives the Today summary the phone sends, keeps it where the Watch widgets read it, and
/// shows it. It has no feature of its own and logs nothing.
@main
struct HealthNutritionWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The session is activated here, outside any scene, so it exists when the system wakes the app in the
        // background with a Watch Connectivity task and no scene is created.
        _ = WatchSummaryModel.shared
    }

    var body: some Scene {
        WindowGroup {
            WatchTodayRoot(model: WatchSummaryModel.shared)
        }
        // A process that stayed alive in the background re-reads what is stored when the app is opened again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { WatchSummaryModel.shared.refresh() }
        }
        // The system wakes the app for a context the phone sent while it was not running. The task ends when this
        // returns, so it returns only once the context has been stored and the complications reloaded.
        .backgroundTask(.watchConnectivity) {
            await WatchSummaryModel.shared.handleWatchConnectivityRefresh()
        }
    }
}

struct WatchTodayRoot: View {
    @ObservedObject var model: WatchSummaryModel

    var body: some View {
        WatchTodayView(snapshot: model.snapshot)
    }
}

final class WatchSummaryModel: NSObject, ObservableObject, WCSessionDelegate {
    /// One instance for the process, owned by no scene, so the session and the receiver outlive any window.
    static let shared = WatchSummaryModel()

    @Published private(set) var snapshot: WidgetSnapshot?
    private let store: WidgetSnapshotStore?
    /// Created once, before the session is activated. The background-task refresh and the session delegate both
    /// reach it from different threads, and they must share its lock; a `lazy var` is not synchronized and could
    /// give each caller its own receiver.
    private let receiver: WatchSnapshotReceiver

    private override init() {
        let store = WidgetSnapshotStore.appGroup()
        self.store = store
        self.receiver = WatchSnapshotReceiver(store: store) {
            WidgetCenter.shared.reloadAllTimelines()
        }
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

    /// The body of the Watch Connectivity background task: makes sure the session is active, applies the pending
    /// context and returns once the session has nothing more waiting (or after a bounded wait).
    func handleWatchConnectivityRefresh() async {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        if session.activationState != .activated { session.activate() }
        // The context is only readable once the session is active.
        // Activation and the pending wait share one budget, well under what the system allows a background task.
        let pauseNanoseconds: UInt64 = 250_000_000
        let deadline = ContinuousClock.now + .seconds(6)
        while session.activationState != .activated, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }
        let remaining = deadline - ContinuousClock.now
        let remainingChecks = max(0, Int(remaining / .milliseconds(250)))
        await WatchConnectivityRefresh.run(
            receiver: receiver, context: { session.receivedApplicationContext },
            hasContentPending: { session.hasContentPending }, pause: { try? await Task.sleep(nanoseconds: pauseNanoseconds) },
            maxChecks: min(WatchConnectivityRefresh.defaultMaxChecks, remainingChecks))
        refresh()
    }

    private func apply(_ context: [String: Any]) {
        WatchConnectivityRefresh.apply(context, through: receiver)
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
    @Environment(\.redactionReasons) private var redactionReasons
    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 76

    private var hidesFigures: Bool { redactionReasons.contains(.privacy) }


    var body: some View {
        // Redrawn every minute, so the day changing drops yesterday's figures to dashes without any new data.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(for: snapshot.flatMap { $0.isCurrent(on: context.date) ? $0 : nil })
        }
    }

    private func content(for snapshot: WidgetSnapshot?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Today").font(.headline)
                if snapshot?.hasEntries == false {
                    Text("Nothing logged today").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ring(for: snapshot)
                    macroRow("Protein", grams: snapshot?.proteinGrams, key: "protein", color: Color("macroProtein"), snapshot: snapshot)
                    macroRow("Carbohydrate", grams: snapshot?.carbohydrateGrams, key: "carbohydrate", color: Color("macroCarbs"), snapshot: snapshot)
                    macroRow("Fat", grams: snapshot?.fatGrams, key: "fat", color: Color("macroFat"), snapshot: snapshot)
                    Text("\(WidgetFigure.water(snapshot?.waterMilliliters, usUnits: snapshot?.usUnits, partial: snapshot?.isPartial("water") == true)) water")
                        .font(.footnote)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The remaining figure inside a ring with a caption saying what it is ("left" with a goal, "eaten" without);
    /// the food and burned lines follow. One spoken label covers them all: the caption is visible only, because the
    /// snapshot's own wording already says "calories remaining" or "Food, N calories".
    private func ring(for snapshot: WidgetSnapshot?) -> some View {
        let caption = snapshot?.remainingDisplay == nil ? "eaten" : "left"
        return VStack(alignment: .leading, spacing: 4) {
            Gauge(value: hidesFigures ? 0 : (snapshot?.energyFraction ?? 0)) {
                Text("Calories")
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text(snapshot?.remainingDisplay ?? snapshot?.foodText ?? "—")
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Color("RelayMint"))
            .frame(width: ringSize, height: ringSize)
            .frame(maxWidth: .infinity)
            .privacySensitive()
            WidgetFoodBurned(snapshot: snapshot, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hidesFigures ? "Today's calories, hidden while locked"
            : (snapshot?.calorieSpoken ?? "Calories unknown"))
    }

    /// A coloured dot (a fill, never text) beside the macro's name and grams in the primary text colour.
    private func macroRow(_ name: String, grams: Double?, key: String, color: Color, snapshot: WidgetSnapshot?) -> some View {
        let figure = WidgetFigure.figure(grams, unit: "g", partial: snapshot?.isPartial(key) == true)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(name) \(figure)").font(.footnote)
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hidesFigures ? "\(name), hidden" : "\(name) \(figure)")
    }
}
