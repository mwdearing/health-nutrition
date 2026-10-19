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
    private var unitsSubscription: AnyCancellable?
    /// The unit flag in the summary last written, so a change of units republishes without rewriting on every
    /// unrelated preference change.
    private var publishedUSUnits: Bool?
    /// The erase generation the last published load was stamped with. A unit change republishes under this one, so
    /// an erase that happened since rejects it just as it rejects a pending load.
    private var publishedGeneration: Int?
    private let store: WidgetSnapshotStore?
    private let erasure: WidgetSnapshotErasure
    private let watch: WatchSnapshotSender?
    private var isErasing: @MainActor () -> Bool = { false }

    init(
        store: WidgetSnapshotStore? = WidgetSnapshotStore.appGroup(),
        erasure: WidgetSnapshotErasure = .shared,
        watch: WatchSnapshotSender? = .shared
    ) {
        self.store = store
        self.erasure = erasure
        self.watch = watch
    }

    /// - Parameter isErasing: true while Erase all data runs. A write then would put figures back that the
    ///   eraser just removed; the reload Today does once the erase finishes publishes the empty day.
    func start(today: TodayViewModel, isErasing: @escaping @MainActor () -> Bool = { false }) {
        guard let store else { return }
        self.isErasing = isErasing
        // A temporary left by a write that was interrupted by a crash or a kill is removed at launch.
        store.removeStaleTemporary()
        // Every change to the totals goes through a load, and a successful load sets `lastLoadedAt`: the summary
        // is written when that moment changes and stamped with it. Nothing else (an undo expiring, a failed
        // reload, a notification after midnight) can make retained totals look fresh.
        // @Published delivers the current value on subscription, so a load that already happened is published too.
        // Switching units changes how water is drawn but not what Today loaded, so it is watched on its own: the
        // current summary is written again, with the new flag, when the flag differs from the one last written.
        unitsSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self, weak today] _ in
                MainActor.assumeIsolated {
                    guard let self, let today, let loadedAt = today.lastLoadedAt,
                        let generation = self.publishedGeneration,
                        self.publishedUSUnits != (today.unitSystem == .usCustomary)
                    else { return }
                    self.publish(from: today, loadedAt: loadedAt, generation: generation)
                }
            }
        subscription = today.$lastLoadedAt
            .compactMap { $0 }
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
    }

    func publish(from today: TodayViewModel, loadedAt: Date, generation: Int) {
        // Only the load whose totals are on screen is written: a pending write from an earlier load, or one whose
        // successor failed part way (lastLoadedAt is nil then), is dropped.
        guard let store, !isErasing(), erasure.accepts(generation: generation), today.lastLoadedAt == loadedAt
        else { return }
        // Reading the totals here, on the main actor, while `lastLoadedAt` still names this load (checked above),
        // is reading what that load produced.
        let snapshot = Self.snapshot(from: today, now: loadedAt)
        // The same summary goes to a paired Watch whether or not the App Group write works; the sender drops it if
        // an erase has happened since this load.
        watch?.submit(snapshot, erasureGeneration: generation)
        publishedUSUnits = snapshot.usUnits
        publishedGeneration = generation
        do {
            try store.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // The summary on disk is the previous one or none; the app does not depend on this write.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func snapshot(from today: TodayViewModel, now: Date) -> WidgetSnapshot {
        var partial: [String] = []
        // `shownAmount` is the known sum on a day where some entries have no value, the whole-day figure otherwise;
        // a figure that is only the known part is listed so the widget can say so.
        func total(_ key: String, in unit: MeasureUnit) -> Double? {
            let figure = Self.figure(today.progress.first { $0.nutrient == key }, in: unit)
            if figure.isPartial { partial.append(key) }
            return figure.value
        }
        let energyGoal = today.progress.first { $0.nutrient == "energy" }?.goal.flatMap {
            WidgetSnapshotUnits.value(Quantity(value: $0.target, unit: $0.unit), in: .kcal)
        }
        let energy = total("energy", in: .kcal)
        let protein = total("protein", in: .g)
        let carbohydrate = total("carbohydrate", in: .g)
        let fat = total("fat", in: .g)
        let calories = Self.calorieFigures(today.calorieRemaining)
        return WidgetSnapshot(
            generatedAt: now, hasEntries: !today.rows.isEmpty, energyKcal: energy,
            energyGoalKcal: energyGoal, proteinGrams: protein,
            carbohydrateGrams: carbohydrate, fatGrams: fat,
            waterMilliliters: NSDecimalNumber(decimal: today.waterTotalMilliliters).doubleValue,
            usUnits: today.unitSystem == .usCustomary, partialFigures: partial.isEmpty ? nil : partial,
            remainingKcal: calories.remaining, burnedKcal: calories.burned, remainingIsPartial: calories.isPartial)
    }
}

extension WidgetSnapshotPublisher {
    /// The calories-left model as snapshot figures. Each value is nil when the model has none (never zero), and the
    /// partial flag is only set when there is a Remaining for it to qualify.
    static func calorieFigures(_ model: CalorieRemaining) -> (remaining: Double?, burned: Double?, isPartial: Bool?) {
        func number(_ value: Decimal?) -> Double? {
            guard let value else { return nil }
            let number = NSDecimalNumber(decimal: value).doubleValue
            return number.isFinite ? number : nil
        }
        let remaining = number(model.remaining)
        return (remaining, number(model.burned), remaining == nil ? nil : (model.isPartial ? true : nil))
    }

    /// One line's figure for the snapshot: the shown amount (the known sum on a partial day) in the snapshot's unit,
    /// and whether it is only the known part. A figure that is unknown, or cannot be converted, is nil and never
    /// counted as zero.
    static func figure(_ line: NutrientProgressLine?, in unit: MeasureUnit) -> (value: Double?, isPartial: Bool) {
        guard let line, case .known(let value, let stored) = line.shownAmount,
            let converted = WidgetSnapshotUnits.value(Quantity(value: value, unit: stored), in: unit)
        else { return (nil, false) }
        return (converted, line.isPartial)
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
    private let watch: WatchSnapshotSender?
    private let now: () -> Date

    init(
        store: WidgetSnapshotStore? = WidgetSnapshotStore.appGroup(),
        erasure: WidgetSnapshotErasure = .shared, watch: WatchSnapshotSender? = .shared,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.erasure = erasure
        self.watch = watch
        self.now = now
    }


    var erasureName: String { "widget data" }

    func eraseAll() throws {
        // The generation moves first: from here on no write announced earlier can land, even if the empty write
        // below fails and the file has to be removed instead.
        erasure.markErased()
        defer { WidgetCenter.shared.reloadAllTimelines() }
        // The Watch's copy is replaced by an empty envelope under the new generation (held and sent on activation
        // if the session is not active yet), whether or not the App Group store exists on this build.
        watch?.erased(erasureGeneration: erasure.generation)
        guard let store else { return }
        // The legacy files are tried first and a failure is reported at the end, after the folder's summary has
        // been emptied, so one failure cannot leave the other figures behind.
        let legacy = Result { try store.removeLegacyRootFiles() }
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
        try legacy.get()
    }
}
