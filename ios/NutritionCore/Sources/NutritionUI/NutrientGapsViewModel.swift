import Foundation
import NutritionDomain
import NutritionJournal

/// Where the published reference row a person picked is kept: "Women 31 to 50", say.
///
/// It is a preference about what the screen compares with, kept beside the other display
/// preferences and erased with them. Nil until a person picks one: the screen then shows amounts
/// alone, because there is no reference row for someone who has not said which one is theirs.
public protocol ReferenceGroupPreferences: AnyObject {
    var referenceGroup: ReferenceGroup? { get }
    func setReferenceGroup(_ group: ReferenceGroup?)
}

/// How one vitamin or mineral's day reads against its published reference values.
public enum NutrientGapStatus: Hashable, Sendable {
    /// No entry today could state this nutrient.
    case nothingLogged
    /// Entries could state it, but none states an amount the app can add up.
    case unknown
    /// Amounts are known, and no reference group is chosen to compare them with.
    case noReference
    /// Every entry that could state it did, and the day is below the RDA or AI.
    case belowReference
    /// What is known is below the RDA or AI, but some entries do not state it, so the day may be higher.
    case belowReferenceSoFar
    /// The known amounts alone reach the RDA or AI.
    case reachedReference
    /// The part of the day an upper limit counts is above that limit.
    case aboveUpperLimit
}

/// What today's entries add up to for one nutrient, split by where it came from. Amounts are in the
/// nutrient's own unit. An entry that could state the nutrient but does not is counted in `missing`
/// and adds nothing, so the amounts are a floor whenever `missing` is above zero.
public struct NutrientDayTally: Equatable, Sendable {
    public var fromFood: Decimal = 0
    public var fromSupplements: Decimal = 0
    /// Entries that stated an amount.
    public var known = 0
    /// Entries that could have stated it and did not, or stated it in a unit that cannot be added
    /// (international units for vitamins A, D and E).
    public var missing = 0

    public init(fromFood: Decimal = 0, fromSupplements: Decimal = 0, known: Int = 0, missing: Int = 0) {
        self.fromFood = fromFood
        self.fromSupplements = fromSupplements
        self.known = known
        self.missing = missing
    }

    public var total: Decimal { fromFood + fromSupplements }
}

/// One vitamin or mineral on the screen: the day's known amount, its reference values for the
/// chosen group, and how the two compare. Plain text throughout, because that is what a test asserts.
public struct NutrientGapRow: Equatable, Identifiable {
    public let nutrient: String
    public let label: String
    public let unit: MeasureUnit
    public let tally: NutrientDayTally
    /// Nil when no group is chosen.
    public let reference: ReferenceIntake?
    /// For a week, the logged days the amounts are a daily average over; nil for a single day.
    public let averagedOverDays: Int?
    /// For a week, the logged days on which the part of the day the upper limit counts was certainly
    /// above it. An upper limit is a daily one, so a week is above it when any of its days is, however
    /// the average reads.
    public let daysAboveLimit: Int
    public let status: NutrientGapStatus

    public var id: String { nutrient }

    public init(
        nutrient: String, label: String, unit: MeasureUnit, tally: NutrientDayTally, reference: ReferenceIntake?,
        averagedOverDays: Int? = nil, daysAboveLimit: Int = 0
    ) {
        self.nutrient = nutrient
        self.label = label
        self.unit = unit
        self.tally = tally
        self.reference = reference
        self.averagedOverDays = averagedOverDays
        self.daysAboveLimit = daysAboveLimit
        self.status = Self.status(tally: tally, reference: reference, daysAboveLimit: daysAboveLimit)
    }

    /// The comparison, in a fixed order: nothing to compare first, then the limit, then the reference.
    static func status(tally: NutrientDayTally, reference: ReferenceIntake?, daysAboveLimit: Int = 0) -> NutrientGapStatus {
        guard tally.known > 0 else { return tally.missing > 0 ? .unknown : .nothingLogged }
        guard let reference else { return .noReference }
        if daysAboveLimit > 0 && reference.upperLimit != nil {
            return .aboveUpperLimit
        }
        if NutrientGaps.exceededLimit(intake: reference, total: tally.total, supplementTotal: tally.fromSupplements) {
            return .aboveUpperLimit
        }
        if tally.total >= reference.amount { return .reachedReference }
        return tally.missing > 0 ? .belowReferenceSoFar : .belowReference
    }

    /// "120 mg", "At least 120 mg" where some entries do not state it, or a word where nothing is known.
    public var amountText: String {
        switch status {
        case .nothingLogged: return "Nothing logged"
        case .unknown: return "Unknown"
        default:
            let figure = Self.figure(tally.total, unit)
            return tally.missing > 0 ? "At least \(figure)" : figure
        }
    }

