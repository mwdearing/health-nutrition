import Foundation
import NutritionJournal

/// One external connection. Apple Health and HealthRelay are shown from the start but cannot be switched on
/// yet: they are listed so the shape of the feature is clear, not to imply that data already leaves the device.
public struct ConnectionsPrivacyConnection: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// False for both connections until their work package ships.
    public var isAvailable: Bool
    /// The switch position the screen shows. Always off while the connection is unavailable.
    public var isEnabled: Bool
    public var arrivingNote: String
}

/// How the export is written to disk. Injected so a test can see the options that were asked for, which it
/// cannot learn from the file afterwards: the write options decide how the file is protected, and the
/// resulting attribute on a given platform does not say what was requested.
public typealias ConnectionsPrivacyExportWriter = (
    _ data: Data, _ url: URL, _ options: Data.WritingOptions
) throws -> Void

/// State of the export action on the screen.
public enum ConnectionsPrivacyExportState: Equatable {
    case idle
    /// The export was made and the file is ready to share.
    case ready
    /// The export failed; `errorMessage` says so.
    case failed
}

/// State of the import action on the screen.
public enum ConnectionsPrivacyImportState: Equatable {
    case idle
    /// The file was restored; `importMessage` says what came back.
    case imported
    /// The file was refused or the restore failed; `importMessage` says so.
    case failed
}

/// Backs the Connections and privacy screen. It reads the local stores and produces the export file; it never
/// sends anything anywhere. Sharing happens only when the person taps the share control.
@MainActor
public final class ConnectionsPrivacyViewModel: ObservableObject {
    public static let appleHealthTitle = "Apple Health"
    public static let healthRelayTitle = "HealthRelay"
    public static let arrivingNote = "This connection arrives in a later release. It cannot be switched on yet."
    public static let privacySummary = """
        Your journal stays on this device. Nothing is uploaded and nothing is sent to Apple or to a server \
        unless you ask for it. The export below is the only way data leaves this screen, and only because you \
        tap it: it writes a JSON copy into a temporary file that the system share sheet can hand to an app you \
        choose.
        """
    public static let exportButtonTitle = "Export journal"
    public static let shareButtonTitle = "Share the export"
    public static let exportFailedMessage = "Could not export the journal."
    public static let importButtonTitle = "Import a journal export"
    public static let importFailedMessage = "Could not import that file."
    /// What the importer refused and why, in the words a person can act on.
    public static let importUnsupportedVersionMessage =
        "That file was made by a newer version of the app, so this one cannot read it."
    public static let importNotEmptyMessage =
        "This phone already has journal entries. An import only works on a journal that is empty."
    public static let unavailableVersion = "unknown"
    /// Fixed until the app target exists and can inject its real version string.
    public static let defaultAppVersion = "0.0.0-development"

    /// Both connections are listed but not usable in this release.
    public static let appleHealthAvailable = false
    public static let healthRelayAvailable = false

    @Published public private(set) var exportState: ConnectionsPrivacyExportState = .idle
    @Published public private(set) var exportFileURL: URL?
    @Published public private(set) var exportFileName: String?
    @Published public private(set) var entryCount = 0
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var importState: ConnectionsPrivacyImportState = .idle
    @Published public private(set) var importSummary: JournalImportSummary?
    @Published public private(set) var importMessage: String?
    /// Switch positions of the two connections. They stay off because the toggles are disabled.
    @Published public var appleHealthEnabled = false
    @Published public var healthRelayEnabled = false

    private let store: JournalStore
    private let favorites: FavoritesStore?
    private let appVersion: String
    private let writer: ConnectionsPrivacyExportWriter

    /// The write options the export always asks for: complete-only, so the journal is unreadable while the
    /// device is locked, and atomic, so no half-written copy can be shared.
    public static let exportWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    /// The real write. Replacing it is only for tests.
    public static func writeExport(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }

    public init(
        store: JournalStore, favorites: FavoritesStore? = nil,
        appVersion: String = ConnectionsPrivacyViewModel.defaultAppVersion,
        writer: @escaping ConnectionsPrivacyExportWriter = ConnectionsPrivacyViewModel.writeExport
    ) {
        self.store = store
        self.favorites = favorites
        self.appVersion = appVersion
        self.writer = writer
    }

    public var privacyText: String { Self.privacySummary }

