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

/// Deletes one exported file. Injected so a test can stand in for a file the system will not delete;
/// the erase has to hear about that rather than report a deletion it did not make.
public typealias ConnectionsPrivacyExportRemover = (_ url: URL) throws -> Void

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

/// How many journal restores are running, and how to wait for all of them to stop.
///
/// A lock and a condition rather than an actor, because the two sides are on different actors by design: the
/// restores finish on background threads - that is the whole point of running them there - while the erase
/// waits on the main actor. `begin` is called before a restore starts and `end` when it has finished, whether
/// it succeeded or failed; `wait` reports whether every restore in flight had finished within the time it was
/// given, so a caller never blocks forever on work that cannot arrive.
private final class ImportGate: @unchecked Sendable {
    private let condition = NSCondition()
    /// How many restores are in flight. A count rather than a flag: two imports can overlap, and the first
    /// of them to finish must not report the gate idle while the second is still writing.
    private var inFlight = 0

    /// Marks a restore as started.
    func begin() {
        condition.lock()
        inFlight += 1
        condition.unlock()
    }

    /// Marks a restore as finished, and wakes anything waiting once the last one is gone.
    func end() {
        condition.lock()
        if inFlight > 0 { inFlight -= 1 }
        if inFlight == 0 { condition.broadcast() }
        condition.unlock()
    }

    /// Blocks the caller until **every** restore in flight has finished. True when there was nothing running,
    /// or when they all finished in time; false when one was still running after `timeout`, which is the
    /// caller's cue to refuse rather than erase beside a restore that is still writing.
    func wait(upTo timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while inFlight > 0 {
            if !condition.wait(until: deadline) {
                // Out of time. True only if the last restore happened to finish in the same breath.
                return inFlight == 0
            }
        }
        return true
    }
}

/// Backs the Connections and privacy screen. It reads the local stores and produces the export file; it never
/// sends anything anywhere. Sharing happens only when the person taps the share control.
@MainActor
public final class ConnectionsPrivacyViewModel: ObservableObject {
    public static let appleHealthTitle = "Apple Health"
    public static let healthRelayTitle = "HealthRelay"
    public static let arrivingNote = "This connection arrives in a later release. It cannot be switched on yet."
    // Written as concatenated literals rather than one multi-line literal: the lint scripts and the
    // acceptance mask string literals with a pattern that pairs quotes naively, and a run of three
    // quotes shifts every pairing after it far enough to swallow real code.
    public static let privacySummary =
        "Your journal stays on this device. Nothing is uploaded and nothing is sent to Apple or to a server "
        + "unless you ask for it. The export below is the only way data leaves this screen, and only because "
        + "you tap it: it writes a JSON copy into a temporary file that the system share sheet can hand to "
        + "an app you choose."
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
    /// An import asked for while an erase was running. It is refused rather than queued, because a restore
    /// that landed afterwards would put back what the person had just deleted.
    public static let importDuringEraseMessage =
        "Data was being erased, so nothing was imported. Try again once that is finished."
    /// An erase that found a restore still running and would not wait any longer.
    public static let eraseWaitTimedOutMessage =
        "An import was still running, so nothing was erased. Try again in a moment."

