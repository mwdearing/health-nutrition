import Foundation
import NutritionDomain
import NutritionJournal

/// Per-day averages over the last 30 local days, for the Insights screen.
///
/// Only days with a known amount for a nutrient count towards its average; a partly logged day counts with its
/// known sum, as a minimum (#510), and the line says how many days that was, so a month with gaps reads as an
/// average of what was logged and never as a month of zeros.
public struct InsightsAverages: Equatable {
    public static let windowDays = 30

    public struct Day {
        /// The local day as the Diary keys it: "yyyy-MM-dd".
        public let key: String
        public let totals: DailyTotals
        /// Whether the day holds a food or drink entry. A day with only water or supplements is not a logged
        /// day, the same rule as the day header and the week summary, so it cannot pull an average down.
        public let isLogged: Bool
        /// What other apps logged to Apple Health that day. A day it states intake for counts, and its amounts are
        /// added to the journal's, as Today adds them; not connected adds nothing.
        public let outside: HealthIntakeTotals.Outside

        public init(
            key: String, totals: DailyTotals, isLogged: Bool = true, outside: HealthIntakeTotals.Outside = .notConnected
        ) {
            self.key = key
            self.totals = totals
            self.isLogged = isLogged
            self.outside = outside
        }

        /// A food or drink entry in the journal, or intake Health states for the day.
        var counts: Bool { isLogged }
    }

    public struct Line: Equatable, Identifiable {
        public let id: String
        public let text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// - Parameters:
    ///   - days: the Diary's days with their totals.
    ///   - nutrients: the nutrient keys to average, in the order to show them.
    ///   - now: the reference instant; the window is the 30 local days ending on its date in `zone`.
    public static func make(days: [Day], nutrients: [String], now: Date, zone: TimeZone) -> InsightsAverages {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let inWindow = days.filter { day in
            guard day.counts, let age = ageInDays(of: day.key, from: today, calendar: calendar) else { return false }
            return age >= 0 && age < windowDays
        }
        var lines: [Line] = []
        for nutrient in nutrients {
            var values: [Decimal] = []
            var partialDays = 0
            var unit: MeasureUnit?
            for day in inWindow {
                // A day with no food or drink entry contributes only Health's side: its water and supplement totals are not
                // intake the average counts (#510).
                let journal = day.isLogged ? day.totals : DailyTotals(totals: [:])
                // A fully known day counts as it is. A partly logged day counts with the sum of its known entries,
                // which is a minimum (#510). A day with nothing known for this nutrient is left out, never counted as
                // 0.
                var value: NutrientValue
                var isPartial: Bool
                if let total = journal.total(for: nutrient), case .known = total.value {
                    value = total.value
                    isPartial = false
                } else if let sum = journal.knownSum(for: nutrient) {
                    value = sum
                    isPartial = true
                } else {
                    value = .unknown
                    isPartial = false
                }
                // Health's side of the day, added as Today adds it: a completed query is a known amount (a known zero
                // with no samples), a query that did not run leaves the figure at least, and not connected adds nothing.
                switch healthSide(of: day.outside, for: nutrient) {
                case .none:
                    break
                case .unread:
                    isPartial = true
                case .known(let healthAmount, let healthUnit, let complete):
                    if !complete { isPartial = true }
                    if case .known(let journalAmount, let journalUnit) = value {
                        if journalUnit.symbol == healthUnit.symbol {
                            value = .known(journalAmount + healthAmount, journalUnit)
                        } else {
                            // As Today does, an amount in another unit than Health's is never converted or added: Health's
                            // positive amount stands alone as a minimum, and with nothing from Health the journal's figure
                            // stands, also as a minimum.
                            if healthAmount > 0 { value = .known(healthAmount, healthUnit) }
                            isPartial = true
                        }
                    } else if healthAmount == 0 {
                        // The journal states nothing for this nutrient and Health adds nothing: the day stays unknown, as
                        // Today leaves it, and is left out of the average rather than counted as a zero.
                        break
                    } else {
                        value = .known(healthAmount, healthUnit)
                        // Entries that carry no value for the nutrient make Health's amount a minimum; with none, the
                        // journal side is a complete nothing and Health's amount is the day.
                        // A total the journal could not form (incompatible units, say) has incomplete coverage though no
                        // entry is missing a value, so it counts the same.
                        if journal.missingCount(for: nutrient) > 0
                            || journal.total(for: nutrient)?.coverage.hasUnknown == true { isPartial = true }
                    }
                }
                guard case .known(let amount, let amountUnit) = value else { continue }
                let target = unit ?? amountUnit
                guard let converted = try? Quantity(value: amount, unit: amountUnit).converted(to: target).value
                else { continue }
                unit = target
                values.append(converted)
                if isPartial { partialDays += 1 }
            }
            guard let unit, !values.isEmpty else { continue }
            let average = values.reduce(Decimal(0), +) / Decimal(values.count)
            let shown = AmountDisplay.display(average, unit: unit, system: .metric)
            let rounded = DisplayRounding.rounded(
                shown.amount, fractionDigits: AmountDisplay.fractionDigits(for: shown.amount))
            let figure = DisplayAmount(
                amount: rounded, unit: shown.unit,
                isBelowSmallest: shown.isBelowSmallest || (rounded == 0 && average > 0))
            let name = NutrientNames.displayName(for: nutrient)
            let dayCount = values.count == 1 ? "1 logged day" : "\(values.count) logged days"
            let text = partialDays > 0
                ? "\(name): at least \(figure.text) a day over \(dayCount)"
                : "\(name): average \(figure.text) a day over \(dayCount)"
            lines.append(Line(id: nutrient, text: text))
        }
        return InsightsAverages(lines: lines)
    }

    private enum HealthSide {
        case none
        case unread
        /// Health's amount for the nutrient; `complete` is false for a subtotal of a query that did not finish.
        case known(Decimal, MeasureUnit, complete: Bool)
    }

    private static func healthSide(of outside: HealthIntakeTotals.Outside, for nutrient: String) -> HealthSide {
        guard case .read(let values, let readKeys) = outside, let mapping = HealthKitWritePlanner.mapping(for: nutrient)
        else { return .none }
        let key = HealthKitWritePlanner.canonicalKey(for: nutrient)
        if readKeys.contains(key) { return .known(values[key] ?? 0, mapping.unit, complete: true) }
        // A query that did not finish may still carry the subtotal of the samples it did convert.
        if let subtotal = values[key] { return .known(subtotal, mapping.unit, complete: false) }
        return .unread
    }

    /// Whole days from a "yyyy-MM-dd" key back to `today`: 0 for today. Nil when the key cannot be read.
    private static func ageInDays(of key: String, from today: Date, calendar: Calendar) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day
    }
}