    /// "RDA 90 mg, upper limit 2000 mg", or "AI 120 mcg, no upper limit set". Nil without a group.
    public var referenceText: String? {
        guard let reference else { return nil }
        let base = "\(reference.kind.abbreviation) \(Self.figure(reference.amount, unit))"
        guard let limit = reference.upperLimit else { return "\(base), no upper limit set" }
        let basis = reference.upperLimitScope == .folicAcid ? " of folic acid" : ""
        return "\(base), upper limit \(Self.figure(limit, unit))\(basis)"
    }

    /// The lines under the figures: where the amount came from, how much is unknown, and what a
    /// form-specific limit counts. Empty when there is nothing to add.
    public var detailLines: [String] {
        var lines: [String] = []
        if tally.known > 0, tally.fromSupplements > 0, tally.fromFood > 0 {
            lines.append(
                "Food \(Self.figure(tally.fromFood, unit)), supplements \(Self.figure(tally.fromSupplements, unit))")
        } else if tally.known > 0, tally.fromSupplements > 0 {
            lines.append("All from supplements")
        }
        if tally.missing > 0 {
            lines.append("Unknown for \(tally.missing) \(tally.missing == 1 ? "entry" : "entries")")
        }
        if let days = averagedOverDays, daysAboveLimit > 0, reference?.upperLimit != nil {
            lines.append("Above the upper limit on \(daysAboveLimit) of \(days) logged \(days == 1 ? "day" : "days").")
        }
        if let reference, reference.upperLimit != nil, let scope = reference.upperLimitScope {
            if let note = NutrientGaps.limitNote(scope) { lines.append(note) }
        }
        return lines
    }

    /// The share of the reference the day has reached, for the bar. Nil without a reference or an amount.
    /// Above the reference the bar is full and `referenceMarker` shows where the reference sits.
    public var foodFraction: Decimal? { fraction(of: tally.fromFood) }
    public var supplementFraction: Decimal? { fraction(of: tally.fromSupplements) }

    /// Where the reference sits on a bar that runs past it, or nil while the day is below it.
    public var referenceMarker: Decimal? {
        guard let reference, reference.amount > 0, tally.total > reference.amount else { return nil }
        return reference.amount / tally.total
    }

    private func fraction(of part: Decimal) -> Decimal? {
        guard let reference, tally.known > 0, reference.amount > 0 else { return nil }
        let scale = max(reference.amount, tally.total)
        return part / scale
    }

    /// The one sentence VoiceOver reads for the row.
    public var accessibilityText: String {
        var parts = [averagedOverDays == nil ? "\(label), \(amountText)" : "\(label), daily average \(amountText)"]
        if let status = statusText { parts.append(status) }
        if let referenceText { parts.append(referenceText) }
        parts.append(contentsOf: detailLines)
        return parts.joined(separator: ". ")
    }

    /// A short statement of the comparison, never advice: "Below the RDA". Nil where there is no
    /// comparison to state.
    public var statusText: String? {
        guard let reference else { return nil }
        let name = reference.kind.abbreviation
        switch status {
        case .belowReference: return "Below the \(name)"
        case .belowReferenceSoFar: return "Below the \(name) so far"
        case .reachedReference: return "Reached the \(name)"
        case .aboveUpperLimit: return "Above the upper limit"
        case .nothingLogged, .unknown, .noReference: return nil
        }
    }

    /// An amount for display: one decimal place, two below 1, and "< 0.01" for an amount too small to
    /// show, so a real amount never reads as zero.
    static func figure(_ amount: Decimal, _ unit: MeasureUnit) -> String {
        let digits = amount < 1 ? 2 : 1
        let rounded = DisplayRounding.rounded(amount, fractionDigits: digits)
        if rounded == 0, amount > 0 { return "< 0.01 \(unit.symbol)" }
        return "\(DecimalFormatting.text(rounded)) \(unit.symbol)"
    }
}

/// The upper-limit rule the vitamins and minerals screen applies, in one place so any screen that
/// warns about a limit (the supplement stack) says exactly what this one does.
public enum NutrientGaps {
    /// True only when the part of the day `intake`'s upper limit counts is certainly above it. Amounts
    /// are in `intake.unit`: `total` is everything known (food and supplements), `supplementTotal` the
    /// supplements alone. False where no limit was set, and always false for the folate and vitamin A
    /// limits, whose forms the journal cannot tell apart, so a warning is never a guess.
    public static func exceededLimit(intake: ReferenceIntake, total: Decimal, supplementTotal: Decimal) -> Bool {
        guard let limit = intake.upperLimit, let scope = intake.upperLimitScope,
            let counted = countedFloor(total: total, supplementTotal: supplementTotal, scope: scope)
        else { return false }
        return counted > limit
    }

