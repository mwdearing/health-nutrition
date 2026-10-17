import Foundation
import XCTest

@testable import HealthNutrition

/// The Watch's receiver against throwaway files and a throwaway defaults suite. Synthetic figures only.
final class WatchSnapshotReceiverTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var reloads = 0
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "synthetic.watch.receiver.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = directory!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        reloads = 0
    }

    private func makeReceiver() -> (WatchSnapshotReceiver, WidgetSnapshotStore) {
        let store = WidgetSnapshotStore(directory: directory)
        return (WatchSnapshotReceiver(store: store, defaults: defaults, now: { self.now }) { self.reloads += 1 }, store)
    }

    private func sample() -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now, hasEntries: true, energyKcal: 1_050, energyGoalKcal: 2_100, proteinGrams: 80,
            carbohydrateGrams: 120, fatGrams: 40, waterMilliliters: 750)
    }

    private func context(generation: Int, snapshot: WidgetSnapshot?) throws -> [String: Any] {
        try WatchSnapshotEnvelope(eraseGeneration: generation, snapshot: snapshot).context()
    }

    func testASummaryIsStoredAndTheWidgetsAreReloaded() throws {
        let (receiver, store) = makeReceiver()
        receiver.receive(context: try context(generation: 0, snapshot: sample()))
        XCTAssertEqual(store.read(), sample())
        XCTAssertEqual(reloads, 1)
    }

    func testTheEraseStoresAnEmptyDay() throws {
        let (receiver, store) = makeReceiver()
        receiver.receive(context: try context(generation: 0, snapshot: sample()))
        receiver.receive(context: try context(generation: 1, snapshot: nil))
        let stored = try XCTUnwrap(store.read())
        XCTAssertFalse(stored.hasEntries)
        XCTAssertNil(stored.energyKcal)
        XCTAssertEqual(receiver.highestEraseGeneration, 1)
    }

    func testAContextFromBeforeAnEraseIsIgnored() throws {
        let (receiver, store) = makeReceiver()
        receiver.receive(context: try context(generation: 2, snapshot: nil))
        let reloadsAfterErase = reloads
        receiver.receive(context: try context(generation: 1, snapshot: sample()))
        XCTAssertFalse(try XCTUnwrap(store.read()).hasEntries, "the late pre-erase summary did not land")
        XCTAssertEqual(reloads, reloadsAfterErase)
    }

    func testTheHighestGenerationSurvivesANewReceiver() throws {
        let (first, _) = makeReceiver()
        first.receive(context: try context(generation: 3, snapshot: nil))
        let (second, store) = makeReceiver()
        XCTAssertEqual(second.highestEraseGeneration, 3)
        second.receive(context: try context(generation: 2, snapshot: sample()))
        XCTAssertFalse(try XCTUnwrap(store.read()).hasEntries)
    }

    func testAnUnknownSchemaOrAMalformedPayloadRemovesTheSummaryAndDoesNotCrash() throws {
        let (receiver, store) = makeReceiver()
        receiver.receive(context: try context(generation: 0, snapshot: sample()))
        let newer = WatchSnapshotEnvelope(
            eraseGeneration: 0, snapshot: sample(), schemaVersion: WatchSnapshotEnvelope.currentSchemaVersion + 1)
        receiver.receive(context: try newer.context())
        XCTAssertNil(store.read())
        receiver.receive(context: try context(generation: 0, snapshot: sample()))
        receiver.receive(context: [WatchSnapshotEnvelope.contextKey: Data("{".utf8)])
        XCTAssertNil(store.read())
        receiver.receive(context: [:])
        XCTAssertNil(store.read())
    }

    func testWithoutAStoreNothingHappens() throws {
        let receiver = WatchSnapshotReceiver(store: nil, defaults: defaults) { self.reloads += 1 }
        receiver.receive(context: try context(generation: 0, snapshot: sample()))
        XCTAssertEqual(reloads, 0)
    }
}
