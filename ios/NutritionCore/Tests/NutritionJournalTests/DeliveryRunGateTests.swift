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

    /// A pause handed the gate before its timeout fires keeps the gate, and the late timeout changes nothing: the
    /// waiter was removed at the handoff, so it is never answered twice (#1001). A manual timer sets the order.
    func testATimeoutThatFiresAfterTheHandoffChangesNothing() async {
        let timer = ManualTimer()
        let gate = DeliveryRunGate(schedule: timer.schedule)
        await gate.enter() // a delivery pass is running
        let pauser = Task { await gate.pause(upTo: 1) }
        await timer.untilArmed()
        await gate.leave() // the pass ends and hands the gate to the waiting pause
        let hold = await pauser.value
        XCTAssertNotNil(hold, "the pause got the gate at the handoff")
        await timer.fire() // the timeout runs late, after the handoff
        // A second pause now has to wait, because the handed-off pause still has the gate; its own timeout answers nil.
        let probe = Task { await gate.pause(upTo: 1) }
        await timer.untilArmed()
        await timer.fire()
        let probeHold = await probe.value
        XCTAssertNil(probeHold, "the handed-off pause still has the gate")
        await gate.resume(hold)
        let free = await gate.pause(upTo: 0)
        XCTAssertNotNil(free, "the gate is free once that pause lets go")
        await gate.resume(free)
    }

    /// A pause whose timeout fires first is answered nil and dropped; the pass that ends later then opens the gate
    /// instead of handing it to the dropped pause (#1001).
    func testATimeoutThatFiresBeforeTheHandoffDropsThePause() async {
        let timer = ManualTimer()
        let gate = DeliveryRunGate(schedule: timer.schedule)
        await gate.enter()
        let pauser = Task { await gate.pause(upTo: 1) }
        await timer.untilArmed()
        await timer.fire()
        let hold = await pauser.value
        XCTAssertNil(hold, "the pause timed out")
        await gate.leave()
        let free = await gate.pause(upTo: 0)
        XCTAssertNotNil(free, "the gate opened, not handed to the dropped pause")
        await gate.resume(free)
    }
}

/// A timer the test fires by hand. `untilArmed` returns once a pause has scheduled its timeout, and `fire` runs that
/// timeout to the end before it returns, so the order of a timeout and a handoff is exact.
private actor ManualTimer {
    private var action: (@Sendable () async -> Void)?
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var schedule: DeliveryRunGate.Schedule {
        { _, action in Task { await self.arm(action) } }
    }

    private func arm(_ action: @escaping @Sendable () async -> Void) {
        self.action = action
        for waiter in armedWaiters { waiter.resume() }
        armedWaiters = []
    }

    func untilArmed() async {
        if action != nil { return }
        await withCheckedContinuation { armedWaiters.append($0) }
    }

    func fire() async {
        let pending = action
        action = nil
        await pending?()
    }
}
