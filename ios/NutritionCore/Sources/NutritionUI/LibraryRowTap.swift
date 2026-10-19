import Foundation

/// What a tap on a library row does. Every row opens its details form, in every place it appears: the row never
/// logs by itself. Logging is the row's own "Log" control, which logs once with Undo (#503).
public enum LibraryRowTap: Equatable {
    case openDetails

    public static func forRow(pickMode: Bool) -> LibraryRowTap {
        .openDetails
    }
}
