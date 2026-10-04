import Foundation

/// A store that can remove everything it holds from the device.
///
/// The Connections and privacy screen holds one of these per store file and runs them all for the
/// "Erase all data" action, so a store that can be emptied on its own conforms here rather than the
/// screen knowing what each store's rows are called.
///
/// Two promises every conforming store keeps:
///
/// - The erase is all or nothing within one store. It commits in a single save, so a failure leaves
///   the store exactly as it was; a half-erased store is worse than an unerased one, because the
///   person cannot tell which half is gone.
/// - The store stays open. Erasing is not closing: afterwards the store still reads and still accepts
///   writes, so the app carries on with an empty journal instead of a broken one.
///
/// Erasing never reaches anything outside the device. A store that has already written to another
/// system removes what it wrote there itself; see `docs/erase-all-data.md`.
public protocol JournalErasing: AnyObject, Sendable {
    /// Removes every record this store holds.
    ///
    /// Throws the store's own error for a store that is closed, because a closed store has nothing
    /// left to erase and must not report success it did not achieve.
    func eraseAll() throws
}