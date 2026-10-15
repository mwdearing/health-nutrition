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
        // Every change to the totals goes through a load, and a successful load sets `lastLoadedAt`: the summary
        // is written when that moment changes and stamped with it. Nothing else (an undo expiring, a failed
        // reload, a notification after midnight) can make retained totals look fresh.
        subscription = today.$lastLoadedAt
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self, weak today] loadedAt in
                guard let self, let today else { return }
                self.publish(from: today, loadedAt: loadedAt)
            }
        if let loadedAt = today.lastLoadedAt { publish(from: today, loadedAt: loadedAt) }
    }

    func publish(from today: TodayViewModel, loadedAt: Date) {
        guard let store, !isErasing() else { return }
        let snapshot = Self.snapshot(from: today, now: loadedAt)
        do {
            try store.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // The widgets keep showing the last snapshot; the app does not depend on this write.
        }
    }

    static func snapshot(from today: TodayViewModel, now: Date) -> WidgetSnapshot {
        func total(_ key: String, in unit: MeasureUnit) -> Double? {
            guard let line = today.progress.first(where: { $0.nutrient == key }),
                case .known(let value, let stored) = line.amount
            else { return nil }
            return WidgetSnapshotUnits.value(Quantity(value: value, unit: stored), in: unit)
        }
        let energyGoal = today.progress.first { $0.nutrient == "energy" }?.goal.flatMap {
            WidgetSnapshotUnits.value(Quantity(value: $0.target, unit: $0.unit), in: .kcal)
        }
        return WidgetSnapshot(
            generatedAt: now, hasEntries: !today.rows.isEmpty, energyKcal: total("energy", in: .kcal),
            energyGoalKcal: energyGoal, proteinGrams: total("protein", in: .g),
            carbohydrateGrams: total("carbohydrate", in: .g), fatGrams: total("fat", in: .g),
            waterMilliliters: NSDecimalNumber(decimal: today.waterTotalMilliliters).doubleValue)
    }
}

/// The snapshot's figures are in one fixed unit each (g, kcal, mL); a total stored in another compatible unit is
/// converted first, and a value that cannot be converted is left out, which the widget shows as dashes.
enum WidgetSnapshotUnits {
    static func value(_ quantity: Quantity, in target: MeasureUnit) -> Double? {
        guard let converted = try? quantity.converted(to: target) else { return nil }
        let number = NSDecimalNumber(decimal: converted.value).doubleValue
        return number.isFinite ? number : nil
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
