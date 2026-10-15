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
        subscription = Self.emissionTimes(of: today.objectWillChange)
            .sink { [weak self, weak today] changedAt in
                guard let self, let today else { return }
                // objectWillChange fires before the values change; by the time the debounce delivers, the new ones are in.
                self.publish(from: today, at: changedAt)
            }
        publish(from: today, at: Date())
    }

    /// The time of each change, taken when the change was announced and delivered after the debounce. The snapshot is
    /// stamped with that time and not the time of the write, so a load that finished at 23:59:59 and is written just
    /// after midnight still carries yesterday's time and goes stale at midnight instead of being shown as today's.
    nonisolated static func emissionTimes<P: Publisher>(
        of publisher: P, debounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(300),
        on scheduler: DispatchQueue = .main, now: @escaping () -> Date = { Date() }
    ) -> AnyPublisher<Date, Never> where P.Failure == Never {
        publisher.map { _ in now() }.debounce(for: debounce, scheduler: scheduler).eraseToAnyPublisher()
    }

    func publish(from today: TodayViewModel, at time: Date = Date()) {
        guard let store, !isErasing(),
            Self.shouldPublish(errorMessage: today.errorMessage, hasLoaded: !today.dateSubtitle.isEmpty)
        else { return }
        let snapshot = Self.snapshot(from: today, now: time)
        do {
            try store.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // The widgets keep showing the last snapshot; the app does not depend on this write.
        }
    }

    /// Nothing is written until Today has loaded successfully once, and not while it reports an error. Before the
    /// first load Today holds only its initializer defaults, and after a failed reload it keeps the rows and totals
    /// it had, so stamping either with a fresh time would replace valid totals or make yesterday's look current and
    /// defeat the widget's stale-day check. The file keeps its old time, and a later successful load publishes.
    nonisolated static func shouldPublish(errorMessage: String?, hasLoaded: Bool) -> Bool {
        hasLoaded && errorMessage == nil
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