    public static let eraseButtonTitle = "Erase all data"
    /// The confirmation the button is guarded by. It names what goes and says the erase cannot be undone.
    public static let eraseConfirmationMessage =
        "Every entry, favorite and recipe this app stores on this device is deleted, along with any export "
        + "file it wrote. This cannot be undone. A copy you already shared or saved elsewhere — in Files, "
        + "in mail, in cloud storage or in another app — is not erased: the app cannot reach it, so delete "
        + "it there yourself."
    public static let eraseConfirmationTitle = "Erase all data?"
    /// Sits under the erase button, so the cost of the action is read before it is tapped rather than
    /// only in the dialog that follows.
    public static let eraseFooterMessage =
        "Erases the journal, favorites and recipes this app stores on this device, plus any export file "
        + "it wrote. A copy you already shared or saved elsewhere — in Files, in mail, in cloud storage "
        + "or in another app — is not erased: delete it there yourself."
    public static let eraseFailedMessage =
        "Some stored data could not be erased. Quit and reopen the app, then try again."
    /// The names the exporter writes, as `fileName(exportedAt:)` builds them. The erase sweeps the
    /// temporary directory for these, so an export left behind by a session that ended without the
    /// screen tidying up is still removed.
    public static let exportFileNamePrefix = "journal-export-"
    public static let exportFileNameSuffix = ".json"
    /// Where the exporter would write for `exportedAt`, so a test can place a strayed export without
    /// duplicating the name format.
    public static func exportFileURL(for exportedAt: Date) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            JournalExporter.fileName(exportedAt: exportedAt))
    }
    /// Whether one name in the temporary directory is exactly a name the exporter writes: the prefix, a
    /// timestamp in the exporter's own format, and the suffix.
    ///
    /// The timestamp is checked, not just its length, because the erase deletes what it matches. A name
    /// that only looks like an export belongs to something else, and deleting a file this app never
    /// wrote would be a worse mistake than leaving a stray one behind.
    public static func exportFilePatternMatches(_ name: String) -> Bool {
        guard name.hasPrefix(exportFileNamePrefix), name.hasSuffix(exportFileNameSuffix) else { return false }
        let stamp = name.dropFirst(exportFileNamePrefix.count).dropLast(exportFileNameSuffix.count)
        // Parse the timestamp the way the exporter formats it, then format it back: only a real UTC time
        // that the exporter would write again byte for byte counts (2024-99-99 does not).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = JournalExporter.fileNameDateFormat
        formatter.isLenient = false
        guard let date = formatter.date(from: String(stamp)) else { return false }
        return JournalExporter.fileName(exportedAt: date) == name
    }
    public static let unavailableVersion = "unknown"
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
    /// Counts how often data was erased, so a host holding this model can tell that the stores behind
    /// its other screens are empty now and reload them. The erase happens on this screen; the totals on
    /// Today and the rows in the Journal would otherwise still show what was just deleted.
    @Published public private(set) var eraseGeneration = 0
    /// Switch positions of the two connections. They stay off because the toggles are disabled.
    @Published public var appleHealthEnabled = false
    @Published public var healthRelayEnabled = false

    /// The unit system shown on screen. Written through to the preference store as soon as it is
    /// changed, so a unit chosen here is the unit the other screens read on the next reload.
    @Published public var unitSystem: UnitSystem {
        didSet {
            guard unitSystem != oldValue, !isPublishingStoredPreference else { return }
            preferences.setUnitSystem(unitSystem)
        }
    }
    /// The quick-water amount as typed, in millilitres.
    @Published public var quickWaterText: String
    /// Why the typed quick-water amount was refused, or nil when it is acceptable.
    @Published public private(set) var quickWaterError: String?
    /// True while the screen is taking its published values FROM the preference store rather than from
    /// a person, so putting the store back to its defaults does not write those defaults straight out
    /// again as though they had just been chosen.
    private var isPublishingStoredPreference = false

    /// What the quick-water field refuses, in the words a person can act on.
    public static let quickWaterInvalidMessage =
        "Enter a water amount above zero, using digits and a point."
    public static let quickWaterTitle = "Quick-add water amount"
    public static let quickWaterFieldLabel = "Quick-add water amount in millilitres"
    public static let unitsSectionTitle = "Units"
    public static let unitSystemTitle = "Show amounts in"

    private let preferences: DisplayPreferencesWriting
    private let store: JournalStore
    private let favorites: FavoritesStore?
    private let appVersion: String
    private let writer: ConnectionsPrivacyExportWriter
    private let remover: ConnectionsPrivacyExportRemover
    /// One entry per store file this app keeps. `eraseAllData()` runs them all; the app injects the real
    /// stores, and a test injects recorders or a store that refuses.
    private let erasers: [JournalErasing]

    /// The restore in flight, so an erase can ask it to stop and wait for it. Nil when nothing is running.
    private var importTask: Task<Void, Never>?
    /// Whether a restore is running right now, and how to wait for it. A lock rather than an actor,
    /// because the two sides of that wait are on different actors: the restore finishes on a background
    /// thread and the erase waits here, on the main actor, so they have to meet somewhere both can reach.
    private let importGate = ImportGate()
    /// True while an erase is running, so an import started in that window is refused rather than racing it.
    private var isErasing = false
    /// Counts imports and erases. An import publishes only while its own number is still the current one,
    /// which is how the outcome of an import an erase overtook is dropped rather than shown.
    private var importGeneration = 0

    /// How long an erase waits for a restore that is still running before it gives up and says so. A restore
    /// of one file is milliseconds; this is only here so a wait that never ends cannot hold the screen.
    public static let eraseWaitsForImportSeconds: TimeInterval = 2

    /// The write options the export always asks for: complete-only, so the journal is unreadable while the
    /// device is locked, and atomic, so no half-written copy can be shared.
    public static let exportWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    /// The real write. Replacing it is only for tests.
    public static func writeExport(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }

    /// The real delete. Replacing it is only for tests.
    public static func removeExport(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// - Parameter preferences: where the display settings are read from and written to. An in-memory one
    ///   is the default, so a host that does not persist anything still gets a working screen and a
    ///   test needs no defaults domain.
    public init(
        store: JournalStore, favorites: FavoritesStore? = nil,
        appVersion: String = ConnectionsPrivacyViewModel.defaultAppVersion,
        writer: @escaping ConnectionsPrivacyExportWriter = ConnectionsPrivacyViewModel.writeExport,
        erasers: [JournalErasing] = [],
        remover: @escaping ConnectionsPrivacyExportRemover = ConnectionsPrivacyViewModel.removeExport,
        preferences: DisplayPreferencesWriting = InMemoryDisplayPreferences()
    ) {
        self.store = store
        self.favorites = favorites
        self.appVersion = appVersion
        self.writer = writer
        self.erasers = erasers
        self.remover = remover
        self.preferences = preferences
        self.unitSystem = preferences.unitSystem
        self.quickWaterText = DecimalFormatting.text(preferences.quickWaterMilliliters)
    }

    /// Checks the typed quick-water amount and stores it when it is above zero. An amount that is not
    /// a positive decimal is refused with a message and the stored value is left alone, so a bad
    /// entry cannot become the amount the Today button adds.
    @discardableResult
    public func saveQuickWaterAmount() -> Bool {
        guard let amount = AmountParser.parse(quickWaterText) else {
            quickWaterError = Self.quickWaterInvalidMessage
            return false
        }
        preferences.setQuickWaterMilliliters(amount)
        quickWaterError = nil
        quickWaterText = DecimalFormatting.text(preferences.quickWaterMilliliters)
        return true
    }

    /// The quick-water amount as it is currently stored.
    public var quickWaterMilliliters: Decimal { preferences.quickWaterMilliliters }

    /// The quick-water amount in the unit system shown on screen.
    public var quickWaterDisplay: DisplayAmount {
        AmountDisplay.display(preferences.quickWaterMilliliters, unit: .mL, system: unitSystem)
    }

    /// The unit systems offered, in a stable order.
    public var unitSystems: [UnitSystem] { UnitSystem.allCases }

    /// The label for a unit system in the picker.
    public static func label(for system: UnitSystem) -> String { system.label }

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
        // An import writes the whole journal in one save and an erase writes it away in another. Run
        // together they could land in either order, and the screen would end up claiming whichever came
        // second. So the two never overlap: an import started while an erase runs is refused, and an erase
        // that finds a restore in flight waits for it to finish before it touches a store. Waiting rather
        // than queueing matters here, because the person asked for everything gone, not for the erase to
        // happen first and then be undone.
        guard !isErasing else { return false }
        isErasing = true
        // The import state from *before* the erase goes now, as the screen enters its erasing state: "Imported
        // 3 entries" describes a journal that is about to stop existing. It is cleared here rather than at
        // the end, because an import asked for during the erase is refused with a message of its own, and
        // clearing afterwards would throw that away - and it is the only thing on the screen explaining why
        // the file they chose did nothing.
        clearImport()
        // Anything an in-flight import publishes afterwards is about a journal that is about to be deleted.
        importGeneration += 1
        importTask?.cancel()
        guard importGate.wait(upTo: Self.eraseWaitsForImportSeconds) else {
            isErasing = false
            errorMessage = Self.eraseWaitTimedOutMessage
            return false
        }
        defer { isErasing = false }

        var failed = false
        for eraser in erasers {
            do {
                try eraser.eraseAll()
            } catch {
                failed = true
            }
        }
        // Every export file this app wrote goes, not only the one this model remembers: the app can be
        // killed after an export, and the next session's model starts with no URL to delete.
        if !removeEveryExportFile() { failed = true }
        // The handle this screen was holding is one of those files, or is already gone. Clearing it
        // cannot fail: the sweep above has removed whatever was still there.
        forgetExportFile()
        // The unit system and the glass size are stored values like any other, so they go with
        // everything else. Clearing them cannot fail either, and the screen is put back to the
        // defaults rather than left showing settings the erase has removed.
        forgetDisplayPreferences()
        entryCount = 0
        exportState = .idle
        errorMessage = failed ? Self.eraseFailedMessage : nil
        eraseGeneration += 1
        return !failed
    }

    /// Puts the display preferences back to their defaults and republishes that state, so the screen
    /// shows what a person sees on a fresh install rather than the settings just erased.
    ///
    /// The published values are read back from the store rather than set to literals, so an
    /// implementation that refuses to clear something would be visible here rather than papered over.
    private func forgetDisplayPreferences() {
        preferences.resetToDefaults()
        isPublishingStoredPreference = true
        unitSystem = preferences.unitSystem
        quickWaterText = DecimalFormatting.text(preferences.quickWaterMilliliters)
        quickWaterError = nil
        isPublishingStoredPreference = false
    }

    /// Removes every `journal-export-*.json` in the temporary directory and reports whether all of them
    /// are gone.
    ///
    /// A file that cannot be deleted, or a directory that cannot be read, makes this return false: the
    /// erase promised to remove exported copies, and a copy it left behind is worse than a reported
    /// failure, because the person would stop looking for it. Every other file is still attempted, so
    /// one stubborn file does not keep the rest.
    private func removeEveryExportFile() -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return false }
        var removed = true
        for name in names where Self.exportFilePatternMatches(name) {
            do {
                try remover(directory.appendingPathComponent(name))
            } catch {
                removed = false
            }
        }
        return removed
    }

    /// Deletes the file while its URL is still known. A file that is already gone is not an error: this is
    /// the screen's own tidying up on the way out, where there is nobody left to tell.
    private func removeExportFile() {
        if let url = exportFileURL { try? remover(url) }
        forgetExportFile()
    }

    /// Drops the remembered copy without touching the disk.
    private func forgetExportFile() {
        exportFileURL = nil
        exportFileName = nil
    }

    /// What an import produced, carried from the background back to the screen.
    ///
    /// Both cases are values the background can build on its own, and nothing that belongs to the main
    /// actor crosses with them: the summary is a count, and a refusal names *which* refusal rather than
    /// the sentence, because the words live on this actor with the rest of the screen's copy.
    private enum ImportOutcome: Sendable {
        case imported(JournalImportSummary)
        case failed(ImportFailure)
    }

    /// Why an import did not happen.
    private enum ImportFailure: Sendable {
        /// The importer said why: a newer schema version, a journal that is not empty, a file it cannot
        /// read. Carried typed so the screen can word each one.
        case refused(JournalImportError)
        /// A store or disk error with nothing to explain to the person.
        case other
        /// An erase was running, so the import was refused before it started.
        case erasing
    }

    /// Reads a file the person chose and restores it. Nothing is sent anywhere: the file was already on
    /// this device or in a place they opened it from, and the restore only writes to the local stores.
    ///
    /// The read and the restore run off the main actor, because they are the slow part: a journal with
    /// thousands of revisions is parsed, checked and written in one go, and doing that here would freeze the
    /// screen the person is looking at, on the one action that starts by reading a file of unknown size.
    /// Only the outcome is published, and it is published on the main actor, because that is what updates
    /// the screen. The stores are `Sendable` and each one serializes its own writes, so the restore is as
    /// safe off this actor as it was on it.
    ///
    /// The task is kept, so an erase cannot pull the stores out from under a restore that is still running;
    /// see `eraseAllData()`. An import started while an erase is running is refused rather than racing it.
    public func importJournal(data: Data) {
        guard !isErasing else {
            // Refused here rather than queued: the person asked to erase everything, and a restore that
            // landed afterwards would put back what they just deleted.
            importSummary = nil
            importState = .failed
            importMessage = Self.importDuringEraseMessage
            return
        }
        // Read out of the main actor's own state first, so the background task touches nothing here.
        let store = store
        let favorites = favorites
        // Counted first, then read: this import's token is the number *after* its own increment, which is
        // what `apply` compares against. Reading before incrementing hands out the previous import's number,
        // so every outcome looks stale and none is ever published.
        importGeneration += 1
        let generation = importGeneration
        let gate = importGate
        gate.begin()
        // Created here, on the main actor, and not inside the task below. The restore has to be *running*
        // before this method returns, because an erase can block the main actor the moment it is called, and
        // a task body that needs the main actor in order to start would never get to run: the erase would
        // wait on a signal nothing was ever going to send. A detached task needs no actor to begin, and its
        // `defer` opens the gate from a background thread as soon as the store writes are done.
        let restore = Task.detached(priority: .userInitiated) { () -> ImportOutcome in
            // The gate is opened from the background, and not from the task below: the erase waits on it from
            // the main actor, so it has to be signalled by the work it is waiting for.
            defer { gate.end() }
            do {
                return .imported(try JournalImporter.importExport(data, into: store, favorites: favorites))
            } catch let error as JournalImportError {
                return .failed(.refused(error))
            } catch {
                return .failed(.other)
            }
        }
        importTask = Task { [weak self] in
            let outcome = await restore.value
            // Named rather than inherited: the task's own isolation decides where this would run, and the
            // state it updates is main-actor state, so the hop is stated instead of assumed.
            await MainActor.run { self?.apply(outcome, startedAt: generation) }
        }
    }

    /// Publishes an import's outcome on the main actor, which is the only place that touches this state.
    ///
    /// An outcome from an import that an erase has overtaken is dropped: the stores it restored were deleted
    /// a moment later, and the screen saying "Imported 3 entries" would be describing a journal that is gone.
    private func apply(_ outcome: ImportOutcome, startedAt generation: Int) {
        guard generation == importGeneration else { return }
        switch outcome {
        case .imported(let summary):
            // The export this screen was holding was made from the journal as it was before the restore, so
            // the share control would still offer the wrong journal. It goes, and the screen stops offering
            // it, rather than leaving a file of the pre-import journal one tap away.
            removeExportFile()
            exportState = .idle
            entryCount = 0
            errorMessage = nil
            importSummary = summary
            importState = .imported
            importMessage = Self.importSummaryText(summary)
        case .failed(let failure):
            importSummary = nil
            importState = .failed
            importMessage = Self.importFailureText(for: failure)
        }
    }

    /// The sentence for a failure, chosen here because the words belong to this actor.
    private static func importFailureText(for failure: ImportFailure) -> String {
        switch failure {
        case .refused(let error):
            return importFailureText(for: error)
        case .other:
            return importFailedMessage
        case .erasing:
            return importDuringEraseMessage
        }
    }

    /// The file the person chose could not be read at all. They asked for that file to be imported and
    /// nothing happened, so this is a failed import and not a cancellation: it says so rather than leaving
    /// the screen looking as if it were never asked.
    public func importCouldNotReadFile() {
        importSummary = nil
        importState = .failed
        importMessage = Self.importFailedMessage
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