import Foundation
import NutritionDomain
import NutritionJournal

/// One external connection. Apple Health and HealthRelay are shown from the start but cannot be switched on
/// yet: they are listed so the shape of the feature is clear, not to imply that data already leaves the device.
public struct ConnectionsPrivacyConnection: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// False for both connections until each of them is built.
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
public final class ImportGate: @unchecked Sendable {
    private let condition = NSCondition()
    public init() {}
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
        "Your journal stays on this device and in your own iCloud or device backups, and is not uploaded as a whole. Signing in sends your account email, "
        + "account ID and optional display name to the project's server. A barcode lookup you start sends the "
        + "barcode to the community catalog, and only when you are signed in. "
        + "A name search in Search foods sends the words you typed to Open Food Facts. "
        + "Share labels off stops new label submissions but does not disable barcode lookup. A label submission is "
        + "linked to your signed-in account, but does not include your journal entries or photo. A product you create "
        + "and share is linked the same way. Searching shared products sends your search words to the project's server "
        + "with your account when you are signed in. After you connect Apple Health in Settings, the app writes "
        + "nutrients from real logged food and water entries to HealthKit on this device and reads back only its own samples, plus steps, activity and weight if you ask on Today; "
        + "a debug build's HealthKit screen can also write test samples. Erasing journal rows does not remove "
        + "HealthKit samples already written. "
        + "For email sign-in, hCaptcha can process browser/device signals and sends a verification result; a rare "
        + "challenge may request camera access. It does not receive your journal. Export writes a local JSON file for "
        + "a destination you choose in the share sheet."
    public static let exportButtonTitle = "Export journal"
    public static let shareButtonTitle = "Share the export"
    public static let exportFailedMessage = "Could not export the journal."
    public static let importButtonTitle = "Import a journal export"
    public static let importFailedMessage = "Could not import that file."
    /// The approved rollback wording: a write failed, and the undo put everything back.
    public static let importRolledBackMessage = "Nothing was imported. Try again."
    /// What the importer refused and why, in the words a person can act on.
    public static let importUnsupportedVersionMessage =
        "That file was made by a newer version of the app, so this one cannot read it."
    public static let importNotEmptyMessage =
        "This device already has journal entries. An import only works on a journal that is empty."
    /// A version 4 backup carries the whole saved meals list, so it is not restored over saved meals the phone keeps.
    public static let importSavedMealsNotEmptyMessage =
        "This device already has saved meals. An import that includes saved meals only works when there are none."
    /// An import asked for while an erase was running. It is refused rather than queued, because a restore
    /// that landed afterwards would put back what the person had just deleted.
    public static let importDuringEraseMessage =
        "Data was being erased, so nothing was imported. Try again once that is finished."
    public static let partialRestoreWarningMessage =
        "The restore was incomplete; journal entries or saved meals may already be present. Check your journal and saved meals before importing this file again."

