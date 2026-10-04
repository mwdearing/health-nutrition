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
    public static let eraseButtonTitle = "Erase all data"
    /// The confirmation the button is guarded by. It names what goes and says the erase cannot be undone.
    public static let eraseConfirmationMessage = """
        Every entry, favorite and recipe this app stores on this device is deleted, along with any copy \
        it has exported. This cannot be undone.
        """
    public static let eraseConfirmationTitle = "Erase all data?"
    /// Sits under the erase button, so the cost of the action is read before it is tapped rather than
    /// only in the dialog that follows.
    public static let eraseFooterMessage = """
        Erases the journal, favorites and recipes this app stores on this device. Nothing has been sent \
        anywhere, so nothing has to be deleted anywhere else.
        """
    public static let eraseFailedMessage =
        "Some stored data could not be erased. Quit and reopen the app, then try again."
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
    /// Counts how often data was erased, so a host holding this model can tell that the stores behind
    /// its other screens are empty now and reload them. The erase happens on this screen; the totals on
    /// Today and the rows in the Journal would otherwise still show what was just deleted.
    @Published public private(set) var eraseGeneration = 0
    /// Switch positions of the two connections. They stay off because the toggles are disabled.
    @Published public var appleHealthEnabled = false
    @Published public var healthRelayEnabled = false

    private let store: JournalStore
    private let favorites: FavoritesStore?
    private let appVersion: String
    private let writer: ConnectionsPrivacyExportWriter
    /// One entry per store file this app keeps. `eraseAllData()` runs them all; the app injects the real
    /// stores, and a test injects recorders or a store that refuses.
    private let erasers: [JournalErasing]

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
        writer: @escaping ConnectionsPrivacyExportWriter = ConnectionsPrivacyViewModel.writeExport,
        erasers: [JournalErasing] = []
    ) {
        self.store = store
        self.favorites = favorites
        self.appVersion = appVersion
        self.writer = writer
        self.erasers = erasers
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

    /// The erase action is offered only when the screen was given the stores to erase. Without one it
    /// would report an erase it never ran, which is worse than not offering it.
    public var canEraseAll: Bool { !erasers.isEmpty }

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

    /// Deletes everything this app stores on this device: every journal entry with its revision history,
    /// product snapshots, queued outbox operations, favorites and personal recipes, plus the exported
    /// copy this screen was holding. Nothing is sent anywhere, so nothing has to be retracted there.
    ///
    /// One store failing does not stop the rest: each store erases itself and the person is told that
    /// something was left behind, so they can try again rather than believe the data is gone when it is
    /// not. Returns whether every store erased itself.
    @discardableResult
    public func eraseAllData() -> Bool {
        var failed = false
        for eraser in erasers {
            do {
                try eraser.eraseAll()
            } catch {
                failed = true
            }
        }
        // The exported copy holds the same history as the stores just emptied, so it goes with them
        // rather than sitting in the temporary directory with nothing able to remove it.
        removeExportFile()
        entryCount = 0
        exportState = .idle
        errorMessage = failed ? Self.eraseFailedMessage : nil
        eraseGeneration += 1
        return !failed
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
}