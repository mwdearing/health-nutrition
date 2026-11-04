import Foundation

/// One day that has at least one counted dose, with the doses logged on that day.
public struct DoseDayMarker: Sendable, Equatable {
    /// One dose on the marked day: the medication's name, and the amount and unit the dose was logged in.
    public struct Entry: Sendable, Equatable {
        /// The name of the medication the dose belongs to.
        public let name: String
        /// The amount of the dose, as logged.
        public let amount: Decimal
        /// The unit the dose was logged in. This can differ from the medication's current unit.
        public let unit: MedicationUnit

        /// An entry with the given name, amount and unit.
        public init(name: String, amount: Decimal, unit: MedicationUnit) {
            self.name = name
            self.amount = amount
            self.unit = unit
        }
    }

    /// The local day the doses were taken on, in each dose's own time zone.
    public let day: CalendarDay
    /// The doses on this day, in the order they were taken. Equal times are ordered by dose identifier.
    public let entries: [Entry]

    /// A marker for the given day with the given entries.
    public init(day: CalendarDay, entries: [Entry]) {
        self.day = day
        self.entries = entries
    }
}

/// Builds the day markers for a range of days from the logged doses.
public enum DoseDayMarkers {
    /// The markers for the days from `from` to `through`, both included, in ascending day order.
    ///
    /// A dose is counted on its own local day. A dose is left out when its day cannot be read, when its day is
    /// outside the range, or when its medication identifier is not in `medications`. Archived medications are
    /// counted. Days with no counted dose have no marker.
    public static func markers(
        medications: [Medication], doses: [MedicationDose], from: CalendarDay, through: CalendarDay
    ) -> [DoseDayMarker] {
        var names: [UUID: String] = [:]
        for medication in medications where names[medication.id] == nil {
            names[medication.id] = medication.name
        }

        var byDay: [CalendarDay: [(dose: MedicationDose, name: String)]] = [:]
        for dose in doses {
            guard let day = dose.day, day >= from, day <= through,
                  let name = names[dose.medicationID] else { continue }
            byDay[day, default: []].append((dose: dose, name: name))
        }

        return byDay.keys.sorted().map { day in
            let ordered = (byDay[day] ?? []).sorted { lhs, rhs in
                if lhs.dose.takenAt != rhs.dose.takenAt {
                    return lhs.dose.takenAt < rhs.dose.takenAt
                }
                return lhs.dose.id.uuidString < rhs.dose.id.uuidString
            }
            let entries = ordered.map { item in
                DoseDayMarker.Entry(name: item.name, amount: item.dose.amount, unit: item.dose.unit)
            }
            return DoseDayMarker(day: day, entries: entries)
        }
    }
}
