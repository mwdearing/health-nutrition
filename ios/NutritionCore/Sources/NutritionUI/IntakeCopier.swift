import Foundation
import NutritionDomain
import NutritionJournal

/// What one copy did: the new entries and how many source entries could not be copied.
public struct IntakeCopyResult: Equatable, Sendable {
    /// The ids of the new intakes, in the order the source entries were copied.
    public let createdIDs: [String]
    /// Source entries left out because their product is gone or their record could not be read.
    public let skippedCount: Int

    public init(createdIDs: [String], skippedCount: Int) {
        self.createdIDs = createdIDs
        self.skippedCount = skippedCount
    }

    public var copiedCount: Int { createdIDs.count }
}

/// Copies a whole day, or one meal of a day, into the present as new entries.
///
/// Each copy is a NEW intake built by the same repeater a single "repeat" uses: new id, the time of
/// the copy, the current time zone, the source's amounts and product snapshot. The source entries are
/// never touched. A source that cannot be copied is skipped and counted, and the rest are still copied.
public struct IntakeCopier {
    private let store: JournalStore
    private let repeater: IntakeRepeater
    private let zoneID: () -> String

    public init(
        store: JournalStore,
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        let resolved = IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider)
        self.zoneID = resolved
        self.repeater = IntakeRepeater(store: store, timeZoneProvider: resolved, makeID: makeID)
    }

    /// The `yyyy-MM-dd` key of the day before `now`, in the copier's zone. What "copy yesterday" reads.
    public func yesterdayKey(now: Date) -> String {
        let zone = TimeZone(identifier: zoneID()) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let earlier = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        return Self.dayKey(earlier, zoneIdentifier: zone.identifier)
    }

    /// The entries of one day, oldest first, that a copy would read.
    ///
    /// Each entry's day is the local day of its OWN time zone, the same rule the Journal groups by.
    public func sources(dayKey: String, meal: MealSelector? = nil) throws -> [Intake] {
        try store.activeIntakes()
            .filter { $0.lifecycle == .active }
            .filter { Self.dayKey($0.occurredAt, zoneIdentifier: $0.timeZoneIdentifier) == dayKey }
            .filter { meal?.matches($0.meal) ?? true }
            .sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
    }

    /// Copies every entry of `dayKey` to `now`. A day with no entries copies nothing.
    @discardableResult
    public func copyDay(dayKey: String, now: Date) throws -> IntakeCopyResult {
        try copy(try sources(dayKey: dayKey), now: now)
    }

    /// Copies the entries of one meal of `dayKey` to `now`.
    @discardableResult
    public func copyMeal(_ meal: MealSelector, dayKey: String, now: Date) throws -> IntakeCopyResult {
        try copy(try sources(dayKey: dayKey, meal: meal), now: now)
    }

    /// Copies yesterday's whole log to `now`.
    @discardableResult
    public func copyYesterday(now: Date) throws -> IntakeCopyResult {
        try copyDay(dayKey: yesterdayKey(now: now), now: now)
    }

    private func copy(_ intakes: [Intake], now: Date) throws -> IntakeCopyResult {
        var created: [String] = []
        var skipped = 0
        for intake in intakes {
            do {
                created.append(try repeater.create(repeating: intake, now: now))
            } catch IntakeRepeatError.productUnavailable {
                skipped += 1
            } catch JournalError.corruptRecord {
                skipped += 1
            }
        }
        return IntakeCopyResult(createdIDs: created, skippedCount: skipped)
    }

    static func dayKey(_ date: Date, zoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneIdentifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Which meal of a day to copy: one of the four named meals, or Other (no meal, or one the four do not name).
public enum MealSelector: Equatable, Sendable {
    case named(MealLabel)
    case other

    func matches(_ stored: String?) -> Bool {
        let key = MealLabel.identityKeyPart(for: stored)
        switch self {
        case .named(let label): return key == label.rawValue
        case .other: return key.flatMap { MealLabel(rawValue: $0) } == nil
        }
    }
}
