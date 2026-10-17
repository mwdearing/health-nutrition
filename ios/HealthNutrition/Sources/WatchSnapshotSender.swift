import Foundation

/// Sends the Today summary to a paired Watch, and an empty one when the person's data is erased. The latest envelope
/// is kept and sent as soon as the transport is ready, so a summary or an erase that happens before the session is
/// active is not lost. Nothing is sent where there is no transport.
final class WatchSnapshotSender: @unchecked Sendable {
    static let shared = WatchSnapshotSender(transport: WatchSessionTransport.shared)

    private let transport: WatchSnapshotTransport?
    private let lock = NSLock()
    private var pending: WatchSnapshotEnvelope?

    init(transport: WatchSnapshotTransport?) {
        self.transport = transport
    }

    /// Sends `envelope`, or holds it until `transportBecameReady()` if the session cannot send yet. An envelope
    /// from before the latest erase never replaces one from after it.
    func submit(_ envelope: WatchSnapshotEnvelope) {
        lock.lock()
        if let held = pending, held.eraseGeneration > envelope.eraseGeneration {
            lock.unlock()
            return
        }
        pending = envelope
        lock.unlock()
        flush()
    }

    /// The erase: an empty envelope under the new generation replaces whatever the Watch was last sent.
    func erased(generation: Int) {
        submit(WatchSnapshotEnvelope(eraseGeneration: generation, snapshot: nil))
    }

    /// Called when the session becomes active or a Watch app is installed.
    func transportBecameReady() {
        flush()
    }

    private func flush() {
        guard let transport, transport.canSend else { return }
        lock.lock()
        let envelope = pending
        lock.unlock()
        guard let envelope, let context = try? envelope.context() else { return }
        do {
            try transport.send(context: context)
            lock.lock()
            // Only clear what was sent: a newer envelope submitted meanwhile stays held.
            if pending == envelope { pending = nil }
            lock.unlock()
        } catch {
            // Kept for the next flush; the app does not depend on this send.
        }
    }
}
