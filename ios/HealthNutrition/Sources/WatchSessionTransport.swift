import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity

/// The phone's side of WatchConnectivity: activates the session and replaces the application context. Device to
/// device only; no server and no package.
final class WatchSessionTransport: NSObject, WatchSnapshotTransport, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSessionTransport()

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    /// Told when the session becomes active or the Watch app is installed, so a held envelope is sent.
    var onReady: (@Sendable () -> Void)?

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    var canSend: Bool {
        guard let session else { return false }
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func send(context: [String: Any]) throws {
        guard let session else { return }
        try session.updateApplicationContext(context)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { onReady?() }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        onReady?()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A new Watch was paired: activate again for it.
        session.activate()
    }
}
#else
/// Platforms without WatchConnectivity send nothing.
final class WatchSessionTransport: WatchSnapshotTransport, @unchecked Sendable {
    static let shared = WatchSessionTransport()
    var onReady: (@Sendable () -> Void)?
    func activate() {}
    var canSend: Bool { false }
    func send(context: [String: Any]) throws {}
}
#endif
