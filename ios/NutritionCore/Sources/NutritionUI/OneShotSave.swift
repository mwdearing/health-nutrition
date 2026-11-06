import Foundation

/// Lets a sheet's Save run once. `begin()` is called before the write: it returns false while a save is under
/// way or already done, so a second tap during the dismissal writes nothing. `finish(success:)` keeps the lock
/// after a save and releases it after a failure, so the person can try again. A re-opened sheet makes a new one.
struct OneShotSave: Equatable {
    /// True from `begin()` until a failed `finish`, and for good after a successful one.
    private(set) var isLocked = false

    /// Takes the lock. False when it is already held, in which case the caller does nothing.
    mutating func begin() -> Bool {
        guard !isLocked else { return false }
        isLocked = true
        return true
    }

    /// Ends the attempt: a success stays locked, a failure unlocks for a retry.
    mutating func finish(success: Bool) {
        if !success { isLocked = false }
    }
}
