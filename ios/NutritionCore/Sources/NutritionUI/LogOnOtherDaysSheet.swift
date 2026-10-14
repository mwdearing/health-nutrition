import SwiftUI

/// Picks past days to log an entry on again. Nothing is logged until Log; `onLog` returns false to keep the
/// sheet open when nothing was logged, so the reason it shows stays in view. Log works once at a time: it
/// is held while a log runs, so a second tap cannot log the same days twice.
public struct LogOnOtherDaysSheet: View {
    /// How far back days can be picked.
    public static let daysBack = 30
    private let now: () -> Date
    private let onLog: (Set<String>) -> Bool
    private let onCancel: () -> Void
    private let message: String?
    @State private var days: Set<DateComponents> = []
    /// True once Log was tapped, so the sheet shows only the reason its own attempt gave.
    @State private var tried = false
    @State private var logging = false

    public init(
        now: @escaping () -> Date = { Date() }, message: String? = nil,
        onLog: @escaping (Set<String>) -> Bool, onCancel: @escaping () -> Void
    ) {
        self.now = now
        self.message = message
        self.onLog = onLog
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    MultiDatePicker("Days", selection: $days, in: Self.range(now: now()))
                } footer: {
                    Text("Adds a new entry on each day, at the same time of day and with the same amounts and meal. This entry's own day and times still to come are skipped. Up to \(IntakeMultiDayLogger.maximumDays) days at once.")
                }
                if tried, let message { InlineNotice(message, tone: .failed) }
            }
            .navigationTitle("Log on other days")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        guard !logging else { return }
                        tried = true
                        logging = true
                        // Held after a log that closes the sheet, so a tap during the dismissal does nothing.
                        logging = onLog(Set(days.compactMap(IntakeMultiDayLogger.dayKey)))
                    }
                    .disabled(logging || days.isEmpty || days.count > IntakeMultiDayLogger.maximumDays)
                }
            }
        }
    }

    /// From the start of the day `daysBack` days ago to the end of today, in the device's calendar.
    static func range(now: Date) -> Range<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return start..<end
    }
}

/// The entry screen's "Log on other days" row and its sheet. It closes the entry once something was logged,
/// as Log again does.
struct LogOnOtherDaysButton: View {
    @ObservedObject var model: EntryDetailViewModel
    let now: () -> Date
    let onFinished: () -> Void
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Text("Log on other days").font(.body)
        }
        .accessibilityHint("Adds new entries with the same amounts on days you choose")
        .sheet(isPresented: $showing) {
            LogOnOtherDaysSheet(now: now, message: model.multiDayMessage, onLog: { days in
                switch model.logOnDays(days, now: now()) {
                case .logged:
                    showing = false
                    onFinished()
                    return true
                case .leftEntries:
                    // The entry screen says what was left; the sheet closes so the days are not logged twice.
                    showing = false
                    return true
                case .nothingLogged:
                    return false
                }
            }, onCancel: { showing = false })
            .onAppear { model.clearMultiDayMessage() }
        }
    }
}
