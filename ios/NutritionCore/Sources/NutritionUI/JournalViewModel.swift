import Foundation
import NutritionDomain
import NutritionJournal

public struct JournalRow: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let occurredAt: Date
    public let timeZoneIdentifier: String
}

public struct JournalDaySection: Equatable, Identifiable {
    /// Local day in the intakes' own time zone, as yyyy-MM-dd.
    public let id: String
    public let rows: [JournalRow]
}

@MainActor
public final class JournalViewModel: ObservableObject {
    @Published public private(set) var sections: [JournalDaySection] = []
    /// Intakes left out because their time zone identifier is invalid or their record could not be read.
    @Published public private(set) var skippedCount: Int = 0
    @Published public private(set) var errorMessage: String?

    private let store: JournalStore
    private let repeater: IntakeRepeater

    public init(
        store: JournalStore,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.repeater = IntakeRepeater(store: store, timeZoneIdentifier: timeZoneIdentifier, makeID: makeID)
    }

    /// Groups active intakes by the local day of each intake's own time zone, newest first.
    public func load(now: Date) {
        do {
            var skipped = 0
            var groups: [String: [JournalRow]] = [:]
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
                    timeZoneIdentifier: intake.timeZoneIdentifier)
                groups[Self.dayKey(intake.occurredAt, zone: zone), default: []].append(row)
            }
            sections = groups.keys.sorted(by: >).map { key in
                JournalDaySection(id: key, rows: (groups[key] ?? []).sorted { $0.occurredAt > $1.occurredAt })
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
        } catch {
            errorMessage = "Could not repeat the entry."
            return nil
        }
    }

    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
