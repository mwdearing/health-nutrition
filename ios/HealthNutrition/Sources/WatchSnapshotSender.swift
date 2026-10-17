import Foundation

/// What survives a relaunch of the app about the Watch: the erase generation (it must only ever go up, because the
/// Watch drops anything below the highest it has seen) and whether the last erase has reached the Watch yet. Two
/// numbers, no figures.
protocol WatchSenderState: AnyObject, Sendable {
    var eraseGeneration: Int { get set }
    var eraseUnsent: Bool { get set }
}

/// Kept in the app's own defaults under keys of its own. Erase all data clears the stores it knows by key, never
/// these, so a generation never goes backwards.
final class UserDefaultsWatchSenderState: WatchSenderState, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let generationKey = "watchSnapshot.eraseGeneration"
    private static let unsentKey = "watchSnapshot.eraseUnsent"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var eraseGeneration: Int {
        get { defaults.integer(forKey: Self.generationKey) }
        set { defaults.set(newValue, forKey: Self.generationKey) }
    }

    var eraseUnsent: Bool {
        get { defaults.bool(forKey: Self.unsentKey) }
        set { defaults.set(newValue, forKey: Self.unsentKey) }
    }
}

/// Sends the Today summary to a paired Watch, and an empty one when the person's data is erased. The latest envelope
/// is kept and sent as soon as the transport is ready, so a summary or an erase that happens before the session is
/// active is not lost; an erase that has not reached the Watch is remembered across a relaunch and sent first.
/// Nothing is sent where there is no transport.
final class WatchSnapshotSender: @unchecked Sendable {
    static let shared = WatchSnapshotSender(
        transport: WatchSessionTransport.shared, state: UserDefaultsWatchSenderState())

    private let transport: WatchSnapshotTransport?
    private let state: WatchSenderState
    private let lock = NSLock()
    /// Held across a whole flush (read the held envelope, send it, clear it), so two flushes on different threads
    /// cannot send out of order and leave the Watch with an older context than the latest one submitted.
    private let sendLock = NSLock()
    private var pending: WatchSnapshotEnvelope?
    /// The newest erase this process has seen, in the same counter the publisher stamps its loads with.
    private var highestErasure = 0

    init(transport: WatchSnapshotTransport?, state: WatchSenderState = UserDefaultsWatchSenderState()) {
        self.transport = transport
        self.state = state
    }

    /// Sends the summary of a load announced under `erasureGeneration`, or holds it until the session is ready. A
    /// summary from before the newest erase is dropped here, under the same lock the erase takes, so it cannot slip
    /// in between the publisher's own check and this call.
    func submit(_ snapshot: WidgetSnapshot, erasureGeneration: Int) {
        lock.lock()
        guard erasureGeneration >= highestErasure else {
            lock.unlock()
            return
        }
        pending = WatchSnapshotEnvelope(eraseGeneration: state.eraseGeneration, snapshot: snapshot)
        lock.unlock()
        flush()
    }

    /// The erase: an empty envelope under a new, persisted generation replaces whatever the Watch was last sent, and
    /// is remembered until the Watch has been handed it.
    func erased(erasureGeneration: Int) {
        lock.lock()
        highestErasure = max(highestErasure, erasureGeneration)
        state.eraseGeneration += 1
        state.eraseUnsent = true
        pending = WatchSnapshotEnvelope(eraseGeneration: state.eraseGeneration, snapshot: nil)
        lock.unlock()
        flush()
    }

    /// At launch: an erase from an earlier run that never reached the Watch is queued again.
    func resumeAfterLaunch() {
        lock.lock()
        if state.eraseUnsent, pending == nil {
            pending = WatchSnapshotEnvelope(eraseGeneration: state.eraseGeneration, snapshot: nil)
        }
        lock.unlock()
        flush()
    }

    /// Called when the session becomes active or a Watch app is installed.
    func transportBecameReady() {
        flush()
    }

    private func flush() {
        guard let transport else { return }
        sendLock.lock()
        defer { sendLock.unlock() }
        guard transport.canSend else { return }
        lock.lock()
        let envelope = pending
        lock.unlock()
        guard let envelope, let context = try? envelope.context() else { return }
        do {
            try transport.send(context: context)
            lock.lock()
            // Only clear what was sent: a newer envelope submitted meanwhile stays held.
            if pending == envelope { pending = nil }
            if envelope.snapshot == nil, envelope.eraseGeneration == state.eraseGeneration { state.eraseUnsent = false }
            lock.unlock()
        } catch {
            // Kept for the next flush; the app does not depend on this send.
        }
    }
}
