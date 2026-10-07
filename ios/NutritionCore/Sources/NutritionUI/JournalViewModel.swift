import Foundation
import NutritionDomain
import NutritionJournal

public struct JournalRow: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let occurredAt: Date
    public let timeZoneIdentifier: String
    /// The meal as words, or nil when the entry states none. Carried on the row so the screens that
    /// list an entry can say which meal it was without reading the journal again.
    public let meal: String?

    /// What a screen reader reads for one row: the name, the amounts, and the meal when it has one.
    public var accessibilityText: String {
        guard let meal else { return "\(title), \(detail)" }
        return "\(title), \(detail), \(meal)"
    }
}

public struct JournalDaySection: Equatable, Identifiable {
    /// Local day in the intakes' own time zone, as yyyy-MM-dd.
    public let id: String
    /// Locale-formatted day (medium date style) in the intakes' own time zone.
    public let title: String
    public let rows: [JournalRow]
    /// What this day adds up to, summed from the same intakes as the rows above and never from
    /// another day.
    public let totals: DailyTotals
    /// One compact line for the day: each tracked nutrient against its target where one is set.
    public let totalsText: String
}

@MainActor
public final class JournalViewModel: ObservableObject {
    @Published public private(set) var sections: [JournalDaySection] = []
    /// Intakes left out because their time zone identifier is invalid or their record could not be read.
    @Published public private(set) var skippedCount: Int = 0
    @Published public private(set) var errorMessage: String?

    private let store: JournalStore
    private let lookup: NutrientFactsLookup
    /// The goals each day's line compares against. Optional, so a caller with no goal store still
    /// gets the per-day totals.
    private let goals: GoalStore?
    private let repeater: IntakeRepeater
    private let locale: Locale

    public init(
        store: JournalStore,
        goals: GoalStore? = nil,
        lookup: NutrientFactsLookup = UnknownNutrientFacts(),
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        locale: Locale = .current,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.lookup = lookup
        self.goals = goals
        self.locale = locale
        self.repeater = IntakeRepeater(
            store: store, timeZoneProvider: IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider),
            makeID: makeID)
    }

    /// Groups active intakes by the local day of each intake's own time zone, newest first.
    public func load(now: Date) {
        do {
            var skipped = 0
            var groups: [String: [JournalRow]] = [:]
            var titles: [String: String] = [:]
            // The intakes of each day, kept beside the rows so the day's totals are summed from
            // exactly the entries the rows below were built from. Nothing here ever sees two days.
            var intakesByDay: [String: [Intake]] = [:]
            for intake in try store.activeIntakes() where intake.lifecycle == .active {
                guard let zone = TimeZone(identifier: intake.timeZoneIdentifier) else {
                    skipped += 1
                    continue
                }
                guard let revisions = try? store.revisions(of: intake.id),
                    let current = revisions.first(where: { $0.number == intake.currentRevision })
                else {
                    skipped += 1
                    continue
                }
                let row = JournalRow(
                    id: intake.id, title: AmountText.title(current.components),
                    detail: AmountText.summary(current.components), occurredAt: intake.occurredAt,
                    timeZoneIdentifier: intake.timeZoneIdentifier,
                    meal: MealLabel.displayName(for: intake.meal))
                let key = Self.dayKey(intake.occurredAt, zone: zone)
                if titles[key] == nil {
                    titles[key] = Self.dayTitle(intake.occurredAt, zone: zone, locale: locale)
                }
                groups[key, default: []].append(row)
                intakesByDay[key, default: []].append(intake)
            }
            let storedGoals = (try? goals?.goals()) ?? []
            let tracked = TodayViewModel.totalsNutrients(goals: storedGoals)
            sections = try groups.keys.sorted(by: >).map { key in
                let totals = try DailyTotalsBuilder.totals(
                    for: intakesByDay[key] ?? [], store: store, lookup: lookup, nutrients: tracked)
                return JournalDaySection(
                    id: key, title: titles[key] ?? key,
                    rows: (groups[key] ?? []).sorted { $0.occurredAt > $1.occurredAt },
                    totals: totals,
                    totalsText: Self.totalsText(totals: totals, tracked: tracked, goals: storedGoals))
            }
            skippedCount = skipped
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the journal."
        }
    }

    /// Creates a new intake from an existing one (one `create`); the original is untouched.
    @discardableResult
    public func repeatIntake(_ intakeID: String, now: Date) -> String? {
        do {
            guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }) else {
                errorMessage = "This entry is no longer available."
                return nil
            }
            let newID = try repeater.create(repeating: intake, now: now)
            load(now: now)
            return newID
        } catch IntakeRepeatError.productUnavailable {
            errorMessage = IntakeRepeatError.productUnavailableMessage
            return nil
        } catch {
            errorMessage = "Could not repeat the entry."
            return nil
        }
    }

    /// The day's whole figure on one line, the nutrients with a target first.
    ///
    /// A nutrient the day cannot answer for is left out rather than written as "unknown": this is a
    /// summary line over a list of entries, and the entries below it say which ones could not be
    /// read. A day where nothing at all is known says so on its own.
    static func totalsText(totals: DailyTotals, tracked: [String], goals: [NutrientGoal]) -> String {
        let withTarget = goals.map { $0.nutrient }
        let ordered = withTarget + tracked.filter { !withTarget.contains($0) }
        let parts = ordered.compactMap { nutrient -> String? in
            let line = NutrientProgressLine.make(
                nutrient: nutrient, total: totals.total(for: nutrient),
                goal: goals.first { $0.nutrient == nutrient })
            // A nutrient the day cannot answer for is left off rather than written as "unknown": this
            // is a summary over a list of entries, and the entries below it say which could not be read.
            guard line.hasKnownAmount else { return nil }
            return line.text
        }
        return parts.isEmpty ? "No totals for this day." : parts.joined(separator: ", ")
    }

    static func dayTitle(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
