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
actor DeliveryRunGate {
    private var isRunning = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Returns once no other run holds the gate. Every `enter()` is followed by exactly one `leave()`.
    func enter() async {
        guard isRunning else {
            isRunning = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate to the next waiting run, or opens it when none is waiting.
    func leave() {
        if waiting.isEmpty {
            isRunning = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
