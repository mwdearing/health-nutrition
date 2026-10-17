import Foundation

/// The Watch's side of the summary: turns a context the phone sent into the file the Watch widgets read. Written
/// against plain values and closures (no WatchConnectivity, no WidgetKit) so the iPhone test bundle covers it.
///
/// - An envelope below the highest erase generation seen (within the same phone install) is ignored: it was sent
///   before an erase.
/// - An envelope with a summary is stored; one without (the erase) stores an empty day, which the widgets read as
///   "Nothing logged today".
/// - An unknown schema version, a malformed or an oversized payload removes the stored summary: the widgets then
///   show dashes. Nothing here can crash on what the phone sent.
final class WatchSnapshotReceiver {
    private let store: WidgetSnapshotStore?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let reload: () -> Void
    private static let highestGenerationPrefix = "watchReceiver.highestEraseGeneration."
    private static let epochKey = "watchReceiver.epoch"
    /// Stands in for the epoch of an envelope that carries none (a phone build from before epochs).
    private static let unnamedEpoch = "unnamed"
    /// The session delegate and the app's start-up both reach the receiver; one context is applied at a time.
    private let lock = NSLock()

    init(
        store: WidgetSnapshotStore?, defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
        reload: @escaping () -> Void
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.reload = reload
    }

    /// The epoch of the phone install whose envelope was applied last.
    private var currentEpoch: String { defaults.string(forKey: Self.epochKey) ?? Self.unnamedEpoch }

    private func highest(in epoch: String) -> Int { defaults.integer(forKey: Self.highestGenerationPrefix + epoch) }

    /// The highest erase generation applied so far for the phone install seen last, kept across launches so it only
    /// ever goes up. Kept per install, so a late envelope from an older install cannot reopen the newer one's guard.
    var highestEraseGeneration: Int { highest(in: currentEpoch) }

    func receive(context: [String: Any]) {
        guard let store else { return }
        lock.lock()
        defer { lock.unlock() }
        switch WatchSnapshotEnvelope.decode(context: context) {
        case .envelope(let envelope):
            // The generation is only comparable within one install of the phone app, so it is kept per epoch: a new
            // epoch (a reinstall or another phone) starts at zero instead of being dropped as "older", and a late
            // envelope from an older install is judged against that install's own mark.
            let epoch = envelope.epoch ?? Self.unnamedEpoch
            // Sent before an erase: nothing changes, so nothing is reloaded.
            guard envelope.eraseGeneration >= highest(in: epoch) else { return }
            defaults.set(epoch, forKey: Self.epochKey)
            defaults.set(envelope.eraseGeneration, forKey: Self.highestGenerationPrefix + epoch)
            let snapshot = envelope.snapshot ?? WidgetSnapshot.empty(at: now())
            do {
                try store.write(snapshot)
            } catch {
                // A summary that cannot be stored must not leave an older one behind.
                try? store.erase()
            }
            reload()
        case .unsupportedSchema, .invalid:
            try? store.erase()
            reload()
        }
    }
}
