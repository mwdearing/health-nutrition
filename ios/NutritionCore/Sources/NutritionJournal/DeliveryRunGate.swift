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
    private var isRunning = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    /// True while an erase holds the gate through `pause(upTo:)`, so `resumeAfterPause()` releases only a hold it has.
    private var heldByPause = false

    public init() {}

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

    /// Takes the gate for an erase, waiting at most `seconds` for a run that holds it. Returns false, holding
    /// nothing, when the run is still going then: the erase touches nothing and the run is not cancelled, because
    /// a HealthKit write stopped halfway would leave the ledger out of step with Health.
    public func pause(upTo seconds: TimeInterval) async -> Bool {
        let entered: Bool
        if !isRunning {
            isRunning = true
            entered = true
        } else {
            let id = UUID()
            entered = await withCheckedContinuation { continuation in
                waiting.append((id, continuation))
                Task { [weak self] in
                    // Clamped to an hour, so an infinite, NaN or huge wait cannot trap the conversion.
                    let bounded = seconds.isFinite ? min(max(seconds, 0), 3600) : 3600
                    try? await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
                    await self?.expire(id)
                }
            }
        }
        if entered { heldByPause = true }
        return entered
    }

    /// Releases the erase's hold. Safe to call on every exit: after a pause that timed out it does nothing.
    public func resumeAfterPause() {
        guard heldByPause else { return }
        heldByPause = false
        leave()
    }

    /// A waiter whose time ran out is answered false and dropped, unless the gate already reached it.
    private func expire(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}
