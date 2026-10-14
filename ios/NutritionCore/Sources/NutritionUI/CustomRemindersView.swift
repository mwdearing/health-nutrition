import SwiftUI

/// The list of water and supplement reminders: each has a switch and a time of day, and can be deleted.
public struct CustomRemindersView: View {
    @ObservedObject private var controller: CustomReminderController

    public init(controller: CustomReminderController) {
        self.controller = controller
    }

    public var body: some View {
        List {
            Section {
                ForEach(controller.reminders) { reminder in
                    VStack(alignment: .leading) {
                        Toggle(reminder.kind.title, isOn: Binding(
                            get: { reminder.isOn },
                            set: { on in Task { await controller.setOn(on, id: reminder.id) } }
                        ))
                        DatePicker("Time", selection: Binding(
                            get: { Self.date(for: reminder.time) },
                            set: { date in
                                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                                let time = ReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                                Task { await controller.setTime(time, id: reminder.id) }
                            }
                        ), displayedComponents: .hourAndMinute)
                    }
                    .accessibilityElement(children: .contain)
                }
                .onDelete { offsets in
                    let ids = offsets.map { controller.reminders[$0].id }
                    Task { for id in ids { await controller.remove(id: id) } }
                }
            }
            Section {
                Button("Add a water reminder") { Task { await controller.add(.water) } }
                    .disabled(!controller.canAdd)
                Button("Add a supplement reminder") { Task { await controller.add(.supplement) } }
                    .disabled(!controller.canAdd)
                Text("Reminders are on this phone only. Nothing is sent anywhere.")
                    .font(.footnote).foregroundStyle(TokenColors.textSecondary)
                if let message = controller.message {
                    InlineNotice(message, tone: .failed)
                }
            }
        }
        .navigationTitle("Reminders")
    }

    private static func date(for time: ReminderTime) -> Date {
        var parts = DateComponents(year: 2001, month: 1, day: 15, hour: time.hour, minute: time.minute)
        parts.calendar = Calendar.current
        return parts.date ?? Date()
    }
}
