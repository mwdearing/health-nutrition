import Foundation

/// What the app knows about camera access, read from the system by the app target.
public enum CameraAccessState: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

/// Which camera sheet is asking, so each keeps its own fallback: the barcode sheet can be typed in, the label
/// sheet's values are read from the photo and have no digits to type.
public enum CameraSheet: Sendable, Equatable {
    case barcode
    case label
}

/// What a camera sheet says when the camera cannot start. Access that is off says so and points to Settings; a
/// sheet that can be typed into also says that. Other failures keep each sheet's own fallback message.
public enum CameraAccessNotice {
    public static let barcodeAccessOffMessage = "Camera access is off. Turn it on in Settings to scan, or type the digits instead."
    public static let labelAccessOffMessage = "Camera access is off. Turn it on in Settings to scan."
    public static let barcodeStartFailureMessage = "The camera could not be started. Type the digits instead."
    public static let labelStartFailureMessage = "The camera could not be started. Type the values in instead."
    public static let openSettingsTitle = "Open Settings"
    public static let openSettingsHint = "Opens Settings to turn on camera access"

    /// The message for a camera that did not start, given what the system says about access and which sheet asks.
    public static func failureMessage(for access: CameraAccessState, sheet: CameraSheet) -> String {
        switch access {
        case .denied, .restricted:
            return sheet == .barcode ? barcodeAccessOffMessage : labelAccessOffMessage
        case .authorized, .notDetermined:
            return sheet == .barcode ? barcodeStartFailureMessage : labelStartFailureMessage
        }
    }

    /// Whether the failure should offer the Settings button: only when access is actually off.
    public static func offersOpenSettings(for access: CameraAccessState) -> Bool {
        access == .denied || access == .restricted
    }
}
