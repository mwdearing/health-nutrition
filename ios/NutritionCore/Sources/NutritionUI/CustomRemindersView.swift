import SwiftUI

/// One water reminder and one supplement reminder, as inline settings rows: a switch each, and a time of
/// day while it is on. Shown in the Settings list, so there is no extra screen.
public struct CustomRemindersRows: View {
    @ObservedObject private var controller: CustomReminderController

    public init(controller: CustomReminderController) {
        self.controller = controller
    }

    public var body: some View {
        ForEach(CustomReminderKind.allCases, id: \.self) { kind in
            let reminder = controller.reminders.first { $0.kind == kind }
            Toggle("\(kind.title) reminder", isOn: Binding(
                get: { reminder?.isOn ?? false },
                set: { on in
                    Task {
                        if let reminder { await controller.setOn(on, id: reminder.id) }
                        else if on { await controller.add(kind) }
                    }
                }
            ))
            if let reminder, reminder.isOn {
                DatePicker("\(kind.title) time", selection: Binding(
                    get: { Self.date(for: reminder.time) },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        let time = ReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                        Task { await controller.setTime(time, id: reminder.id) }
                    }
                ), displayedComponents: .hourAndMinute)
            }
        }
        Text("Reminders on this phone at the times you choose. Nothing is sent anywhere.")
            .font(.footnote).foregroundStyle(TokenColors.textSecondary)
        if let message = controller.message {
            InlineNotice(message, tone: .failed)
        }
    }

    private static func date(for time: ReminderTime) -> Date {
        var parts = DateComponents(year: 2001, month: 1, day: 15, hour: time.hour, minute: time.minute)
        parts.calendar = Calendar.current
        return parts.date ?? Date()
    }
}
