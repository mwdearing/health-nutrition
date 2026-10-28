import Foundation

/// Lets one delivery run at a time through a worker, and queues the rest in arrival order.
///
/// **A run reads the queue once and acts on what it read**, so two runs that overlap act on the same
/// operations: both write the same revision, and a run still waiting on an earlier write can land it after
/// the other run has already retracted the intake's samples, which puts deleted samples back
/// (health-nutrition #120). A later run waits rather than being dropped, because whatever triggered it may
/// have queued work the running pass did not see.
///
/// The workers are value types, so the gate is a reference every copy of a worker shares.
///
/// Erase all data holds the same gate for as long as it runs (#841): a pass that is writing finishes first,
/// and a pass that arrives during the erase waits behind it, so no pass is between its busy check and its
/// Health write while the stores are emptied.
public actor DeliveryRunGate {
    /// A hold on the gate taken by `pause(upTo:)`. Only the hold that currently has the gate can release it, so a
    /// caller whose wait timed out, or that releases twice, can never let go of someone else's hold (#984).
    public struct PauseHold: Sendable, Equatable {
        fileprivate let id: UUID
    }

    private var isRunning = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    /// The pause that holds the gate right now, or nil when a delivery run holds it or nothing does.
    private var currentPause: PauseHold?

    /// Runs `action` once `nanoseconds` have passed: the pause's timeout. Tests pass their own, to fire a timeout at an
    /// exact point instead of racing a real clock.
    typealias Schedule = @Sendable (_ nanoseconds: UInt64, _ action: @escaping @Sendable () async -> Void) -> Void
    private let schedule: Schedule

    public init() {
        self.init(schedule: { nanoseconds, action in
            Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                await action()
            }
        })
    }

    init(schedule: @escaping Schedule) {
        self.schedule = schedule
    }

    /// The timer's wait for `seconds`, in nanoseconds: clamped to 0 through an hour, so an infinite, NaN or huge
    /// timeout cannot trap the conversion. Negative values, negative infinity included, wait not at all; NaN and
    /// positive infinity wait the full hour.
    static func boundedNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let bounded: TimeInterval
        if seconds.isNaN || seconds == .infinity {
            bounded = 3600
        } else {
            bounded = min(max(seconds, 0), 3600)
        }
        return UInt64(bounded * 1_000_000_000)
    }

    /// Returns once no other run holds the gate. Every `enter()` is followed by exactly one `leave()`.
    func enter() async {
        guard isRunning else {
            isRunning = true
            return
        }
        _ = await withCheckedContinuation { continuation in
            waiting.append((UUID(), continuation))
        }
    }

    /// Hands the gate to the next waiting run, or opens it when none is waiting.
    func leave() {
        if waiting.isEmpty {
            isRunning = false
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Takes the gate for an erase, waiting at most `seconds` for a run that holds it. Returns nil, holding
    /// nothing, when the run is still going then: the erase touches nothing and the run is not cancelled, because
    /// a HealthKit write stopped halfway would leave the ledger out of step with Health.
    public func pause(upTo seconds: TimeInterval) async -> PauseHold? {
        let entered: Bool
        if !isRunning {
            isRunning = true
            entered = true
        } else {
            let id = UUID()
            entered = await withCheckedContinuation { continuation in
                waiting.append((id, continuation))
                schedule(Self.boundedNanoseconds(seconds)) { [weak self] in await self?.expire(id) }
            }
        }
        guard entered else { return nil }
        let hold = PauseHold(id: UUID())
        currentPause = hold
        return hold
    }

    /// Releases `hold` when it is the hold that has the gate. Safe to call on every exit: nil (a pause that timed
    /// out), a hold already released, or any other caller's hold does nothing.
    public func resume(_ hold: PauseHold?) {
        guard let hold, hold == currentPause else { return }
        currentPause = nil
        leave()
    }

    /// A waiter whose time ran out is answered false and dropped, unless the gate already reached it.
    private func expire(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}
