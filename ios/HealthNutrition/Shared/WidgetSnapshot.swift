import Foundation
import os

/// What the Today widgets show: the day's figures as plain numbers, written by the app and read by the
/// widget extension. It is a summary, not the journal: no entry, product name, time or note is in it.
struct WidgetSnapshot: Codable, Equatable {
    var generatedAt: Date
    /// Whether the day holds any entry. False draws the "Nothing logged today" state instead of zeros.
    var hasEntries: Bool
    var energyKcal: Double?
    var energyGoalKcal: Double?
    var proteinGrams: Double?
    var carbohydrateGrams: Double?
    var fatGrams: Double?
    var waterMilliliters: Double?
    /// Whether the person reads US customary units, so water is drawn in fluid ounces. Absent in a summary written
    /// before this field existed, which is read as metric.
    var usUnits: Bool?
    /// The figures that are only the known part of the day because some entries have no values ("energy",
    /// "protein", "carbohydrate", "fat"). Absent or empty means every figure is a whole-day figure. A figure listed
    /// here is drawn with a trailing "+" and spoken as "at least".
    var partialFigures: [String]?
    /// Calories left today (goal less food plus counted burned). Nil without a goal or a known food total; never
    /// zero for "unknown".
    var remainingKcal: Double?
    /// Calories burned today, present only when the person counts activity and Health has a reading.
    var burnedKcal: Double?
    /// True when `remainingKcal` is an upper bound because some entries have no calories.
    var remainingIsPartial: Bool?

    func isPartial(_ figure: String) -> Bool { partialFigures?.contains(figure) == true }

    /// A summary with nothing in it: no entries and no figures, as after Erase all data.
    static func empty(at time: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: time, hasEntries: false, energyKcal: nil, energyGoalKcal: nil, proteinGrams: nil,
            carbohydrateGrams: nil, fatGrams: nil, waterMilliliters: nil)
    }

    /// Whether this summary was written on the same local day as `now`. After midnight, with the app closed, the
    /// file still holds yesterday's totals; the widget must not present them as today's.
    func isCurrent(on now: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(generatedAt, inSameDayAs: now)
    }

    /// The next local midnight, when today's summary stops being today's.
    static func nextMidnight(from now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
    }

    /// Shortly after the next local midnight, when a refresh drops yesterday's summary.
    static func refreshAfterMidnight(from now: Date, calendar: Calendar = .current) -> Date {
        nextMidnight(from: now, calendar: calendar).addingTimeInterval(60)
    }

    /// How much of the energy goal is reached, 0 through 1, or nil without a known total and a goal.
    var energyFraction: Double? {
        guard let energyKcal, let energyGoalKcal, energyGoalKcal > 0, energyKcal.isFinite, energyGoalKcal.isFinite
        else { return nil }
        return min(max(energyKcal / energyGoalKcal, 0), 1)
    }
}

/// The App Group the app and its widgets share, named after the app's own bundle identifier so a
/// differently-signed build gets its own group. The Watch app and its widgets name the same group (a group
/// identifier is shared across devices by name; each device keeps its own container).
enum WidgetAppGroup {
    private static let extensionSuffix = ".widgets"
    private static let watchSuffix = ".watchkitapp"

    /// `group.<app bundle id>`. The widget extension's bundle id is the app's plus `.widgets`, so in the extension
    /// that one suffix is removed and both processes name the same group. The Watch app's is the app's plus
    /// `.watchkitapp` and its widgets' that plus `.widgets`, removed the same way. The app's own identifier is used
    /// as it is, even when it happens to end in `.widgets`.
    static func identifier(forBundleIdentifier bundleIdentifier: String, isExtension: Bool, isWatch: Bool = false)
        -> String
    {
        var base = bundleIdentifier
        if isExtension, base.hasSuffix(extensionSuffix) { base.removeLast(extensionSuffix.count) }
        if isWatch, base.hasSuffix(watchSuffix) { base.removeLast(watchSuffix.count) }
        return "group." + base
    }

    static var current: String? {
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        #if os(watchOS)
        let isWatch = true
        #else
        let isWatch = false
        #endif
        return Bundle.main.bundleIdentifier.map {
            identifier(forBundleIdentifier: $0, isExtension: isExtension, isWatch: isWatch)
        }
    }
}

/// How the widget writes a figure: a whole number, or nothing when the value is missing, not finite, or too large
/// to be a daily total (so the conversion to Int below can never trap).
enum WidgetFigure {
    static let largest = 1_000_000_000.0
    static let millilitersPerUSFluidOunce = 29.5735295625

    /// A whole number in the person's number format ("1,200"), as Today draws its calorie figures, or nil when the
    /// value is missing, not finite or too large to be a daily total.
    static func groupedWholeNumber(_ value: Double?) -> String? {
        guard let value, value.isFinite, abs(value) <= largest else { return nil }
        // Adding zero turns a rounded -0 into 0, so a hair under zero never reads "-0".
        return (value.rounded() + 0).formatted(.number.precision(.fractionLength(0)))
    }

    /// A bare whole number, "+" after it when it is only the known part of the day, or a dash.
    static func number(_ value: Double?, partial: Bool = false) -> String {
        guard let text = wholeNumber(value) else { return "—" }
        return partial ? text + "+" : text
    }

    /// A whole-number figure with its unit, "+" after the number when it is only the known part of the day.
    static func figure(_ value: Double?, unit: String, partial: Bool = false) -> String {
        guard let text = wholeNumber(value) else { return "—" }
        return text + (partial ? "+" : "") + " " + unit
    }

