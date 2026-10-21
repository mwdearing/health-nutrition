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
        /// The read ran. `values` holds each nutrient's day total in its unit. A key in `readKeys` with no value
        /// is a known zero: its query succeeded and Health had no samples. A key outside `readKeys` is unknown,
        /// which is what a failed query leaves.
        case read(values: [String: Decimal], readKeys: Set<String>)
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

        // The journal's side: complete when the whole day is known, a known partial sum otherwise. Its amount is
        // added only in the Health unit. An amount in another unit (an IU alias total, say) is never converted or
        // added, so the journal side stays out and the line reads as at least.
        var journalValue: Decimal?
        var journalComplete = false
        var journalEmpty = false
        var journalUnit: MeasureUnit?
        if case .known(let value, let amountUnit) = line.amount {
            journalValue = value
            journalUnit = amountUnit
            journalComplete = true
        } else if line.isPartial, case .known(let value, let amountUnit)? = line.knownSum {
            journalValue = value
            journalUnit = amountUnit
        } else if case .unknown = line.amount, !line.isPartial, line.missingCount == 0 {
            // Unknown with nothing left out: no entry contributes a value to this nutrient (an empty day, or a day
            // with only drinks or supplements that do not state it). The builder reads that as unknown, but nothing
            // was missed, so the journal side is a complete nothing.
            journalValue = 0
            journalComplete = true
            journalEmpty = true
        }
        var journalMismatch = false
        if let journalUnit, journalUnit.symbol != unit.symbol {
            journalValue = nil
            journalComplete = false
            journalMismatch = true
        }

        // Health's side: a value Health returned, a known zero for a query that succeeded with no samples,
        // and unknown (nil, never zero) for a query that failed or was not run.
        // A nutrient whose query was skipped for any sample stays incomplete even when some of its samples were summed.
        var outsideValue: Decimal?
        var outsideComplete = false
        // Health's values and read keys are canonical, so an alias line (a goal stored under a captured alias) is looked up
        // under its canonical key.
        let canonical = HealthKitWritePlanner.canonicalKey(for: line.nutrient)
        if case .read(let values, let readKeys) = outside {
            if readKeys.contains(canonical) {
                outsideValue = values[canonical] ?? 0
                outsideComplete = true
            } else {
                outsideValue = values[canonical]
            }
        }

        // A journal amount in another unit is not added, and if Health is unknown too, the amount stays in its own
        // unit as a partial total: "at least", never exact.
        if journalMismatch, outsideValue == nil {
            let own: NutrientValue? = {
                if case .known = line.amount { return line.amount }
                if line.isPartial, case .known? = line.knownSum { return line.knownSum }
                return nil
            }()
            if let own {
                return NutrientProgressLine(
                    nutrient: line.nutrient, amount: .unknown, goal: line.goal, displayName: line.label,
                    isPartial: true, knownSum: own, missingCount: line.missingCount)
            }
        }

        guard journalValue != nil || outsideValue != nil else { return line }
        // Nothing logged and no Health amount above zero: the day has nothing known, so the line stays "—" rather
        // than reading 0 or "at least 0".
        if journalEmpty, (outsideValue ?? 0) == 0 { return line }
        // A journal side with entries but no known part, against a Health zero: nothing is known, so the line stays unknown.
        if journalValue == nil, (outsideValue ?? 0) == 0 { return line }
        let sum = NutrientValue.known((journalValue ?? 0) + (outsideValue ?? 0), unit)

        if journalComplete && outsideComplete {
            return NutrientProgressLine(
                nutrient: line.nutrient, amount: sum, goal: line.goal, displayName: line.label,
                missingCount: line.missingCount)
        }
        return NutrientProgressLine(
            nutrient: line.nutrient, amount: .unknown, goal: line.goal, displayName: line.label,
            isPartial: true, knownSum: sum, missingCount: line.missingCount,
            healthGap: !outsideComplete)
    }
}
