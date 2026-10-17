import Foundation

/// The Watch's side of the summary: turns a context the phone sent into the file the Watch widgets read. Written
/// against plain values and closures (no WatchConnectivity, no WidgetKit) so the iPhone test bundle covers it.
///
/// - An envelope below the highest erase generation seen is ignored: it was sent before an erase.
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

    init(
        store: WidgetSnapshotStore?, defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
        reload: @escaping () -> Void
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.reload = reload
    }

    /// The highest erase generation applied so far, kept across launches so it only ever goes up.
    var highestEraseGeneration: Int { defaults.integer(forKey: Self.highestGenerationKey) }

    func receive(context: [String: Any]) {
        guard let store else { return }
        defer { reload() }
        switch WatchSnapshotEnvelope.decode(context: context) {
        case .envelope(let envelope):
            guard envelope.eraseGeneration >= highestEraseGeneration else { return }
            defaults.set(envelope.eraseGeneration, forKey: Self.highestGenerationKey)
            let snapshot = envelope.snapshot ?? WidgetSnapshot.empty(at: now())
            do {
                try store.write(snapshot)
            } catch {
                // A summary that cannot be stored must not leave an older one behind.
                try? store.erase()
            }
        case .unsupportedSchema, .invalid:
            try? store.erase()
        }
    }
}
