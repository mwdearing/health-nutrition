import Foundation

/// What the app knows about camera access, read from the system by the app target.
public enum CameraAccessState: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

/// What a camera sheet says when the camera cannot start. Access that is off gets its own message and a way to
/// the Settings app; any other failure keeps the message the sheets already showed.
public enum CameraAccessNotice {
    public static let accessOffMessage = "Camera access is off. Turn it on in Settings to scan."
    public static let startFailureMessage = "The camera could not be started. Type the digits instead."
    public static let openSettingsTitle = "Open Settings"

    /// The message for a camera that did not start, given what the system says about access.
    public static func failureMessage(for access: CameraAccessState) -> String {
        switch access {
        case .denied, .restricted:
            return accessOffMessage
        case .authorized, .notDetermined:
            return startFailureMessage
        }
    }

    /// Whether the failure should offer the Settings button: only when access is actually off.
    public static func offersOpenSettings(for access: CameraAccessState) -> Bool {
        access == .denied || access == .restricted
    }
}
