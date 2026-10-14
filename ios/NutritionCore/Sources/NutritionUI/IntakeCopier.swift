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
/// An entry whose time zone names no zone has no day and is never copied.
public struct IntakeCopier {
    private let store: JournalStore
    private let makeID: () -> String
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
        self.makeID = makeID
    }

    /// The `yyyy-MM-dd` key of the day before `now`, in the copier's zone. What "copy yesterday" reads.
    public func yesterdayKey(now: Date) -> String {
        Self.yesterdayKey(now: now, zoneIdentifier: zoneID())
    }

    private static func yesterdayKey(now: Date, zoneIdentifier: String) -> String {
        let zone = TimeZone(identifier: zoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let earlier = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        return Self.dayKey(earlier, zoneIdentifier: zone.identifier) ?? ""
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
        try run(dayKey: { _ in dayKey }, meal: nil, now: now)
    }

    /// Copies the entries of one meal of `dayKey` to `now`.
    @discardableResult
    public func copyMeal(_ meal: MealSelector, dayKey: String, now: Date) throws -> IntakeCopyResult {
        try run(dayKey: { _ in dayKey }, meal: meal, now: now)
    }

    /// Copies yesterday's whole log to `now`.
    @discardableResult
    public func copyYesterday(now: Date) throws -> IntakeCopyResult {
        try run(dayKey: { Self.yesterdayKey(now: now, zoneIdentifier: $0) }, meal: nil, now: now)
    }

    /// Active entries whose zone names no zone and whose instant falls on `dayKey` in the copier's zone: they cannot be placed on a
    /// local day, so a copy of that day reports them as skipped rather than silently dropping them.
    private func unreadableZoneCount(dayKey: String, meal: MealSelector?, destination: String) throws -> Int {
        try store.activeIntakes()
            .filter { $0.lifecycle == .active && TimeZone(identifier: $0.timeZoneIdentifier) == nil }
            .filter { Self.dayKey($0.occurredAt, zoneIdentifier: destination) == dayKey }
            .filter { meal?.matches($0.meal) ?? true }
            .count
    }

    /// `dayKey` is given the one destination zone the batch uses, so "yesterday" and the zone the copies are
    /// written in always come from the same answer of the provider.
    private func run(dayKey keyForZone: (String) -> String, meal: MealSelector?, now: Date) throws
        -> IntakeCopyResult
    {
        // One zone for the whole batch: the provider is asked once, validated, then fixed.
        let destination = zoneID()
        guard TimeZone(identifier: destination) != nil else { throw IntakeCopyError.invalidDestinationZone }
        let dayKey = keyForZone(destination)
        return try copy(
            try sources(dayKey: dayKey, meal: meal), now: now, destination: destination,
            unreadableZone: try unreadableZoneCount(dayKey: dayKey, meal: meal, destination: destination))
    }

    private func copy(_ intakes: [Intake], now: Date, destination: String, unreadableZone: Int) throws
        -> IntakeCopyResult
    {
        let repeater = IntakeRepeater(store: store, timeZoneProvider: { destination }, makeID: makeID)
        var created: [String] = []
        var skipped = unreadableZone
        for intake in intakes {
            do {
                created.append(try repeater.create(repeating: intake, now: now))
            } catch IntakeRepeatError.productUnavailable {
                skipped += 1
            } catch JournalError.corruptRecord {
                skipped += 1
            } catch JournalError.noComponents, JournalError.emptyCategory {
                // An entry written before the store refused these states is a bad source, not a store failure.
                skipped += 1
            } catch {
                // A store failure is not a bad source: stop, and say what was already written.
                throw IntakeCopyError.stoppedEarly(
                    IntakeCopyResult(createdIDs: created, skippedCount: skipped), underlying: error)
            }
        }
        return IntakeCopyResult(createdIDs: created, skippedCount: skipped)
    }

    /// Nil for a zone identifier that names no zone: such an entry has no day, so it matches none.
    static func dayKey(_ date: Date, zoneIdentifier: String) -> String? {
        guard let zone = TimeZone(identifier: zoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// A copy that stopped on a store failure: what was already written is not undone.
public enum IntakeCopyError: Error {
    case stoppedEarly(IntakeCopyResult, underlying: Error)
    /// The zone new entries would be written in names no zone; nothing was written.
    case invalidDestinationZone
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
