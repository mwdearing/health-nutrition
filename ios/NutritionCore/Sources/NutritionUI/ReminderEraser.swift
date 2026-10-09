import Foundation
import NutritionJournal

/// Removes the daily reminder's pending request when Erase all data runs. The stored setting is reset
/// by the display preferences reset that the same erase performs.
public final class ReminderEraser: JournalErasing, @unchecked Sendable {
    private let scheduler: ReminderScheduling

    public init(scheduler: ReminderScheduling) {
        self.scheduler = scheduler
    }

    public func eraseAll() throws {
        scheduler.cancelDaily()
    }
}