    /// The least the day certainly holds of what a limit counts, or nil where the journal cannot say.
    ///
    /// A limit is only reported as exceeded when this floor is above it, so "Above the upper limit" is
    /// never a guess. Everything known counts toward an all-sources limit. Whatever a supplement states
    /// is a supplemental form, so the supplement amount is a floor for the magnesium limit (medicines are
    /// not logged) and for the niacin and vitamin E limits (fortified foods cannot be told from other
    /// food). The folate limit counts folic acid only and the vitamin A limit preformed vitamin A only,
    /// and the journal cannot tell either from the other forms a supplement may hold (methylfolate, beta
    /// carotene), so those two are not checked at all.
    public static func countedFloor(total: Decimal, supplementTotal: Decimal, scope: UpperLimitScope) -> Decimal? {
        switch scope {
        case .allSources: return total
        case .supplementsAndMedicines, .supplementsAndFortifiedFoods: return supplementTotal
        case .folicAcid, .preformedVitaminA: return nil
        }
    }

    /// What a limit that does not count everything counts, and what the screen can and cannot check.
    public static func limitNote(_ scope: UpperLimitScope) -> String? {
        switch scope {
        case .allSources:
            return nil
        case .supplementsAndMedicines:
            return "The upper limit counts supplements and medicines only, not food or water. Supplements are checked."
        case .supplementsAndFortifiedFoods:
            return "The upper limit counts supplements and fortified foods, not food itself. Only supplements are checked."
        case .folicAcid:
            return "The upper limit counts folic acid only. The app can't tell it from other folate, so it isn't checked."
        case .preformedVitaminA:
            return "The upper limit counts preformed vitamin A only. The app can't tell it from beta carotene, so it isn't checked."
        }
    }

}

/// How much of the journal the screen covers: today alone, or a daily average over the last seven days.
public enum NutrientGapsSpan: String, CaseIterable, Sendable {
    case day, week

    /// "Day" or "Week", the words the picker shows.
    public var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        }
    }

    /// How many local days back from today the span reaches, today included.
    var dayCount: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        }
    }
}

/// One titled group of rows on the screen.
public struct NutrientGapSection: Equatable, Identifiable {
    public let title: String
    public let rows: [NutrientGapRow]
    public var id: String { title }
}

/// Backs the vitamins and minerals screen: what today's entries state for each nutrient the reference
/// table covers, compared with the published values for the group a person picks.
///
/// The day is summed one entry at a time with `DailyTotalsBuilder`, so each entry contributes exactly
/// what Today would count for it, and an entry that does not state a nutrient is counted as unknown
/// rather than letting it hide what the other entries do state. Supplements are summed apart from
/// food, because some upper limits count supplements alone.
@MainActor
public final class NutrientGapsViewModel: ObservableObject {
    @Published public private(set) var sections: [NutrientGapSection] = []
    @Published public private(set) var rows: [NutrientGapRow] = []
    @Published public private(set) var referenceGroup: ReferenceGroup?
    @Published public private(set) var errorMessage: String?
    /// Entries left out because their stored time zone is not a valid one, so their day is unknown.
    @Published public private(set) var skippedIntakeCount = 0
    /// Today, or the daily average over the last seven days.
    @Published public private(set) var span: NutrientGapsSpan = .day
    /// The days in the span with at least one food, drink or supplement entry. The week's figures are
    /// averages over these days, so a day nothing was logged on does not pull every average down.
    @Published public private(set) var loggedDays = 0

    /// The line that says what the week's figures are, or nil for a single day.
    public var spanSummary: String? {
        guard span == .week, errorMessage == nil else { return nil }
        switch loggedDays {
        case 0: return "Nothing was logged in the last 7 days."
        case 1: return "Average per day over the 1 day you logged in the last 7."
        default: return "Average per day over the \(loggedDays) days you logged in the last 7."
        }
    }

    /// The line that says entries were left out, or nil when none were.
    public var skippedNotice: String? {
        guard skippedIntakeCount > 0 else { return nil }
        let entries = skippedIntakeCount == 1 ? "1 entry has" : "\(skippedIntakeCount) entries have"
        return "\(entries) a time zone the app can't read and \(skippedIntakeCount == 1 ? "is" : "are") left out, so these figures may be low."
    }

