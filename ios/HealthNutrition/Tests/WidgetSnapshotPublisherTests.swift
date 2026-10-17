import Foundation
import NutritionUI
import XCTest

@testable import HealthNutrition

/// The publisher's gates against a real Today view model on throwaway files: it writes for the load on screen,
/// and not while an erase runs, for a load announced before an erase, or for a load that is no longer the one on
/// screen. Synthetic data only; display settings live in a throwaway suite.
@MainActor
final class WidgetSnapshotPublisherTests: XCTestCase {
    private let loadedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var directory: URL!

    private func makeToday() throws -> TodayViewModel {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "synthetic.widget.publisher.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { [directory] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let services = try AppServices.make(
            directory: directory.appendingPathComponent("app", isDirectory: true),
            displayPreferences: UserDefaultsDisplayPreferences(defaults: suite),
            reminderScheduler: RecordingReminderScheduler(),
            // Never the real App Group: this test only exercises the publisher against its own store.
            widgetSnapshotEraser: WidgetSnapshotEraser(store: nil, watch: nil))
        return services.today
    }

    private func makeStore() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directory: directory.appendingPathComponent("group", isDirectory: true))
    }

    func testItWritesForTheLoadOnScreen() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: WidgetSnapshotErasure(), watch: nil)
        publisher.publish(from: today, loadedAt: loadedAt, generation: 0)
        XCTAssertEqual(store.read()?.generatedAt, loadedAt)
    }

    func testItWritesNothingForALoadThatIsNoLongerTheOneOnScreen() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: WidgetSnapshotErasure(), watch: nil)
        // A write announced for an earlier load: today.lastLoadedAt has moved on.
        publisher.publish(from: today, loadedAt: loadedAt.addingTimeInterval(-60), generation: 0)
        XCTAssertNil(store.read())
    }

    func testItWritesNothingForALoadAnnouncedBeforeAnErase() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let erasure = WidgetSnapshotErasure()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: erasure, watch: nil)
        let pending = erasure.generation
        erasure.markErased()
        publisher.publish(from: today, loadedAt: loadedAt, generation: pending)
        XCTAssertNil(store.read())
    }

    func testItWritesNothingWhileAnEraseRuns() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: WidgetSnapshotErasure(), watch: nil)
        publisher.start(today: today, isErasing: { true })
        XCTAssertNil(store.read(), "the launch-time publish also waits out an erase")
    }
}