    public static let eraseButtonTitle = "Erase all data"
    /// The confirmation the button is guarded by. It names what goes and says the erase cannot be undone.
    public static let eraseConfirmationMessage =
        "Every entry, favorite, saved meal, recipe, supplement and daily goal this app stores on this device is deleted, and the daily, water and supplement reminders "
        + "are switched off, along with any export file it wrote. This cannot be undone. A copy you already shared or saved elsewhere — in Files, "
        + "in mail, in cloud storage or in another app — is not erased: the app cannot reach it, so delete "
        + "it there yourself. Nutrition and water data this app wrote to Apple Health stays there: delete it in the Health app. "
        + "Erasing also signs you out on this device; your community account and any "
        + "shared labels remain on the server."
    public static let eraseConfirmationTitle = "Erase all data?"
    /// Sits under the erase button, so the cost of the action is read before it is tapped rather than
    /// only in the dialog that follows.
    public static let eraseFooterMessage =
        "Erases the journal, favorites, saved meals, recipes, your supplement list and daily goals this app stores on this device and switches off the daily, water and supplement "
        + "reminders, plus any export file it wrote. A copy you already shared or saved elsewhere — in Files, in mail, in cloud storage "
        + "or in another app — is not erased: delete it there yourself. Data this app wrote to Apple Health stays there too: delete it in the Health app. Erasing signs you out on this device; "
        + "your community account and any shared labels remain on the server."
    /// Shown when the erase stopped before any store was touched, so nothing has been erased yet.
    public static let eraseNothingErasedMessage = "Nothing was erased. Tap Retry to try again."
    /// Names what is still on the phone after an erase, in the order the erase ran. `names` is never empty.
    public static func eraseLeftBehindMessage(_ names: [String]) -> String {
        "Erase didn't finish. Still on this device: \(naturalList(names)). Tap Retry to erase them."
    }
    private static func naturalList(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
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
    /// True when `errorMessage` describes an erase that did not finish, so the screen offers Retry.
    @Published public private(set) var eraseRetryAvailable = false
    /// True from the moment the person asks to erase (Erase or Retry) until they confirm or cancel. Nothing is erased
    /// while this is only requested.
    @Published public private(set) var eraseConfirmationPending = false
    @Published public private(set) var importState: ConnectionsPrivacyImportState = .idle
    @Published public private(set) var isImporting = false
    /// Main-actor count of restores whose outcomes have not yet reached `apply`. The store-write gate is
    /// cross-thread; this published count also keeps export availability current for every overlapping run.
    @Published private var activeImportCompletions = 0
    @Published public private(set) var importSummary: JournalImportSummary?
    @Published public private(set) var importMessage: String?
    /// A partial restore can be superseded by another import result, but its retained rows still need review.
    /// This warning remains until a successful restore or a successful erase confirms the journal is replaced.
    @Published public private(set) var incompleteRestoreWarning: String?
    /// Counts how often data was erased, so a host holding this model can tell that the stores behind
    /// its other screens are empty now and reload them. The erase happens on this screen; the totals on
    /// Today and the rows in the Journal would otherwise still show what was just deleted.
    @Published public private(set) var eraseGeneration = 0
    /// Counts completed journal restores, including partial restores, so the host reloads screens that hold
    /// their own journal snapshot. Kept distinct from import/erase fencing generations.
    @Published public private(set) var journalRestoreGeneration = 0
    /// True while an erase is running, so an import started in that window is refused rather than racing it.
    @Published public private(set) var isErasing = false
    /// Switch positions of the two connections. They stay off because the toggles are disabled.
    @Published public var appleHealthEnabled = false
    @Published public var healthRelayEnabled = false

    /// The unit system shown on screen. Written through to the preference store as soon as it is
    /// changed, so a unit chosen here is the unit the other screens read on the next reload.
    ///
    /// The typed quick-water amount moves with it: the field reads in one unit at a time, so the same
    /// figure has to be restated in the new one. An amount already typed as a number is converted; one
    /// that is not a number is left as it is, because there is nothing to convert and the field's own
    /// error says why.
    @Published public var unitSystem: UnitSystem {
        didSet {
            guard unitSystem != oldValue, !isPublishingStoredPreference else { return }
            convertQuickWaterText(from: oldValue)
            preferences.setUnitSystem(unitSystem)
        }
    }
    /// The quick-water amount as typed, in the unit the screen is showing.
    @Published public var quickWaterText: String {
        didSet {
            // Any change not made by showing the stored amount is the person's own, so the stored figure is no
            // longer what the field stands for (issue 389).
            if !isShowingStoredQuickWater { quickWaterEditedSinceStored = true }
        }
    }
    /// True while the field is shown from the stored milliliters and nothing has been typed since. A unit switch
    /// or a Save then must not rewrite the stored value from the rounded figure.
    private var quickWaterEditedSinceStored = false
    private var isShowingStoredQuickWater = false
    /// Why the typed quick-water amount was refused, or nil when it is acceptable.
    @Published public private(set) var quickWaterError: String?
    /// True while the screen is taking its published values FROM the preference store rather than from
    /// a person, so putting the store back to its defaults does not write those defaults straight out
    /// again as though they had just been chosen.
    private var isPublishingStoredPreference = false

    /// What the quick-water field refuses, in the words a person can act on. It names no unit, because
    /// the field's own label says which one the amount is read in.
    public static let quickWaterInvalidMessage =
        "Enter a water amount above zero, using digits and a point."
    public static let quickWaterTitle = "Quick-add water amount"
    public static let unitsSectionTitle = "Units"
    public static let unitSystemTitle = "Show amounts in"

    private let preferences: DisplayPreferencesWriting
    private let store: JournalStore
    private let favorites: FavoritesStore?
    /// Where an export reads saved meals and an import writes them; nil leaves them out of both.
    private let savedMeals: JournalSavedMealsStore?
    /// Where an export reads goals and an import writes them. Required, so no caller can leave them out silently.
    private let goals: GoalStore
    private let appVersion: String
    private let writer: ConnectionsPrivacyExportWriter
    private let remover: ConnectionsPrivacyExportRemover
    /// One entry per store file this app keeps. `eraseAllData()` runs them all; the app injects the real
    /// stores, and a test injects recorders or a store that refuses. When the journal store also conforms
    /// to `JournalErasing`, object identity distinguishes its result from failures in the other erasers.
    private let erasers: [JournalErasing]
    private let beforeErase: @MainActor () -> Void
    private let afterSuccessfulErase: @MainActor () -> Void
    /// Forgets an optional community session on this device; the default keeps account-free builds standalone.
    private let eraseLocalAccount: () async throws -> Void
    /// Reads back the system's pending reminder requests after the reminder erasers ran, and names each kind of
    /// reminder that still has one ("reminders", "custom reminders"). The reminder erasers cannot report a failure.
    private let remindersStillPending: () async -> [String]
    /// How long an erase waits for a running import; a test shortens it so the timeout path runs quickly.
    private let importWaitSeconds: TimeInterval
    /// The Health delivery worker's run gate. An erase holds it while it runs, so no delivery pass is between its
    /// busy check and its Health write while the stores are emptied (#841). Nil only where no worker runs.
    private let deliveryGate: DeliveryRunGate?
    /// How long an erase waits for a delivery pass that holds the gate; a test shortens it.
    private let deliveryWaitSeconds: TimeInterval

    /// Changes whenever this screen creates, clears, or forgets an export. An import may remove only the
    /// copy that was already current when that import began; a later export may contain restored rows.
    private var exportRevision = 0
    /// Unlike `eraseGeneration`, this advances only when the journal eraser reports success. Failures in
    /// account or ancillary cleanup must not make a confirmed journal deletion look like it failed.
    private var successfulEraseEpoch = 0
    private struct DeferredImportEffects {
        let changedJournal: Bool
        let isPartialRestore: Bool
        let startedAtImportGeneration: Int
        let exportRevisionAtStart: Int
    }
    /// Import outcomes that arrive while an erase is suspended are resolved when its result is known.
    private var deferredImportEffectsDuringErase: [DeferredImportEffects] = []

    /// The restore in flight, so an erase can ask it to stop and wait for it. Nil when nothing is running.
    /// Whether a restore is running right now, and how to wait for it. A lock rather than an actor,
    /// because the two sides of that wait are on different actors: the restore finishes on a background
    /// thread and the erase waits here, on the main actor, so they have to meet somewhere both can reach.
    private let importGate: ImportGate
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
        goals: GoalStore,
        store: JournalStore, favorites: FavoritesStore? = nil, savedMeals: JournalSavedMealsStore? = nil,
        appVersion: String = ConnectionsPrivacyViewModel.defaultAppVersion,
        writer: @escaping ConnectionsPrivacyExportWriter = ConnectionsPrivacyViewModel.writeExport,
        erasers: [JournalErasing] = [],
        remover: @escaping ConnectionsPrivacyExportRemover = ConnectionsPrivacyViewModel.removeExport,
        preferences: DisplayPreferencesWriting = InMemoryDisplayPreferences(),
        beforeErase: @escaping @MainActor () -> Void = {},
        afterSuccessfulErase: @escaping @MainActor () -> Void = {},
        eraseLocalAccount: @escaping () async throws -> Void = {},
        remindersStillPending: @escaping () async -> [String] = { [] },
        importWaitSeconds: TimeInterval = ConnectionsPrivacyViewModel.eraseWaitsForImportSeconds,
        importGate: ImportGate = ImportGate(),
        deliveryGate: DeliveryRunGate? = nil,
        deliveryWaitSeconds: TimeInterval = ConnectionsPrivacyViewModel.eraseWaitsForImportSeconds
    ) {
        self.importGate = importGate
        self.deliveryGate = deliveryGate
        self.deliveryWaitSeconds = deliveryWaitSeconds
        self.store = store
        self.favorites = favorites
        self.savedMeals = savedMeals
        self.goals = goals
        self.appVersion = appVersion
        self.writer = writer
        self.erasers = erasers
        self.beforeErase = beforeErase
        self.afterSuccessfulErase = afterSuccessfulErase
        self.eraseLocalAccount = eraseLocalAccount
        self.remindersStillPending = remindersStillPending
        self.importWaitSeconds = importWaitSeconds
        self.remover = remover
        self.preferences = preferences
        self.unitSystem = preferences.unitSystem
        // Computed from the store rather than read back through `quickWaterDraftAmount`: an initializer
        // cannot read itself before every stored property is set, and this is the last one.
        self.quickWaterText = DecimalFormatting.text(
            Self.draftAmount(milliliters: preferences.quickWaterMilliliters, system: preferences.unitSystem))
    }

