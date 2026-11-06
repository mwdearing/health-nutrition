import Foundation

/// The body of the Watch's Watch Connectivity background task, written against plain values and closures (no
/// WatchConnectivity) so the iPhone test bundle covers it. The system keeps the app awake until the task returns, so
/// it returns only once the pending context has been applied and the session reports nothing more waiting.
enum WatchConnectivityRefresh {
    /// How many times to look for more pending content before returning anyway, so a task never holds the app open
    /// indefinitely.
    static let defaultMaxChecks = 20

    /// Applies the session's latest context through `receiver` (which stores it and reloads the timelines), and, while
    /// `hasContentPending` says more is queued, waits with `pause` and applies the latest context again, up to
    /// `maxChecks` waits.
    /// An empty context is not applied: it is what a session reports before the phone has sent anything, and it must not
    /// clear a stored summary.
    static func run(
        receiver: WatchSnapshotReceiver, context: () -> [String: Any], hasContentPending: () -> Bool,
        pause: () async -> Void, maxChecks: Int = defaultMaxChecks
    ) async {
        var waits = 0
        while true {
            // Asked before the context is read, so anything that arrived by then is applied by this pass.
            let pending = hasContentPending()
            // Read and applied under the receiver's lock, so a newer context the delegate delivers in between is
            // never overwritten by this older read.
            receiver.receive(contextFrom: context)
            // A canceled task (the system is ending it) stops after the apply it just did.
            guard pending, waits < maxChecks, !Task.isCancelled else { return }
            waits += 1
            await pause()
        }
    }

    static func apply(_ context: [String: Any], through receiver: WatchSnapshotReceiver) {
        guard !context.isEmpty else { return }
        receiver.receive(context: context)
    }
}
