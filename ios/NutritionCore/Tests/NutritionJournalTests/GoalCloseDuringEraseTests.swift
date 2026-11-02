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
}