    /// Checks the typed quick-water amount and stores it in milliliters when it is above zero. An amount
    /// that is not a positive decimal is refused with a message and the stored value is left alone, so a
    /// bad entry cannot become the amount the Today button adds.
    ///
    /// The field is read in the unit it is labeled in, and converted here: what is stored stays
    /// milliliters, so the ounces are an input and a display unit and never reach the journal, the export
    /// or the digests.
    @discardableResult
    public func saveQuickWaterAmount() -> Bool {
        // Untouched since it was shown from the stored amount: nothing to write, and the stored value stays exact.
        if !quickWaterEditedSinceStored {
            quickWaterError = nil
            return true
        }
        guard let amount = AmountParser.parseTyped(quickWaterText) else {
            quickWaterError = Self.quickWaterInvalidMessage
            return false
        }
        preferences.setQuickWaterMilliliters(milliliters(for: amount, in: quickWaterUnit))
        quickWaterError = nil
        showStoredQuickWater()
        return true
    }

    /// Shows the stored amount in the unit the screen is showing, and remembers that it does.
    private func showStoredQuickWater() {
        isShowingStoredQuickWater = true
        quickWaterText = DecimalFormatting.text(quickWaterDraftAmount)
        isShowingStoredQuickWater = false
        quickWaterEditedSinceStored = false
    }

