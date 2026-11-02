import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// #1156: a `close()` that lands between an erase's row delete and its file replacement must stay closed.
final class GoalCloseDuringEraseTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testACloseDuringAnEraseStaysClosed() throws {
        let url = try makeDirectory().appendingPathComponent("goals.store")
        var operations = StoreFileOperations.system
        var storeRef: SwiftDataGoalStore?
        operations.afterRowsDeleted = {
            // The erase holds writeLock here, not the store lock, so a close from another thread can run now.
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataGoalStore(url: url, fileOperations: operations)
        storeRef = store
        try store.setGoal(NutrientGoal(nutrient: "protein", target: 60, unit: .g))
        try store.eraseAll()
        XCTAssertThrowsError(try store.goals()) { error in
            XCTAssertEqual(error as? GoalStoreError, .closed, "the erase reopened a store that was closed")
        }
        XCTAssertThrowsError(try store.setGoal(NutrientGoal(nutrient: "protein", target: 70, unit: .g))) { error in
            XCTAssertEqual(error as? GoalStoreError, .closed)
        }
    }

    /// The emptied container is not held after a close during an erase (#1156): the store must drop the container the
    /// erase opened, so nothing keeps the file open once the store is closed.
    func testTheEmptiedContainerIsNotHeldAfterACloseDuringAnErase() throws {
        let url = try makeDirectory().appendingPathComponent("goals.store")
        final class Probe { weak var container: ModelContainer? }
        let probe = Probe()
        var operations = StoreFileOperations.system
        let opening = operations.openContainer
        operations.openContainer = { url in
            let container = try opening(url)
            probe.container = container
            return container
        }
        var storeRef: SwiftDataGoalStore?
        operations.afterRowsDeleted = {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataGoalStore(url: url, fileOperations: operations)
        storeRef = store
        try autoreleasepool { try store.eraseAll() }
        XCTAssertNil(probe.container, "a closed store kept the container its erase opened, so the file stays open")
    }
}