    public static let readFailedMessage = "Could not read the journal."

    private let store: JournalStore
    private let lookup: NutrientFactsLookup
    private let preferences: ReferenceGroupPreferences?
    private var tallies: [String: NutrientDayTally] = [:]
    /// The week's tallies day by day, so a daily upper limit is checked against each day, not the average.
    private var dayTallies: [[String: NutrientDayTally]] = []

    public init(
        store: JournalStore, lookup: NutrientFactsLookup = UnknownNutrientFacts(),
        preferences: ReferenceGroupPreferences? = nil
    ) {
        self.store = store
        self.lookup = lookup
        self.preferences = preferences
        self.referenceGroup = preferences?.referenceGroup
    }

    /// The nutrients listed, in the reference table's order.
    public static var nutrients: [String] { ReferenceIntakes.nutrients }

    /// Reads the span's entries again and rebuilds every row.
    public func load(now: Date) {
        referenceGroup = preferences?.referenceGroup
        do {
            let read = try Self.tallies(store: store, lookup: lookup, now: now, days: span.dayCount)
            loggedDays = read.loggedDays
            tallies = span == .week ? Self.averaged(read.tallies, over: read.loggedDays) : read.tallies
            dayTallies = span == .week ? read.byDay : []
            skippedIntakeCount = read.skipped
            errorMessage = nil
        } catch {
            tallies = [:]
            dayTallies = []
            loggedDays = 0
            skippedIntakeCount = 0
            errorMessage = Self.readFailedMessage
        }
        rebuild()
    }

    /// Switches between today and the week, and reads the journal for it.
    public func chooseSpan(_ span: NutrientGapsSpan, now: Date) {
        self.span = span
        load(now: now)
    }

    /// The week's totals as a daily average over the logged days. Entry counts stay totals, so "Unknown
    /// for 3 entries" still counts entries; a span with nothing logged is left as it is.
    static func averaged(_ tallies: [String: NutrientDayTally], over days: Int) -> [String: NutrientDayTally] {
        guard days > 1 else { return tallies }
        let divisor = Decimal(days)
        return tallies.mapValues { tally in
            NutrientDayTally(
                fromFood: tally.fromFood / divisor, fromSupplements: tally.fromSupplements / divisor,
                known: tally.known, missing: tally.missing)
        }
    }

    /// Stores the group a person picked, or clears it, and compares the same day against it.
    public func chooseReferenceGroup(_ group: ReferenceGroup?) {
        preferences?.setReferenceGroup(group)
        referenceGroup = group
        rebuild()
    }

    private func rebuild() {
        let group = referenceGroup
        let isWeek = span == .week
        rows = Self.nutrients.map { nutrient in
            let reference = group.flatMap { ReferenceIntakes.intake(for: nutrient, group: $0) }
            let daysAbove = reference.map { reference in
                dayTallies.filter { day in
                    guard let tally = day[nutrient] else { return false }
                    return NutrientGaps.exceededLimit(
                        intake: reference, total: tally.total, supplementTotal: tally.fromSupplements)
                }.count
            } ?? 0
            return NutrientGapRow(
                nutrient: nutrient, label: NutrientNames.displayName(for: nutrient),
                unit: Self.unit(for: nutrient), tally: tallies[nutrient] ?? NutrientDayTally(),
                reference: reference, averagedOverDays: isWeek ? loggedDays : nil, daysAboveLimit: daysAbove)
        }
        sections = errorMessage == nil ? Self.sections(rows, hasGroup: group != nil, span: span) : []
    }

    /// The unit a nutrient is counted in: the nutrient mapping's, which the reference table matches.
    static func unit(for nutrient: String) -> MeasureUnit {
        HealthKitWritePlanner.mapping(for: nutrient)?.unit ?? .mg
    }

    /// Rows grouped for reading: what needs a look first, then what is fine, then what is not known.
    static func sections(_ rows: [NutrientGapRow], hasGroup: Bool, span: NutrientGapsSpan = .day) -> [NutrientGapSection] {
        func section(_ title: String, _ statuses: Set<NutrientGapStatus>) -> NutrientGapSection? {
            let matching = rows.filter { statuses.contains($0.status) }
            return matching.isEmpty ? nil : NutrientGapSection(title: title, rows: matching)
        }
        let notKnown = section(span == .day ? "Not known today" : "Not known this week", [.unknown, .nothingLogged])
        guard hasGroup else {
            return [section(span == .day ? "Today" : "Last 7 days", [.noReference]), notKnown].compactMap { $0 }
        }
        return [
            section("Above an upper limit", [.aboveUpperLimit]),
            section("Below the reference", [.belowReference, .belowReferenceSoFar]),
            section("Reached the reference", [.reachedReference]),
            notKnown,
        ].compactMap { $0 }
    }