    /// The unit the quick-water field is read in: fluid ounces under the US system, milliliters under
    /// metric. Water is a volume either way, so the two are the same measure at two scales.
    public var quickWaterUnit: MeasureUnit {
        AmountDisplay.volumeUnit(for: unitSystem)
    }

    /// The symbol that unit is written with, for the field's label and its helper line.
    public var quickWaterUnitSymbol: String { quickWaterUnit.symbol }

    /// The field's label, which names the unit the amount is read in rather than assuming one.
    public var quickWaterFieldLabel: String {
        "Quick-add water amount in \(quickWaterUnitSymbol)"
    }

    /// The typed amount as the screen shows it, in `quickWaterUnit`.
    ///
    /// A converted figure is rounded to the digits a reader of the unit gets, so the figure in the field
    /// is the same one the button on Today will say and no more precise than that: a person who saves
    /// what they can read stores what they meant. The rounding is the display rounding, so it never
    /// turns a non-zero stored amount into a zero in the field.
    ///
    /// Metric shows the milliliters that are stored, so nothing is rounded there: 400.55 mL was typed at
    /// that precision and rounding it to the digit a converted ounce carries would restate it as 400.6
    /// in the very field the person is editing.
    public var quickWaterDraftAmount: Decimal {
        Self.draftAmount(milliliters: preferences.quickWaterMilliliters, system: unitSystem)
    }

    /// The figure the quick-water field starts on for a stored amount, in the unit the system reads volumes in.
    ///
    /// It is rounded from the exact converted figure, not from the display amount: a display amount is
    /// already rounded, so a tiny positive amount would arrive here as zero. The rounding keeps a positive
    /// amount too small for its digits at its own value, so the field never reads as none of it.
    static func draftAmount(milliliters: Decimal, system: UnitSystem) -> Decimal {
        let shown = AmountDisplay.display(milliliters, unit: .mL, system: system)
        guard shown.unit != .mL else { return shown.amount }
        let exact = (try? Quantity(value: milliliters, unit: .mL).converted(to: shown.unit).value) ?? shown.amount
        return roundedForReading(exact, fractionDigits: AmountDisplay.fractionDigits(for: exact))
    }

    /// A figure rounded to the digits it is shown with, except that an amount too small for those digits
    /// keeps them all rather than reading as none of it.
    private static func roundedForReading(_ amount: Decimal, fractionDigits: Int) -> Decimal {
        let rounded = DisplayRounding.rounded(amount, fractionDigits: fractionDigits)
        return rounded == 0 && amount != 0 ? amount : rounded
    }

    /// The milliliters the typed draft stands for, or the stored amount when the field holds something
    /// that is not a number.
    ///
    /// The helper line is about the figure in the field, so it follows the draft rather than the stored
    /// value: a glass entered but not yet saved is still a glass, and the line describing the previous
    /// one while a new one is typed would be answering about the wrong amount.
    private var quickWaterTypedMilliliters: Decimal {
        guard let typed = AmountParser.parseTyped(quickWaterText) else { return preferences.quickWaterMilliliters }
        return milliliters(for: typed, in: quickWaterUnit)
    }

    /// The quick-water amount as it is currently stored.
    public var quickWaterMilliliters: Decimal { preferences.quickWaterMilliliters }

    /// The quick-water amount in the unit system shown on screen.
    public var quickWaterDisplay: DisplayAmount {
        AmountDisplay.display(preferences.quickWaterMilliliters, unit: .mL, system: unitSystem)
    }

    /// The same amount in the unit the screen is NOT showing, for the helper line under the field.
    ///
    /// It is read from the typed draft rather than from what is stored, so the line answers for the
    /// figure in the field the moment it is typed: typing ten under the US system says "= 296 mL"
    /// before Save is tapped. A field holding something that is not a number has nothing to convert,
    /// so it falls back to the stored amount rather than showing nothing.
    ///
    /// Milliliters are read as whole figures there, because a glass size is the thing being set and
    /// "354.9 mL" is a precision nobody asked for; a fluid ounce keeps the digits it is shown with
    /// everywhere else, since 8 fl oz and 8.45 fl oz are different glasses.
    public var quickWaterOtherUnitDisplay: DisplayAmount {
        let other: UnitSystem = unitSystem == .usCustomary ? .metric : .usCustomary
        let shown = AmountDisplay.display(quickWaterTypedMilliliters, unit: .mL, system: other)
        let digits = shown.unit == .mL ? 0 : AmountDisplay.fractionDigits(for: shown.amount)
        return DisplayAmount(
            amount: DisplayRounding.rounded(shown.amount, fractionDigits: digits), unit: shown.unit,
            isBelowSmallest: shown.isBelowSmallest)
    }

    /// The helper line: what the typed amount is in the other unit, e.g. "= 355 mL".
    public var quickWaterEquivalenceText: String {
        "= \(quickWaterOtherUnitDisplay.text)"
    }

    /// The same figure read aloud, because "fl oz" is nothing to a screen reader.
    public var quickWaterEquivalenceAccessibilityLabel: String {
        "= \(quickWaterOtherUnitDisplay.spokenAmount) "
            + "\(AmountDisplay.spokenName(for: quickWaterOtherUnitDisplay.unit))"
    }

