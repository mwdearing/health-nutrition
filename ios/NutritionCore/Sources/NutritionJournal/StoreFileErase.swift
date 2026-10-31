import Foundation
import SwiftData

extension StoreFileOperations {
    /// The file steps of an erase for a store other than the journal, with the store's own container factory: the
    /// checkpoint and the removal are the journal store's (#228).
    static func systemOperations(opening open: @escaping (URL) throws -> ModelContainer) -> StoreFileOperations {
        StoreFileOperations(checkpoint: system.checkpoint, remove: system.remove, openContainer: open)
    }

    /// Deletes the store file at `url` with its write-ahead and shared-memory files, then opens an empty store there,
    /// the same steps the journal store's erase takes (#228).
    ///
    /// The write-ahead file is checkpointed into the store file first. The companions go before the main file and the
    /// removal stops at the first failure, so an erase that stops partway leaves a complete main file. The reopen is
    /// tried whatever happened before it. The result carries the reopened container, nil when the reopen failed, and
    /// the first error, which the caller throws: a failed step is never reported as a clean erase.
    func replaceStoreFiles(at url: URL) -> (container: ModelContainer?, error: Error?) {
        var firstError: Error?
        do {
            try checkpoint(url)
        } catch {
            firstError = error
        }
        for suffix in ["-shm", "-wal", ""] {
            if firstError != nil { break }
            let file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                try remove(file)
            } catch {
                firstError = error
            }
        }
        do {
            return (try openContainer(url), firstError)
        } catch {
            return (nil, firstError ?? error)
        }
    }
}
