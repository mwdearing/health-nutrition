import Foundation
import XCTest
@testable import NutritionJournal

/// The erase's hold on the delivery gate (#841): a wait with any timeout, however odd, waits rather than traps.
final class DeliveryRunGateTests: XCTestCase {
    /// An infinite, NaN or huge timeout is clamped, so the timer behind the wait cannot trap converting it. The pass
    /// ends shortly after the wait begins, so the pause takes the gate.
    func testAPauseWithAnInfiniteNaNOrHugeTimeoutWaitsInsteadOfTrapping() async {
        for timeout in [TimeInterval.infinity, .nan, 1e300] {
            let gate = DeliveryRunGate()
            await gate.enter() // a delivery pass is running
            let pause = Task { await gate.pause(upTo: timeout) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            await gate.leave()
            let paused = await pause.value
            XCTAssertTrue(paused, "the pause with timeout \(timeout) takes the gate once the pass ends")
            await gate.resumeAfterPause()
        }
    }
}
