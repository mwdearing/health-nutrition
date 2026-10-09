import Foundation
import NutritionJournal

/// Removes the daily reminder's pending request when Erase all data runs. The stored setting is reset
/// by the display preferences reset that the same erase performs.
///
/// It also records the erase, so a reminder action that was already waiting on the system when the erase
/// ran stands down instead of writing its result back.
public final class ReminderEraser: JournalErasing, @unchecked Sendable {
    private let scheduler: ReminderScheduling
    private let erasures: ReminderErasures

    public init(scheduler: ReminderScheduling, erasures: ReminderErasures = ReminderErasures()) {
        self.scheduler = scheduler
        self.erasures = erasures
    }

    public func eraseAll() throws {
        erasures.record()
        scheduler.cancelDaily()
    }
}
