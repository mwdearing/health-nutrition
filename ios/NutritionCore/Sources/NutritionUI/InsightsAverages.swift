import Foundation
import NutritionDomain

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

        public init(key: String, totals: DailyTotals, isLogged: Bool = true) {
            self.key = key
            self.totals = totals
            self.isLogged = isLogged
        }
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
            guard day.isLogged, let age = ageInDays(of: day.key, from: today, calendar: calendar) else { return false }
            return age >= 0 && age < windowDays
        }
        var lines: [Line] = []
        for nutrient in nutrients {
            var values: [Decimal] = []
            var partialDays = 0
            var unit: MeasureUnit?
            for day in inWindow {
                // A fully known day counts as it is. A partly logged day counts with the sum of its known entries,
                // which is a minimum (#510). A day with nothing known for this nutrient is left out, never counted as
                // 0.
                let value: NutrientValue
                let isPartial: Bool
                if let total = day.totals.total(for: nutrient), case .known = total.value {
                    value = total.value
                    isPartial = false
                } else if let sum = day.totals.knownSum(for: nutrient) {
                    value = sum
                    isPartial = true
                } else {
                    continue
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

    /// Whole days from a "yyyy-MM-dd" key back to `today`: 0 for today. Nil when the key cannot be read.
    private static func ageInDays(of key: String, from today: Date, calendar: Calendar) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day
    }
}