    /// Today's entries, one at a time, into a tally per nutrient, and how many entries were left out
    /// because their day cannot be told.
    ///
    /// The day is each entry's own local day, as on Today, and an entry whose stored time zone is not a
    /// valid one is counted as skipped rather than silently treated as another day. Each entry is summed
    /// alone, so a food that does not state a nutrient marks only itself unknown. A water entry, or a
    /// supplement that does not declare a nutrient, says nothing about it and counts nowhere.
    ///
    /// An entry with a product snapshot is read through `DailyTotalsBuilder`, which scales the snapshot
    /// to the amount logged. An entry typed by hand has no snapshot to scale, and each component states
    /// its own amount, so its components are read one by one: a component that states the nutrient keeps
    /// its amount even when another component of the same entry does not, and the entry is then both a
    /// known contribution and an unknown one.
    static func tallies(
        store: JournalStore, lookup: NutrientFactsLookup, now: Date, days: Int = 1
    ) throws -> (tallies: [String: NutrientDayTally], skipped: Int, loggedDays: Int, byDay: [[String: NutrientDayTally]]) {
        var tallies: [String: NutrientDayTally] = [:]
        var byDay: [[String: NutrientDayTally]] = Array(repeating: [:], count: max(days, 1))
        var skipped = 0
        var logged: Set<Int> = []
        let nutrients = Self.nutrients
        for intake in try store.activeIntakes() where intake.lifecycle == .active {
            guard let offset = Self.daysBefore(now, intake) else {
                skipped += 1
                continue
            }
            // Today is 0; a day in the future or before the span is not part of it.
            guard (0..<max(days, 1)).contains(offset) else { continue }
            let revisions = try store.revisions(of: intake.id)
            guard let current = revisions.first(where: { $0.number == intake.currentRevision }) else { continue }
            if intake.category != DailyTotalsBuilder.waterCategory { logged.insert(offset) }
            let snapshot = current.productSnapshotID.flatMap { try? store.product(snapshotID: $0) }
            let isSupplement = snapshot?.kind == .supplement
            let byComponent = snapshot == nil && intake.category != DailyTotalsBuilder.waterCategory
            var totals: DailyTotals?
            if !byComponent {
                totals = try DailyTotalsBuilder.totals(for: [intake], store: store, lookup: lookup, nutrients: nutrients)
            }
            for nutrient in nutrients {
                let values: [NutrientValue]
                if let totals {
                    guard let total = totals.total(for: nutrient), total.coverage.totalCount > 0 else { continue }
                    values = [total.value]
                } else {
                    values = current.components.map {
                        DailyTotalsBuilder.value(for: $0, snapshot: nil, nutrient: nutrient, lookup: lookup)
                    }.filter { $0 != .notApplicable }
                    guard !values.isEmpty else { continue }
                }
                let unit = Self.unit(for: nutrient)
                var amount = Decimal(0)
                var anyKnown = false
                var anyMissing = false
                for value in values {
                    if case .known(let stated, let statedUnit) = value,
                        let converted = try? Quantity(value: stated, unit: statedUnit).converted(to: unit),
                        !converted.value.isNaN, converted.value >= 0
                    {
                        amount += converted.value
                        anyKnown = true
                    } else {
                        anyMissing = true
                    }
                }
                var tally = tallies[nutrient] ?? NutrientDayTally()
                var dayTally = byDay[offset][nutrient] ?? NutrientDayTally()
                if anyKnown {
                    if isSupplement {
                        tally.fromSupplements += amount
                        dayTally.fromSupplements += amount
                    } else {
                        tally.fromFood += amount
                        dayTally.fromFood += amount
                    }
                    tally.known += 1
                    dayTally.known += 1
                }
                if anyMissing {
                    tally.missing += 1
                    dayTally.missing += 1
                }
                tallies[nutrient] = tally
                byDay[offset][nutrient] = dayTally
            }
        }
        return (tallies, skipped, logged.count, byDay)
    }

    /// How many local days before `now`'s day the entry's day is, both read in the entry's own time
    /// zone as Today reads it: 0 for today, 1 for yesterday, negative for a later day. Nil when the
    /// stored time zone is not a valid one.
    static func daysBefore(_ now: Date, _ intake: Intake) -> Int? {
        guard let zone = TimeZone(identifier: intake.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: intake.occurredAt), to: calendar.startOfDay(for: now)
        ).day
    }
}
