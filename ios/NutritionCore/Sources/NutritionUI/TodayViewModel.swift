import Foundation
import NutritionDomain
import NutritionJournal

/// A water entry that can still be taken back.
public struct UndoHandle: Equatable {
    public let intakeID: String
    public let expiresAt: Date
}

/// One row on the Today screen.
public struct TodayRow: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let occurredAt: Date
}

@MainActor
public final class TodayViewModel: ObservableObject {
    public static let defaultTrackedNutrients = ["potassium", "sodium", "protein", "fiber"]
    public static let undoWindow: TimeInterval = 10

    @Published public private(set) var rows: [TodayRow] = []
    /// Water today in mL, an exact decimal.
    @Published public private(set) var waterTotalMilliliters: Decimal = 0
    /// Water components skipped because their unit is not a volume (never counted as zero).
    @Published public private(set) var waterSkippedCount: Int = 0
    @Published public private(set) var coverage: [CoverageLine] = []
    @Published public private(set) var undo: UndoHandle?
    @Published public private(set) var errorMessage: String?

    private let store: JournalStore
    private let lookup: NutrientFactsLookup
    private let trackedNutrients: [String]
    private let timeZoneIdentifier: String
    private let makeID: () -> String

    public init(
        store: JournalStore,
        lookup: NutrientFactsLookup = UnknownNutrientFacts(),
        trackedNutrients: [String] = TodayViewModel.defaultTrackedNutrients,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.lookup = lookup
        self.trackedNutrients = trackedNutrients
        self.timeZoneIdentifier = timeZoneIdentifier
        self.makeID = makeID
    }

    /// Reloads Today: active intakes on the local day of each intake's own time zone.
    public func load(now: Date) {
        do {
            let intakes = try store.activeIntakes().filter {
                $0.lifecycle == .active && Self.isSameLocalDay($0, as: now)
            }
            var newRows: [TodayRow] = []
            var waterTotal = Decimal(0)
            var skipped = 0
            var foodComponents: [IntakeComponent] = []
            for intake in intakes.sorted(by: { $0.occurredAt > $1.occurredAt }) {
                let revisions = try store.revisions(of: intake.id)
                let components = revisions.first { $0.number == intake.currentRevision }?.components ?? []
                if intake.category == "water" {
                    for component in components {
                        if component.unit.dimension == .volume,
                            let converted = try? Quantity(value: component.amount, unit: component.unit).converted(to: .mL)
                        {
                            waterTotal += converted.value
                        } else {
                            skipped += 1
                        }
                    }
                } else {
                    foodComponents.append(contentsOf: components)
                }
                newRows.append(
                    TodayRow(
                        id: intake.id,
                        title: components.map(\.name).joined(separator: ", "),
                        detail: components.map { Self.describe($0) }.joined(separator: ", "),
                        occurredAt: intake.occurredAt))
            }
            rows = newRows
            waterTotalMilliliters = waterTotal
            waterSkippedCount = skipped
            coverage = trackedNutrients.map { nutrient in
                CoverageLine.make(
                    nutrient: nutrient,
                    values: foodComponents.map { lookup.value(for: $0, nutrient: nutrient) })
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the journal."
        }
    }

    /// Writes one water intake (one `create`) and returns the undo handle, valid for 10 seconds.
    @discardableResult
    public func quickAddWater(milliliters: Decimal = 250, now: Date) -> UndoHandle? {
        let intake = Intake(
            id: makeID(), category: "water", occurredAt: now, timeZoneIdentifier: timeZoneIdentifier)
        let component = IntakeComponent(componentID: "water", name: "Water", amount: milliliters, unit: .mL)
        do {
            try store.create(intake, components: [component], product: nil, now: now)
        } catch {
            errorMessage = "Could not save the water."
            return nil
        }
        let handle = UndoHandle(intakeID: intake.id, expiresAt: now.addingTimeInterval(Self.undoWindow))
        undo = handle
        load(now: now)
        return handle
    }

    public func isUndoAvailable(now: Date) -> Bool {
        guard let undo else { return false }
        return now < undo.expiresAt
    }

    /// Deletes the last quick-added water while the window is open. Returns false once it expired.
    @discardableResult
    public func undoLastQuickAdd(now: Date) -> Bool {
        guard let handle = undo, now < handle.expiresAt else {
            undo = nil
            return false
        }
        do {
            try store.delete(intakeID: handle.intakeID, now: now)
        } catch {
            errorMessage = "Could not undo."
            return false
        }
        undo = nil
        load(now: now)
        return true
    }

    /// Spoken summary of the water total for assistive technology.
    public var waterAccessibilityValue: String {
        "\(DecimalFormatting.text(waterTotalMilliliters)) millilitres today"
    }

    static func isSameLocalDay(_ intake: Intake, as now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: intake.timeZoneIdentifier) ?? TimeZone.current
        return calendar.isDate(intake.occurredAt, inSameDayAs: now)
    }

    private static func describe(_ component: IntakeComponent) -> String {
        "\(DecimalFormatting.text(component.amount)) \(component.unit.symbol)"
    }
}

/// Locale-independent decimal text.
enum DecimalFormatting {
    static func text(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }
}
