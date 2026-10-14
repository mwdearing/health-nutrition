import Combine
import Foundation
import NutritionDomain
import NutritionJournal
import NutritionUI
import WidgetKit

/// Keeps the widgets' snapshot in step with Today: after Today's figures change it writes the summary into the
/// App Group and asks WidgetKit to refresh. Nothing is written where the App Group is unavailable.
@MainActor
final class WidgetSnapshotPublisher {
    private var subscription: AnyCancellable?
    private let store: WidgetSnapshotStore?
    private var isErasing: () -> Bool = { false }

    init(store: WidgetSnapshotStore? = WidgetSnapshotStore.appGroup()) {
        self.store = store
    }

    /// - Parameter isErasing: true while Erase all data runs. A write then would put figures back that the
    ///   eraser just removed; the reload Today does once the erase finishes publishes the empty day.
    func start(today: TodayViewModel, isErasing: @escaping () -> Bool = { false }) {
        guard store != nil else { return }
        self.isErasing = isErasing
        subscription = today.objectWillChange
            // objectWillChange fires before the values change; the next run loop turn sees the new ones.
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self, weak today] _ in
                guard let self, let today else { return }
                self.publish(from: today)
            }
        publish(from: today)
    }

    func publish(from today: TodayViewModel) {
        guard let store, !isErasing() else { return }
        let snapshot = Self.snapshot(from: today, now: Date())
        do {
            try store.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // The widgets keep showing the last snapshot; the app does not depend on this write.
        }
    }

    static func snapshot(from today: TodayViewModel, now: Date) -> WidgetSnapshot {
        func total(_ key: String) -> Double? {
            guard let line = today.progress.first(where: { $0.nutrient == key }),
                case .known(let value, _) = line.amount
            else { return nil }
            return NSDecimalNumber(decimal: value).doubleValue
        }
        let energyGoal = today.progress.first { $0.nutrient == "energy" }?.goal
        return WidgetSnapshot(
            generatedAt: now, hasEntries: !today.rows.isEmpty, energyKcal: total("energy"),
            energyGoalKcal: energyGoal.map { NSDecimalNumber(decimal: $0.target).doubleValue },
            proteinGrams: total("protein"), carbohydrateGrams: total("carbohydrate"), fatGrams: total("fat"),
            waterMilliliters: NSDecimalNumber(decimal: today.waterTotalMilliliters).doubleValue)
    }
}

/// Removes the widgets' snapshot with the rest of the person's data, so "Erase all data" leaves no figures in
/// the App Group.
final class WidgetSnapshotEraser: JournalErasing, @unchecked Sendable {
    private let store: WidgetSnapshotStore?

    init(store: WidgetSnapshotStore? = WidgetSnapshotStore.appGroup()) {
        self.store = store
    }

    func eraseAll() throws {
        try store?.erase()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
