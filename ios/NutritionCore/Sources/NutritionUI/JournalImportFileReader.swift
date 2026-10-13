import Foundation
import NutritionJournal

/// Reads a selected journal export without ever buffering more than its import byte limit plus one byte.
public enum JournalImportFileReader {
    private static let chunkSize = 64 * 1024

    public static func read(_ url: URL, limits: JournalImportLimits) throws -> Data {
        try read(url, limits: limits, metadataSize: Self.fileSize, chunkSize: Self.chunkSize,
                 isCancelled: { Task.isCancelled })
    }

    public static func readScoped(_ url: URL, limits: JournalImportLimits) throws -> Data {
        #if os(macOS) || os(iOS)
        try withSecurityScopedAccess(
            startAccessing: { url.startAccessingSecurityScopedResource() },
            stopAccessing: { url.stopAccessingSecurityScopedResource() }
        ) {
            try read(url, limits: limits)
        }
        #else
        try read(url, limits: limits)
        #endif
    }

    static func withSecurityScopedAccess<T>(
        startAccessing: () -> Bool,
        stopAccessing: () -> Void,
        operation: () throws -> T
    ) rethrows -> T {
        let accessed = startAccessing()
        defer { if accessed { stopAccessing() } }
        return try operation()
    }

    /// Internal seams keep metadata and cancellation failure paths deterministic in tests.
    static func read(
        _ url: URL,
        limits: JournalImportLimits,
        metadataSize: (URL) -> Int?,
        chunkSize: Int = Self.chunkSize,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        precondition(chunkSize > 0)
        if isCancelled() { throw CancellationError() }
        if let size = metadataSize(url), size > limits.maxImportBytes {
            throw JournalImportError.tooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = Data()
        while true {
            if isCancelled() { throw CancellationError() }

            let remaining = limits.maxImportBytes - result.count
            let allowance = remaining < chunkSize ? remaining + 1 : chunkSize
            guard let chunk = try handle.read(upToCount: allowance), !chunk.isEmpty else {
                return result
            }
            result.append(chunk)
            if result.count > limits.maxImportBytes {
                throw JournalImportError.tooLarge
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}
