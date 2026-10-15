import Foundation

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

    /// `group.<app bundle id>`. The widget extension's bundle id is the app's plus `.widgets`, so the suffix
    /// is removed and both processes name the same group.
    static func identifier(forBundleIdentifier bundleIdentifier: String) -> String {
        var base = bundleIdentifier
        if base.hasSuffix(extensionSuffix) { base.removeLast(extensionSuffix.count) }
        return "group." + base
    }

    static var current: String? {
        Bundle.main.bundleIdentifier.map { identifier(forBundleIdentifier: $0) }
    }
}

/// Reads and writes the snapshot file in a directory. The directory is the App Group container in the app and
/// in the widget; a test passes a temporary one.
struct WidgetSnapshotStore {
    static let fileName = "today-widget.json"

    let directory: URL
    var fileManager: FileManager = .default

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
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func erase() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
