import Foundation

/// What a tap on a library row does. Pick mode (Add's "From Library") opens the details form, and
/// nothing is logged there. Elsewhere a tap logs once, with Undo.
public enum LibraryRowTap: Equatable {
    case openDetails
    case logOnce

    public static func forRow(pickMode: Bool) -> LibraryRowTap {
        pickMode ? .openDetails : .logOnce
    }

    /// The long-press menu and the VoiceOver "Details" action appear only where a tap logs at once,
    /// and only when the screen can open details.
    public static func offersDetails(pickMode: Bool, hasOpenHandler: Bool) -> Bool {
        !pickMode && hasOpenHandler
    }
}