    /// Both connections, in a stable order, for hosts and tests.
    public var connections: [ConnectionsPrivacyConnection] {
        [
            ConnectionsPrivacyConnection(
                id: "apple-health", title: Self.appleHealthTitle,
                detail: "Write entries to the Health app on this phone.", isAvailable: Self.appleHealthAvailable,
                isEnabled: Self.appleHealthAvailable && appleHealthEnabled, arrivingNote: Self.arrivingNote),
            ConnectionsPrivacyConnection(
                id: "health-relay", title: Self.healthRelayTitle,
                detail: "Send entries to your own relay service.", isAvailable: Self.healthRelayAvailable,
                isEnabled: Self.healthRelayAvailable && healthRelayEnabled, arrivingNote: Self.arrivingNote),
        ]
    }

    /// The export action stays available after a failure: the message explains what went wrong, and the person
    /// can tap export again. Nothing on this screen can clear the error state, so disabling the button on it
    /// would strand the person on a screen with no working way out.
    public var canExport: Bool { true }

    /// Builds the export document, encodes it and writes it to a temporary file. Nothing is sent anywhere.
    @discardableResult
    public func export(now: Date) -> Bool {
        do {
            let document = try JournalExporter.makeExport(
                store: store, favorites: favorites, appVersion: appVersion, exportedAt: now)
            let data = try JournalExporter.encode(document)
            let name = JournalExporter.fileName(exportedAt: now)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            // The export is the whole health history in one file, so it is written complete-only.
            try writer(data, url, Self.exportWriteOptions)
            // A second export in another second gets a different file name, so the copy this screen was
            // holding would be left behind with nothing able to remove it. It holds the same journal, so it
            // goes before the new URL replaces it.
            if exportFileURL != url { removeExportFile() }
            exportFileURL = url
            exportFileName = name
            entryCount = document.intakes.count
            exportState = .ready
            errorMessage = nil
            return true
        } catch {
            // The export this screen holds is no longer offered, so its file goes with it rather than being
            // left in the temporary directory with nothing left to remove it.
            removeExportFile()
            exportState = .failed
            errorMessage = Self.exportFailedMessage
            return false
        }
    }

    /// Removes the exported file and returns the screen to its empty state. The journal JSON can contain the
    /// whole history, so the copy on disk is deleted before the screen forgets where it was.
    public func clearExport() {
        removeExportFile()
        entryCount = 0
        exportState = .idle
        errorMessage = nil
    }

    /// Deletes the file while its URL is still known. A file that is already gone is not an error.
    private func removeExportFile() {
        guard let url = exportFileURL else {
            exportFileName = nil
            return
        }
        try? FileManager.default.removeItem(at: url)
        exportFileURL = nil
        exportFileName = nil
    }

    /// Reads a file the person chose and restores it. Nothing is sent anywhere: the file was already on
    /// this device or in a place they opened it from, and the restore only writes to the local stores.
    ///
    /// The importer refuses anything it cannot do whole - a file from a newer schema version, a journal
    /// that already has entries, a file it cannot read - and says which, so the message can tell the
    /// person whether to try another file or to delete something first.
    @discardableResult
    public func importJournal(data: Data) -> Bool {
        do {
            let summary = try JournalImporter.importExport(data, into: store, favorites: favorites)
            importSummary = summary
            importState = .imported
            importMessage = Self.importSummaryText(summary)
            return true
        } catch let error as JournalImportError {
            importSummary = nil
            importState = .failed
            importMessage = Self.importFailureText(for: error)
            return false
        } catch {
            importSummary = nil
            importState = .failed
            importMessage = Self.importFailedMessage
            return false
        }
    }

    /// One line saying what came back, so a restore that quietly did nothing still looks like an answer.
    public static func importSummaryText(_ summary: JournalImportSummary) -> String {
        let entries = summary.intakes == 1 ? "1 entry" : "\(summary.intakes) entries"
        let deleted = summary.tombstones == 0 ? "" : " and \(summary.tombstones) deleted"
        let favorites = summary.favorites == 0 ? "" : ", \(summary.favorites) favorites"
        return "Imported \(entries)\(deleted)\(favorites)."
    }

    public static func importFailureText(for error: JournalImportError) -> String {
        switch error {
        case .unsupportedVersion:
            return importUnsupportedVersionMessage
        case .notEmpty:
            return importNotEmptyMessage
        case .malformed, .corrupt:
            return importFailedMessage
        }
    }

    /// Returns the screen's import state to empty, so a later attempt does not read as part of an earlier
    /// one.
    public func clearImport() {
        importState = .idle
        importSummary = nil
        importMessage = nil
    }
}