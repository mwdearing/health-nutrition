import Foundation
import XCTest
@testable import NutritionJournal

/// The erase's hold on the delivery gate (#841, #984).
final class DeliveryRunGateTests: XCTestCase {
    /// Any timeout, however odd, becomes a wait of 0 through an hour, so the timer's conversion cannot trap.
    func testTheTimeoutIsClampedSoNoValueTraps() {
        XCTAssertEqual(DeliveryRunGate.boundedNanoseconds(.infinity), 3_600_000_000_000)
        XCTAssertEqual(DeliveryRunGate.boundedNanoseconds(.nan), 3_600_000_000_000)
        XCTAssertEqual(DeliveryRunGate.boundedNanoseconds(1e300), 3_600_000_000_000)
        XCTAssertEqual(DeliveryRunGate.boundedNanoseconds(-.infinity), 0, "negative infinity waits not at all")
        XCTAssertEqual(DeliveryRunGate.boundedNanoseconds(-5), 0)
        XCTAssertEqual(DeliveryRunGate.boundedNanoseconds(2), 2_000_000_000)
    }

    /// A pause that timed out has no hold, so releasing it does nothing to the run that still has the gate.
    func testAReleaseAfterATimedOutPauseLeavesTheRunningPassHoldingTheGate() async {
        let gate = DeliveryRunGate()
        await gate.enter() // a delivery pass is running
        let timedOut = await gate.pause(upTo: 0.05)
        XCTAssertNil(timedOut)
        await gate.resume(timedOut)
        let probe = await gate.pause(upTo: 0.05)
        XCTAssertNil(probe, "the pass still has the gate")
        await gate.leave()
    }

    /// Only the hold that has the gate releases it: an old hold released again cannot let go of a newer one.
    func testAStaleHoldCannotReleaseANewerHold() async {
        let gate = DeliveryRunGate()
        let first = await gate.pause(upTo: 0.5)
        XCTAssertNotNil(first)
        await gate.resume(first)
        let second = await gate.pause(upTo: 0.5)
        XCTAssertNotNil(second)
        await gate.resume(first) // released already; must not release `second`
        let probe = await gate.pause(upTo: 0.05)
        XCTAssertNil(probe, "the newer hold still has the gate")
        await gate.resume(second)
        let free = await gate.pause(upTo: 0.5)
        XCTAssertNotNil(free, "the gate is free once its own holder lets go")
        await gate.resume(free)
    }
}
