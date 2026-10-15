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

    /// Shortly after the next local midnight, when a refresh drops yesterday's summary.
    static func refreshAfterMidnight(from now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let midnight = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        return midnight.addingTimeInterval(60)
    }

    /// How much of the energy goal is reached, 0 through 1, or nil without a known total and a goal.
    var energyFraction: Double? {
        guard let energyKcal, let energyGoalKcal, energyGoalKcal > 0, energyKcal.isFinite, energyGoalKcal.isFinite
        else { return nil }
        return min(max(energyKcal / energyGoalKcal, 0), 1)
    }
}

/// The App Group the app and its widgets share, named after the app's own bundle identifier so a
/// differently-signed build gets its own group.
enum WidgetAppGroup {
    private static let extensionSuffix = ".widgets"

    /// `group.<app bundle id>`. The widget extension's bundle id is the app's plus `.widgets`, so in the extension
    /// that one suffix is removed and both processes name the same group. The app's own identifier is used as it
    /// is, even when it happens to end in `.widgets`.
    static func identifier(forBundleIdentifier bundleIdentifier: String, isExtension: Bool) -> String {
        var base = bundleIdentifier
        if isExtension, base.hasSuffix(extensionSuffix) { base.removeLast(extensionSuffix.count) }
        return "group." + base
    }

    static var current: String? {
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        return Bundle.main.bundleIdentifier.map { identifier(forBundleIdentifier: $0, isExtension: isExtension) }
    }
}

/// How the widget writes a figure: a whole number, or nothing when the value is missing, not finite, or too large
/// to be a daily total (so the conversion to Int below can never trap).
enum WidgetFigure {
    static let largest = 1_000_000_000.0

    static func wholeNumber(_ value: Double?) -> String? {
        guard let value, value.isFinite, abs(value) <= largest else { return nil }
        return String(Int(value.rounded()))
    }
}

/// Reads and writes the snapshot file in a directory. The directory is the App Group container in the app and
/// in the widget; a test passes a temporary one.
struct WidgetSnapshotStore {
    static let fileName = "today-widget.json"

    let directory: URL
    var fileManager: FileManager = .default
    /// How the bytes reach the file. A parameter so a test can make the write fail.
    var writeData: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The store in the App Group container, or nil where the group is not available (an unsigned
    /// simulator build without the entitlement, for instance), in which case nothing is written.
    static func appGroup(fileManager: FileManager = .default) -> WidgetSnapshotStore? {
        guard let group = WidgetAppGroup.current,
            let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return WidgetSnapshotStore(directory: url, fileManager: fileManager)
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Written with file protection until first unlock, so it is not readable before the device was first
    /// unlocked after a restart, and replaced atomically so the widget never reads half a file.
    func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try writeData(data, fileURL)
        // Rewritten at every load, so it is left out of device backups. A failure is logged (the error text, never
        // a figure) rather than swallowed.
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "HealthNutrition", category: "widget-summary")
                .error("Could not leave the summary out of backups: \(error.localizedDescription, privacy: .public)")
        }
    }

    func erase() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