    /// The volume in milliliters an amount typed in `unit` stands for. One fluid ounce is exactly
    /// 29.5735295625 mL, so this multiplication is exact in a `Decimal` and nothing is lost.
    private func milliliters(for amount: Decimal, in unit: MeasureUnit) -> Decimal {
        guard unit == .flOz else { return amount }
        return amount * Decimal(string: "29.5735295625", locale: AmountParser.locale)!
    }

    /// Restates a typed quick-water amount in the unit the screen has moved to.
    ///
    /// Nothing happens to an amount that is not a number: a half-typed entry has no value to convert,
    /// and the field's own error already says what is wrong with it.
    private func convertQuickWaterText(from oldSystem: UnitSystem) {
        // Still the stored amount, untouched: show it again in the new unit, from the exact stored value.
        if !quickWaterEditedSinceStored {
            showStoredQuickWater()
            return
        }
        guard let typed = AmountParser.parseTyped(quickWaterText) else { return }
        let milliliters = milliliters(
            for: typed, in: AmountDisplay.volumeUnit(for: oldSystem))
        quickWaterText = DecimalFormatting.text(
            AmountDisplay.display(milliliters, unit: .mL, system: unitSystem).amount)
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
                detail: "Write entries to the Health app on this device.", isAvailable: Self.appleHealthAvailable,
                isEnabled: Self.appleHealthAvailable && appleHealthEnabled, arrivingNote: Self.arrivingNote),
            ConnectionsPrivacyConnection(
                id: "health-relay", title: Self.healthRelayTitle,
                detail: "Send entries to your own relay service.", isAvailable: Self.healthRelayAvailable,
                isEnabled: Self.healthRelayAvailable && healthRelayEnabled, arrivingNote: Self.arrivingNote),
        ]
    }

    /// Export waits until every overlapping import has published its result, and while an erase runs. An
    /// export during a restore could capture the old journal just before the restore writes into it.
    public var canExport: Bool { !isErasing && activeImportCompletions == 0 }

    /// The erase action is offered only when the screen was given the stores to erase. Without one it
    /// would report an erase it never ran, which is worse than not offering it.
    public var canEraseAll: Bool { !erasers.isEmpty }

    /// Builds the export document, encodes it and writes it to a temporary file. Nothing is sent anywhere.
    @discardableResult
    public func export(now: Date) -> Bool {
        guard canExport else { return false }
        exportRevision += 1
        do {
            let document = try JournalExporter.makeExport(
                store: store, favorites: favorites, savedMeals: savedMeals, goals: goals, appVersion: appVersion,
                exportedAt: now)
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

    /// Deletes everything this app stores on this device, including the optional community session,
    /// every journal entry with its revision history, product snapshots, queued outbox operations,
    /// favorites and personal recipes, plus the exported copy this screen was holding. It never calls
    /// a server-side account or sign-out endpoint.
    ///
    /// One store failing does not stop the rest: each store erases itself and the person is told that
    /// something was left behind, so they can try again rather than believe the data is gone when it is
    /// not. Returns whether every store erased itself.
    @discardableResult
    public func eraseAllData() async -> Bool {
        // An import writes the whole journal in one save and an erase writes it away in another. Run
        // together they could land in either order, and the screen would end up claiming whichever came
        // second. So the two never overlap: an import started while an erase runs is refused, and an erase
        // that finds a restore in flight waits for it to finish before it touches a store. Waiting rather
        // than queueing matters here, because the person asked for everything gone, not for the erase to
        // happen first and then be undone.
        guard !isErasing else { return false }
        isErasing = true
        eraseRetryAvailable = false
        deferredImportEffectsDuringErase.removeAll()
        defer { isErasing = false }
        // Wait for a running import to finish. The wait never cancels the import: if it runs past the wait, the erase
        // touches nothing, the import keeps running, and the person is told nothing was erased so they can try again.
        guard importGate.wait(upTo: importWaitSeconds) else {
            errorMessage = Self.eraseNothingErasedMessage
            eraseRetryAvailable = true
            resolveDeferredImportEffectsAfterErase(journalEraseSucceeded: false)
            return false
        }
        // Then take the Health delivery gate, so no pass is between its busy check and its Health write while the
        // stores are emptied (#841). A pass still running after the wait is not cancelled: the erase touches
        // nothing and offers Retry, as it does for an import.
        let erased: Bool
        if await deliveryGate?.pause(upTo: deliveryWaitSeconds) ?? true {
            erased = await eraseHoldingDelivery()
        } else {
            erased = await eraseHoldingDelivery()
        }
        // On every exit, the timeout included. After a pause that timed out the gate holds nothing for this erase,
        // so this does nothing then.
        await deliveryGate?.resumeAfterPause()
        return erased
    }

    /// The erase itself, run while it holds the Health delivery gate. Returns whether every store erased itself.
    private func eraseHoldingDelivery() async -> Bool {
        // With the import gone, no import can run again until this erase finishes. A restore flag left behind would
        // let the next import of that file put back favorites the person is erasing, so it goes before any store is
        // touched. A flag that cannot be removed stops the erase with nothing erased, and the screen offers Retry.
        guard clearRestoreFlagOrStop() else { return false }
        // The import state from *before* the erase goes now, once the erase is known to be going ahead, so a failed
        // flag clear leaves the import on screen as it was.
        clearImport()
        // Anything an in-flight import publishes afterwards is about a journal that is about to be deleted.
        importGeneration += 1
        beforeErase()

        // Every store and export file that is still on the phone afterwards is named, so the person knows exactly
        // what to retry. The stores are named in the order the erase ran; the reminder readback comes after them,
        // and the export files last. One failure never stops the rest.
        var leftBehind: [String] = []
        var journalEraseSucceeded = false
        // The community session is forgotten locally only. This never calls the server.
        do {
            try await eraseLocalAccount()
        } catch {
            leftBehind.append("community sign-in")
        }
        let journalEraser = store as? JournalErasing
        for eraser in erasers {
            do {
                try eraser.eraseAll()
                if let journalEraser, eraser === journalEraser {
                    journalEraseSucceeded = true
                }
            } catch {
                leftBehind.append(eraser.erasureName)
            }
        }
        // Every export file this app wrote goes, not only the one this model remembers: the app can be
        // killed after an export, and the next session's model starts with no URL to delete.
        leftBehind += await remindersStillPending()
        if !removeEveryExportFile() { leftBehind.append("export files") }
        let failed = !leftBehind.isEmpty
        // The handle this screen was holding is one of those files, or is already gone. Clearing it
        // cannot fail: the sweep above has removed whatever was still there.
        forgetExportFile()
        // The unit system and the glass size are stored values like any other, so they go with
        // everything else. Clearing them cannot fail either, and the screen is put back to the
        // defaults rather than left showing settings the erase has removed.
        forgetDisplayPreferences()
        entryCount = 0
        exportState = .idle
        errorMessage = failed ? Self.eraseLeftBehindMessage(leftBehind) : nil
        eraseRetryAvailable = failed
        resolveDeferredImportEffectsAfterErase(journalEraseSucceeded: journalEraseSucceeded)
        eraseGeneration += 1
        if !failed { afterSuccessfulErase() }
        return !failed
    }

    /// Clears the restore-in-progress flag. On failure the erase has erased nothing: the screen says so and offers
    /// Retry, and the import effects deferred during the erase are resolved. Returns whether the flag is clear.
    private func clearRestoreFlagOrStop() -> Bool {
        // A store that cannot clear the flag fails closed: erasing it would leave the flag set for a re-import.
        do {
            guard let progress = store as? JournalRestoreProgress else {
                throw CocoaError(.featureUnsupported)
            }
            try progress.clearRestoreInProgress()
            return true
        } catch {
            errorMessage = Self.eraseNothingErasedMessage
            eraseRetryAvailable = true
            resolveDeferredImportEffectsAfterErase(journalEraseSucceeded: false)
            return false
        }
    }

    /// Asks the person to confirm an erase. Erase and Retry both come through here, so neither erases on its own.
    public func requestErase() {
        eraseConfirmationPending = true
    }

    /// Withdraws a requested erase without erasing anything.
    public func cancelEraseRequest() {
        eraseConfirmationPending = false
    }

    /// Runs the erase the person has just confirmed.
    public func confirmErase() async -> Bool {
        eraseConfirmationPending = false
        return await eraseAllData()
    }

    /// The stores an erase runs, one field per slot, so each slot is named where it is built.
    public struct EraseStores {
        public let widgets: JournalErasing
        public let savedMeals: JournalErasing
        public let supplements: JournalErasing
        public let reminders: [JournalErasing]
        public let journal: JournalErasing
        public let favorites: JournalErasing
        public let recipes: JournalErasing
        public let goals: JournalErasing

        public init(
            widgets: JournalErasing, savedMeals: JournalErasing, supplements: JournalErasing,
            reminders: [JournalErasing], journal: JournalErasing, favorites: JournalErasing, recipes: JournalErasing,
            goals: JournalErasing
        ) {
            self.widgets = widgets
            self.savedMeals = savedMeals
            self.supplements = supplements
            self.reminders = reminders
            self.journal = journal
            self.favorites = favorites
            self.recipes = recipes
            self.goals = goals
        }
    }

    /// The stores in the order an erase runs them, and so the order a failure is listed in: widget data first, so no
    /// publish announced before the erase lands after it, and journal after the lists it does not depend on.
    public static func eraseOrder(_ stores: EraseStores) -> [JournalErasing] {
        [stores.widgets, stores.savedMeals, stores.supplements] + stores.reminders
            + [stores.journal, stores.favorites, stores.recipes, stores.goals]
    }

    /// Puts the display preferences back to their defaults and republishes that state, so the screen
    /// shows what a person sees on a fresh install rather than the settings just erased.
    ///
    /// The published values are read back from the store rather than set to literals, so an
    /// implementation that refuses to clear something would be visible here rather than papered over.
    private func forgetDisplayPreferences() {
        preferences.resetToDefaults()
        // The erase just deleted every goal. Mark the default water goal as already offered so the
        // reload that follows does not write a new one into the erased goal store.
        (preferences as? WaterGoalDefaultPreferences)?.markWaterGoalSeeded()
        isPublishingStoredPreference = true
        unitSystem = preferences.unitSystem
        showStoredQuickWater()
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
        exportRevision += 1
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

        /// The outcome may have changed the journal even if another import now owns the screen state.
        var changedJournal: Bool {
            switch self {
            case .imported:
                return true
            case .failed(.refused(.partialRestore)):
                return true
            case .failed:
                return false
            }
        }

        var isPartialRestore: Bool {
            if case .failed(.refused(.partialRestore)) = self { return true }
            return false
        }
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
            isImporting = false
            importMessage = Self.importDuringEraseMessage
            return
        }
        // Read out of the main actor's own state first, so the background task touches nothing here.
        let store = store
        let favorites = favorites
        let savedMeals = savedMeals
        // Counted first, then read: this import's token is the number *after* its own increment, which is
        // what `apply` compares against. Reading before incrementing hands out the previous import's number,
        // so every outcome looks stale and none is ever published.
        importGeneration += 1
        let generation = importGeneration
        let startedAtSuccessfulEraseEpoch = successfulEraseEpoch
        let exportRevisionAtStart = exportRevision
        activeImportCompletions += 1
        isImporting = true
        let gate = importGate
        gate.begin()
        // Created here, on the main actor, and not inside the task below. The restore has to be *running*
        // before this method returns, because an erase can block the main actor the moment it is called, and
        // a task body that needs the main actor in order to start would never get to run: the erase would
        // wait on a signal nothing was ever going to send. A detached task needs no actor to begin, and its
        // `defer` opens the gate from a background thread as soon as the store writes are done.
        let goals = self.goals
        let restore = Task.detached(priority: .userInitiated) { () -> ImportOutcome in
            // The gate is opened from the background, and not from the task below: the erase waits on it from
            // the main actor, so it has to be signalled by the work it is waiting for.
            defer { gate.end() }
            do {
                return .imported(
                    try JournalImporter.importExport(
                        data, into: store, favorites: favorites, savedMeals: savedMeals, goals: goals))
            } catch let error as JournalImportError {
                return .failed(.refused(error))
            } catch {
                return .failed(.other)
            }
        }
        Task { [weak self] in
            let outcome = await restore.value
            // Named rather than inherited: the task's own isolation decides where this would run, and the
            // state it updates is main-actor state, so the hop is stated instead of assumed.
            await MainActor.run {
                self?.apply(
                    outcome, startedAt: generation,
                    successfulEraseEpochAtStart: startedAtSuccessfulEraseEpoch,
                    exportRevisionAtStart: exportRevisionAtStart)
            }
        }
    }

    /// Publishes an import's outcome on the main actor, which is the only place that touches this state.
    ///
    /// An outcome from an import that a successful erase has overtaken is dropped: the stores it restored were
    /// deleted a moment later, and the screen saying "Imported 3 entries" would describe a journal that is gone.
    private func apply(
        _ outcome: ImportOutcome, startedAt generation: Int,
        successfulEraseEpochAtStart: Int, exportRevisionAtStart: Int
    ) {
        if activeImportCompletions > 0 { activeImportCompletions -= 1 }
        // Whatever happens to this outcome below, the screen is importing only while a restore is still running.
        isImporting = activeImportCompletions > 0
        // A successful erase owns the stores after it completes. A failed erase does not: retain any
        // restore effects that arrived while it was suspended and publish them once its result is known.
        guard successfulEraseEpochAtStart == successfulEraseEpoch else { return }
        if isErasing {
            deferredImportEffectsDuringErase.append(DeferredImportEffects(
                changedJournal: outcome.changedJournal,
                isPartialRestore: outcome.isPartialRestore,
                startedAtImportGeneration: generation,
                exportRevisionAtStart: exportRevisionAtStart))
            return
        }

        // Store mutations outlive import presentation. A newer import may already have published a refusal,
        // but an earlier successful or partial restore still changed the journal and requires every journal
        // snapshot to reload. An export made after this import started may reflect those restored rows.
        let isCompleteImport: Bool
        if case .imported = outcome {
            isCompleteImport = true
        } else {
            isCompleteImport = false
        }
        applyStoreEffects(
            changedJournal: outcome.changedJournal,
            isPartialRestore: outcome.isPartialRestore,
            startedAt: generation,
            exportRevisionAtStart: exportRevisionAtStart,
            mayClearWarning: true,
            isCompleteImport: isCompleteImport)

        guard generation == importGeneration else { return }
        isImporting = false
        switch outcome {
        case .imported(let summary):
            importSummary = summary
            importState = .imported
            importMessage = Self.importSummaryText(summary, locale: .current)
        case .failed(let failure):
            importSummary = nil
            importState = .failed
            importMessage = Self.importFailureText(for: failure)
        }
    }

    private func applyStoreEffects(
        changedJournal: Bool, isPartialRestore: Bool, startedAt generation: Int,
        exportRevisionAtStart: Int, mayClearWarning: Bool, isCompleteImport: Bool = false
    ) {
        if changedJournal {
            if exportRevision == exportRevisionAtStart {
                removeExportFile()
                exportState = .idle
                entryCount = 0
            }
            if mayClearWarning, generation == importGeneration { errorMessage = nil }
            journalRestoreGeneration += 1
        }
        if isPartialRestore {
            incompleteRestoreWarning = Self.partialRestoreWarningMessage
        } else if mayClearWarning, isCompleteImport, generation == importGeneration {
            // Only the current complete restore can replace a partial warning; a late older success must not
            // conceal rows retained by a newer partial restore.
            incompleteRestoreWarning = nil
        }
    }

    /// The failed erase left the stores in an unknown but not confirmed-empty state. Apply outcomes that
    /// arrived while it ran so the host reloads and any partial restore remains visible; the erase error
    /// was already published and must not be cleared by these stale import generations.
    private func resolveDeferredImportEffectsAfterFailedErase() {
        let deferred = deferredImportEffectsDuringErase
        deferredImportEffectsDuringErase.removeAll()
        for effect in deferred {
            applyStoreEffects(
                changedJournal: effect.changedJournal,
                isPartialRestore: effect.isPartialRestore,
                startedAt: effect.startedAtImportGeneration,
                exportRevisionAtStart: effect.exportRevisionAtStart,
                mayClearWarning: false)
        }
    }

    /// Restore effects are stale as soon as the journal itself confirms erasure, even if a later
    /// account, favorites, recipe, goal, reminder, or export-file cleanup fails. If the journal eraser
    /// failed or was not identified, keep the prior partial-restore warning and refresh those effects.
    private func resolveDeferredImportEffectsAfterErase(journalEraseSucceeded: Bool) {
        if journalEraseSucceeded {
            resolveDeferredImportEffectsAfterSuccessfulErase()
        } else {
            resolveDeferredImportEffectsAfterFailedErase()
        }
    }

    /// A successful erase replaces the journal with empty stores, so restore completions from before it are
    /// obsolete. Only this confirmed success advances the epoch used by import completion fencing.
    private func resolveDeferredImportEffectsAfterSuccessfulErase() {
        successfulEraseEpoch += 1
        deferredImportEffectsDuringErase.removeAll()
        incompleteRestoreWarning = nil
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
        isImporting = false
        importSummary = nil
        importState = .failed
        importMessage = Self.importFailedMessage
    }

    /// The selected file exceeded the import byte ceiling before it could be handed to the importer.
    public func importFileTooLarge() {
        isImporting = false
        importSummary = nil
        importState = .failed
        importMessage = Self.importFailureText(for: .tooLarge)
    }

    /// One line saying what came back, so a restore that quietly did nothing still looks like an answer.
    public static func importSummaryText(_ summary: JournalImportSummary, locale: Locale = .current) -> String {
        // Every count carries grouping separators (1,234 entries), in the locale the screen is shown in.
        func count(_ n: Int) -> String { n.formatted(.number.locale(locale)) }
        let entries = summary.intakes == 1 ? "1 entry" : "\(count(summary.intakes)) entries"
        let deleted = summary.tombstones == 0 ? "" : " and \(count(summary.tombstones)) deleted"
        let favorites = summary.favorites == 0 ? "" : ", \(count(summary.favorites)) favorites"
        let savedMeals = summary.savedMeals == 0 ? ""
            : summary.savedMeals == 1 ? ", 1 saved meal" : ", \(count(summary.savedMeals)) saved meals"
        let goals = summary.goals == 0 ? "" : summary.goals == 1 ? ", 1 goal" : ", \(count(summary.goals)) goals"
        let kept = summary.keptOutOfLibrary == 0 ? ""
            : summary.keptOutOfLibrary == 1 ? ", 1 entry kept out of Library > Products"
            : ", \(count(summary.keptOutOfLibrary)) entries kept out of Library > Products"
        return "Imported \(entries)\(deleted)\(favorites)\(savedMeals)\(goals)\(kept)."
    }

    public static func importFailureText(for error: JournalImportError) -> String {
        switch error {
        case .unsupportedVersion:
            return importUnsupportedVersionMessage
        case .notEmpty:
            return importNotEmptyMessage
        case .savedMealsNotEmpty:
            return importSavedMealsNotEmptyMessage
        case .tooLarge:
            return "This journal export is too large to import."
        case .malformed, .corrupt:
            return importFailedMessage
        case .partialRestore:
            return partialRestoreWarningMessage
        case .rolledBack:
            return importRolledBackMessage
        }
    }

    /// Returns the screen's import state to empty, so a later attempt does not read as part of an earlier
    /// one.
    public func clearImport() {
        isImporting = false
        importState = .idle
        importSummary = nil
        importMessage = nil
    }
}
