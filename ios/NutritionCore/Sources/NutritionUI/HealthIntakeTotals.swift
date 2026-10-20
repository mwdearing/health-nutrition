import Foundation
import NutritionDomain
import NutritionJournal

/// Adds what other apps logged to Apple Health into Today's per-nutrient lines.
///
/// The journal and Health are two sides of the same day. A side that is not known is never counted as
/// zero: when either side is missing, the line reads as a partial total ("at least"). A line with nothing
/// known on either side is left as it was, so "unknown" stays unknown rather than becoming a figure.
public enum HealthIntakeTotals {
    /// Health's side of the day.
    public enum Outside: Equatable, Sendable {
        /// Apple Health is not connected, so nothing outside the journal is counted.
        case notConnected
        /// The read failed, so every nutrient's Health side is unknown.
        case failed
        /// The read succeeded, with each canonical key's day total. A key with no value is unknown.
        case read([String: Decimal])
    }

    /// The lines with Health's side added. Water is left alone: its own line already counts drinks.
    public static func combine(_ lines: [NutrientProgressLine], outside: Outside) -> [NutrientProgressLine] {
        guard outside != .notConnected else { return lines }
        return lines.map { combine($0, outside: outside) }
    }

    static func combine(_ line: NutrientProgressLine, outside: Outside) -> NutrientProgressLine {
        guard line.nutrient != DailyTotalsBuilder.waterKey,
              let unit = HealthKitWritePlanner.mapping(for: line.nutrient)?.unit
        else { return line }

        // The journal's side: complete when the whole day is known, a known partial sum otherwise.
        var journalValue: Decimal?
        var journalComplete = false
        if case .known(let value, _) = line.amount {
            journalValue = value
            journalComplete = true
        } else if line.isPartial, case .known(let value, _)? = line.knownSum {
            journalValue = value
        }

        // Health's side: a missing key or a failed read is unknown, never zero.
        var outsideValue: Decimal?
        if case .read(let values) = outside {
            outsideValue = values[line.nutrient]
        }
        let outsideComplete = outsideValue != nil

        guard journalValue != nil || outsideValue != nil else { return line }
        let sum = NutrientValue.known((journalValue ?? 0) + (outsideValue ?? 0), unit)

        if journalComplete && outsideComplete {
            return NutrientProgressLine(
                nutrient: line.nutrient, amount: sum, goal: line.goal, displayName: line.label,
                missingCount: line.missingCount)
        }
        return NutrientProgressLine(
            nutrient: line.nutrient, amount: .unknown, goal: line.goal, displayName: line.label,
            isPartial: true, knownSum: sum, missingCount: line.missingCount)
    }
}
