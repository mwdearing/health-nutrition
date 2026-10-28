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

    /// A pause on a gate that should be free. A free gate answers without scheduling a timeout; if this pause has to
    /// wait instead, its timeout is fired so it answers nil and the caller's assertion fails rather than hanging.
    private func pauseOnAFreeGate(_ gate: DeliveryRunGate, _ timer: ManualTimer) async -> DeliveryRunGate.PauseHold? {
        let attempt = Task { await gate.pause(upTo: 1) }
        if await timer.untilArmed(within: 1) { await timer.fire() }
        guard let outcome = await finished(attempt) else {
            XCTFail("a pause on a free gate did not answer")
            return nil
        }
        return outcome
    }

    /// A pause handed the gate before its timeout fires keeps the gate, and the late timeout changes nothing: the
    /// waiter was removed at the handoff, so it is never answered twice (#1001). A manual timer sets the order.
    func testATimeoutThatFiresAfterTheHandoffChangesNothing() async {
        let timer = ManualTimer()
        let gate = DeliveryRunGate(schedule: timer.schedule)
        await gate.enter() // a delivery pass is running
        let pauser = Task { await gate.pause(upTo: 1) }
        guard await timer.untilArmed() else { return XCTFail("the pause did not start waiting") }
        await gate.leave() // the pass ends and hands the gate to the waiting pause
        guard let outcome = await finished(pauser) else { return XCTFail("the pause never answered") }
        let hold = outcome
        XCTAssertNotNil(hold, "the pause got the gate at the handoff")
        await timer.fire() // the timeout runs late, after the handoff
        // A second pause now has to wait, because the handed-off pause still has the gate; its own timeout answers nil.
        let probe = Task { await gate.pause(upTo: 1) }
        guard await timer.untilArmed() else { return XCTFail("the pause did not start waiting") }
        await timer.fire()
        guard let probeOutcome = await finished(probe) else { return XCTFail("the probe pause never answered") }
        let probeHold = probeOutcome
        XCTAssertNil(probeHold, "the handed-off pause still has the gate")
        await gate.resume(hold)
        let free = await pauseOnAFreeGate(gate, timer)
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
        guard await timer.untilArmed() else { return XCTFail("the pause did not start waiting") }
        await timer.fire()
        guard let outcome = await finished(pauser) else { return XCTFail("the pause never answered") }
        let hold = outcome
        XCTAssertNil(hold, "the pause timed out")
        await gate.leave()
        let free = await pauseOnAFreeGate(gate, timer)
        XCTAssertNotNil(free, "the gate opened, not handed to the dropped pause")
        await gate.resume(free)
    }
}

/// A timer the test fires by hand. `untilArmed` reports once a pause has scheduled its timeout, and `fire` runs that
/// timeout to the end before it returns, so the order of a timeout and a handoff is exact. Every wait is bounded, so a
/// broken gate fails the test instead of hanging the run.
private actor ManualTimer {
    private var action: (@Sendable () async -> Void)?

    nonisolated var schedule: DeliveryRunGate.Schedule {
        { _, action in Task { await self.arm(action) } }
    }

    private func arm(_ action: @escaping @Sendable () async -> Void) { self.action = action }

    var isArmed: Bool { action != nil }

    /// True once a timeout is scheduled, polling for at most `seconds`.
    func untilArmed(within seconds: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while action == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return action != nil
    }

    func fire() async {
        let pending = action
        action = nil
        await pending?()
    }
}

/// The value of `task`, or nil when it has not finished within `seconds`, so a broken gate fails the waiting assertion
/// instead of hanging the run. A task that never finishes is left behind; the test has already failed by then.
private func finished<T: Sendable>(_ task: Task<T, Never>, within seconds: TimeInterval = 5) async -> T? {
    let once = ResumeOnce<T?>()
    return await withCheckedContinuation { continuation in
        Task { once.resume(continuation, with: await task.value) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.resume(continuation, with: nil)
        }
    }
}

/// Resumes a continuation at most once, for whichever of two racing tasks gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resume(_ continuation: CheckedContinuation<T, Never>, with value: T) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { continuation.resume(returning: value) }
    }
}
