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
            // Stamped with the erase generation when the load is announced, before the debounce, so a write that
            // was already pending when an erase ran is recognised whatever the clock does in between. Today's load
            // is synchronous on the main actor, so the moment it is announced is the moment the journal was read:
            // no read can start before an erase and finish after it.
            .map { [erasure] loadedAt in (loadedAt: loadedAt, generation: erasure.generation) }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self, weak today] load in
                // Delivered on the main queue by the debounce scheduler above, so this is the main actor.
                MainActor.assumeIsolated {
                    guard let self, let today else { return }
                    self.publish(from: today, loadedAt: load.loadedAt, generation: load.generation)
                }
            }
        if let loadedAt = today.lastLoadedAt {
            publish(from: today, loadedAt: loadedAt, generation: erasure.generation)
        }
    }

    func publish(from today: TodayViewModel, loadedAt: Date, generation: Int) {
        // Only the load whose totals are on screen is written: a pending write from an earlier load, or one whose
        // successor failed part way (lastLoadedAt is nil then), is dropped.
        guard let store, !isErasing(), erasure.accepts(generation: generation), today.lastLoadedAt == loadedAt
        else { return }
        // Reading the totals here, on the main actor, while `lastLoadedAt` still names this load (checked above),
        // is reading what that load produced.
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

/// A counter that moves on every Erase all data, so a summary write that was already pending (a load announced
/// before the erase) can be recognised and dropped instead of putting the erased figures back. A counter, not a
/// time: it does not depend on the clock.
final class WidgetSnapshotErasure: @unchecked Sendable {
    static let shared = WidgetSnapshotErasure()

    private let lock = NSLock()
    private var count = 0

    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func markErased() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// A load announced under an earlier generation read the journal before an erase.
    func accepts(generation: Int) -> Bool {
        generation == self.generation
    }
}

/// Clears the widgets' summary when the person's data is erased, so "Erase all data" leaves no figures in the App
/// Group. It first replaces the summary with an empty one, so the widget reads "Nothing logged today" at once; if
/// that write fails it removes the file instead, and it reloads the widgets either way. A summary write already
/// pending at that moment is recognised by its erase generation and dropped.
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
        // The generation moves first: from here on no write announced earlier can land, even if the empty write
        // below fails and the file has to be removed instead.
        erasure.markErased()
        defer { WidgetCenter.shared.reloadAllTimelines() }
        guard let store else { return }
        do {
            try store.write(WidgetSnapshot.empty(at: now()))
        } catch {
            do {
                try store.erase()
            } catch {
                // Neither replacing nor removing worked: empty the file in place so no figure is left, then try
                // the removal once more. If even that cannot be done the erase reports the failure.
                try store.truncate()
                try? store.erase()
            }
        }
    }
}
