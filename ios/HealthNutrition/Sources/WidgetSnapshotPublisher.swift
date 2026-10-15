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
    private let erasure: WidgetSnapshotErasure
    private var isErasing: @MainActor () -> Bool = { false }

    init(
        store: WidgetSnapshotStore? = WidgetSnapshotStore.appGroup(),
        erasure: WidgetSnapshotErasure = .shared
    ) {
        self.store = store
        self.erasure = erasure
    }

    /// - Parameter isErasing: true while Erase all data runs. A write then would put figures back that the
    ///   eraser just removed; the reload Today does once the erase finishes publishes the empty day.
    func start(today: TodayViewModel, isErasing: @escaping @MainActor () -> Bool = { false }) {
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
                // Delivered on the main queue by the debounce scheduler above, so this is the main actor.
                MainActor.assumeIsolated {
                    guard let self, let today else { return }
                    self.publish(from: today, loadedAt: loadedAt)
                }
            }
        if let loadedAt = today.lastLoadedAt { publish(from: today, loadedAt: loadedAt) }
    }

    func publish(from today: TodayViewModel, loadedAt: Date) {
        guard let store, !isErasing(), erasure.accepts(loadedAt: loadedAt) else { return }
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

/// When Erase all data last ran, so a summary write that was already pending (a load stamped before the erase)
/// can be recognised and dropped instead of putting the erased figures back.
final class WidgetSnapshotErasure: @unchecked Sendable {
    static let shared = WidgetSnapshotErasure()

    private let lock = NSLock()
    private var erasedAt: Date?

    func markErased(at time: Date) {
        lock.lock()
        erasedAt = time
        lock.unlock()
    }

    /// A load stamped at or before the last erase is stale: it read the journal before the erase.
    func accepts(loadedAt: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let erasedAt else { return true }
        return loadedAt > erasedAt
    }
}

/// Replaces the widgets' summary with an empty one when the person's data is erased, so "Erase all data" leaves no
/// figures in the App Group and the widget reads "Nothing logged today" at once. A summary write already pending
/// at that moment is recognised by its load time and dropped.
final class WidgetSnapshotEraser: JournalErasing, @unchecked Sendable {
    private let store: WidgetSnapshotStore?
    private let erasure: WidgetSnapshotErasure
    private let now: () -> Date

    init(
        store: WidgetSnapshotStore? = WidgetSnapshotStore.appGroup(),
        erasure: WidgetSnapshotErasure = .shared, now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.erasure = erasure
        self.now = now
    }

    func eraseAll() throws {
        let time = now()
        erasure.markErased(at: time)
        try store?.write(WidgetSnapshot.empty(at: time))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