    /// Water as the person reads it: whole fluid ounces under US units, whole millilitres otherwise; dashes when the
    /// value is missing or cannot be shown.
    static func water(_ milliliters: Double?, usUnits: Bool?) -> String {
        if usUnits == true {
            guard let milliliters, milliliters.isFinite else { return "—" }
            let ounces = milliliters / millilitersPerUSFluidOunce
            // A sip is still water: under half an ounce it reads "<1" rather than a rounded 0.
            if ounces > 0, ounces < 0.5 { return "<1 fl oz" }
            return (wholeNumber(ounces) ?? "—") + " fl oz"
        }
        return (wholeNumber(milliliters) ?? "—") + " mL"
    }

    static func wholeNumber(_ value: Double?) -> String? {
        guard let value, value.isFinite, abs(value) <= largest else { return nil }
        return String(Int(value.rounded()))
    }
}

/// Reads and writes the snapshot file in a directory. The directory is the App Group container in the app and
/// in the widget; a test passes a temporary one.
struct WidgetSnapshotStore {
    static let fileName = "today-widget.json"
    /// The summary lives in its own folder inside the App Group container, and that folder is what is left out of
    /// device backups: everything in it, a temporary included, is excluded from the moment it exists, so no step
    /// of a write can leave a figure in a backup.
    static let folderName = "WidgetSummary"

    let directory: URL
    var fileManager: FileManager = .default
    /// How the bytes reach a file. A parameter so a test can make the write fail.
    var writeData: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
    }
    /// Leaves a folder out of device backups. A parameter so a test can make it fail.
    var excludeFromBackup: (URL) throws -> Void = { url in
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// The store in the App Group container, or nil where the group is not available (an unsigned
    /// simulator build without the entitlement, for instance), in which case nothing is written.
    static func appGroup(fileManager: FileManager = .default) -> WidgetSnapshotStore? {
        guard let group = WidgetAppGroup.current,
            let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return WidgetSnapshotStore(directory: url, fileManager: fileManager)
    }

    private var folderURL: URL { directory.appendingPathComponent(Self.folderName, isDirectory: true) }
    private var fileURL: URL { folderURL.appendingPathComponent(Self.fileName) }
    /// Where a new summary is written before it replaces the file. A fixed name inside the folder.
    private var temporaryURL: URL { folderURL.appendingPathComponent(Self.fileName + ".tmp") }

    func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Makes sure the folder exists and is left out of backups before anything is put in it. If it cannot be left
    /// out the folder is removed again and the call throws, so a summary is never stored where a backup would
    /// take it.
    private func prepareFolder() throws {
        if !fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.createDirectory(
                at: folderURL, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        do {
            try excludeFromBackup(folderURL)
        } catch {
            // Not left behind where a backup could take it. If even the removal fails that is the failure reported.
            try fileManager.removeItem(at: folderURL)
            throw error
        }
    }

    /// Written with file protection until first unlock, to a fixed temporary name in the excluded folder and then
    /// moved over the file, so the widget never reads half a file.
    func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try prepareFolder()
        let temporary = temporaryURL
        do {
            try writeData(data, temporary)
            // The folder is what is excluded; the files are flagged as well, so each one reads back as excluded.
            try? excludeFromBackup(temporary)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
            try? excludeFromBackup(fileURL)
        } catch {
            // Whatever the failure, no half-written temporary stays; the previous summary is as it was.
            try? fileManager.removeItem(at: temporary)
            let logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "HealthNutrition", category: "widget-summary")
            logger.error("Could not write the summary: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Removes the whole folder: the summary and any temporary an interrupted write left. Throws if it is still
    /// there afterwards, so an erase never reports success with a figure on disk.
    func erase() throws {
        // Both are attempted; a legacy file that cannot be removed is reported after the folder has been dealt with.
        let legacy = Result { try removeLegacyRootFiles() }
        let folder = Result { () throws -> Void in
            guard fileManager.fileExists(atPath: folderURL.path) else { return }
            try fileManager.removeItem(at: folderURL)
            if fileManager.fileExists(atPath: folderURL.path) { throw CocoaError(.fileWriteUnknown) }
        }
        // The folder's failure is reported first; either one fails the erase.
        try folder.get()
        try legacy.get()
    }

    /// A summary an earlier build kept directly in the container instead of the folder, if there is one. Erase all
    /// data removes it on every path, not only when the folder has to be removed. Throws if one is still there
    /// afterwards, so an erase never reports success with a figure on disk; a file that is not there is fine.
    func removeLegacyRootFiles() throws {
        var failure: Error?
        for name in [Self.fileName, Self.fileName + ".tmp"] {
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failure = failure ?? error
            }
            if fileManager.fileExists(atPath: url.path) { failure = failure ?? CocoaError(.fileWriteUnknown) }
        }
        if let failure { throw failure }
    }

    /// Removes a temporary left by an interrupted write, when the app starts. Best effort: it is inside the
    /// excluded folder and the next write or an erase replaces or removes it anyway.
    func removeStaleTemporary() {
        try? fileManager.removeItem(at: temporaryURL)
    }

    /// Last resort when the folder cannot be removed: empties the summary file in place (and removes the temporary
    /// if it can), so no figure is left in the summary. The widget treats a file it cannot decode as "no summary" and shows dashes.
    func truncate() throws {
        // The temporary is removed if it can be; emptying the summary does not wait on it.
        try? fileManager.removeItem(at: temporaryURL)
        try Data().write(to: fileURL)
    }
}
