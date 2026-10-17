import Foundation

/// The Watch's side of the summary: turns a context the phone sent into the file the Watch widgets read. Written
/// against plain values and closures (no WatchConnectivity, no WidgetKit) so the iPhone test bundle covers it.
///
/// - An envelope below the highest erase generation seen from the same phone install is ignored: it was sent
///   before an erase. A different install (a reinstall, a restored backup, another phone) starts the comparison again.
/// - An envelope with a summary is stored; one without (the erase) stores an empty day, which the widgets read as
///   "Nothing logged today".
/// - An unknown schema version, a malformed or an oversized payload removes the stored summary: the widgets then
///   show dashes. Nothing here can crash on what the phone sent.
final class WatchSnapshotReceiver {
    private let store: WidgetSnapshotStore?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let reload: () -> Void
    private static let highestGenerationKey = "watchReceiver.highestEraseGeneration"
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

    /// The highest erase generation applied so far for the phone install seen last, kept across launches so it only
    /// ever goes up while that install stays the same.
    var highestEraseGeneration: Int { defaults.integer(forKey: Self.highestGenerationKey) }

    func receive(context: [String: Any]) {
        guard let store else { return }
        lock.lock()
        defer { lock.unlock() }
        switch WatchSnapshotEnvelope.decode(context: context) {
        case .envelope(let envelope):
            // The generation is only comparable within one install of the phone app. A different epoch (a reinstall,
            // a restored backup, another phone) is a restart: it is accepted and its own counter is followed from
            // here, never dropped as "older". Only the phone's most recent context is ever delivered, so no stale
            // install's envelope arrives after a newer one.
            let epoch = envelope.epoch ?? Self.unnamedEpoch
            if epoch != (defaults.string(forKey: Self.epochKey) ?? Self.unnamedEpoch) {
                defaults.set(epoch, forKey: Self.epochKey)
                defaults.set(0, forKey: Self.highestGenerationKey)
            }
            // Sent before an erase: nothing changes, so nothing is reloaded.
            guard envelope.eraseGeneration >= highestEraseGeneration else { return }
            defaults.set(envelope.eraseGeneration, forKey: Self.highestGenerationKey)
            let snapshot = envelope.snapshot ?? WidgetSnapshot.empty(at: now())
            do {
                try store.write(snapshot)
            } catch {
                // A summary that cannot be stored must not leave an older one behind.
                try? store.erase()
            }
            reload()
        case .unsupportedSchema, .invalid:
            // What cannot be read cannot be ordered, so it fails closed: the stored summary is removed and the
            // widgets show dashes, which is never a stale figure.
            try? store.erase()
            reload()
        }
    }
}
