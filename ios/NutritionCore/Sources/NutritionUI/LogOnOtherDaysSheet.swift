import SwiftUI

/// Picks past days to log an entry on again. Nothing is logged until Log. Log works once at a time: it is
/// held while a log runs, so a second tap cannot log the same days twice.
public struct LogOnOtherDaysSheet: View {
    /// What a Log did, as the sheet needs it.
    public enum Attempt: Equatable {
        /// Nothing was logged: the sheet stays open with the reason it is given.
        case stay
        /// The sheet closes; the screen behind it says or shows the rest.
        case close
        /// Something was logged and some chosen days were skipped: the sheet stays open to say which, and
        /// Done then closes it.
        case loggedWithSkips(String)
    }

    /// How far back days can be picked.
    public static let daysBack = 30
    private let now: () -> Date
    private let onLog: (Set<String>) -> Attempt
    private let onCancel: () -> Void
    private let onDone: () -> Void
    private let message: String?
    @State private var days: Set<DateComponents> = []
    /// True once Log was tapped, so the sheet shows only the reason its own attempt gave.
    @State private var tried = false
    @State private var logging = false
    /// What a log that skipped some days says; set, the sheet offers only Done.
    @State private var loggedNotice: String?

    public init(
        now: @escaping () -> Date = { Date() }, message: String? = nil,
        onLog: @escaping (Set<String>) -> Attempt, onCancel: @escaping () -> Void, onDone: @escaping () -> Void
    ) {
        self.now = now
        self.message = message
        self.onLog = onLog
        self.onCancel = onCancel
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The multi-day calendar is an iPhone control; the package's macOS test build has none.
                    #if os(iOS)
                    MultiDatePicker("Days", selection: $days, in: Self.range(now: now()))
                    #else
                    Text("Choosing days needs the iPhone calendar.")
                    #endif
                } footer: {
                    Text("Adds a new entry on each day, at the same time of day and with the same amounts and meal. This entry's own day and times still to come are skipped. Up to \(IntakeMultiDayLogger.maximumDays) days at once.")
                }
                if let loggedNotice {
                    InlineNotice(loggedNotice, tone: .waiting)
                } else if tried, let message {
                    InlineNotice(message, tone: .failed)
                }
            }
            .navigationTitle("Log on other days")
            .toolbar {
                if loggedNotice == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Log") {
                            guard !logging else { return }
                            tried = true
                            logging = true
                            switch onLog(Set(days.compactMap(IntakeMultiDayLogger.dayKey))) {
                            case .stay: logging = false
                            // Held after a log, so a tap during the dismissal does nothing.
                            case .close: break
                            case .loggedWithSkips(let notice): loggedNotice = notice
                            }
                        }
                        .disabled(logging || days.isEmpty || days.count > IntakeMultiDayLogger.maximumDays)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
    }

    /// "Logged on 2 days. Skipped Nov 10 (this entry's day) and Nov 15 (in the future)." Nil when no day
    /// was skipped. Days read as the device shows a month and day, with the year when it is not this year,
    /// and the list is joined as the device joins one.
    public static func loggedText(
        _ result: IntakeMultiDayResult, now: Date, locale: Locale = .current, calendar: Calendar = .current
    ) -> String? {
        guard !result.skipped.isEmpty else { return nil }
        let thisYear = calendar.component(.year, from: now)
        let parts = result.skipped.map { skipped -> String in
            "\(dayText(skipped.day, thisYear: thisYear, locale: locale, calendar: calendar)) (\(reasonText(skipped.reason)))"
        }
        let formatter = ListFormatter()
        formatter.locale = locale
        let list = formatter.string(from: parts) ?? parts.joined(separator: ", ")
        let logged = result.createdIDs.count == 1 ? "1 day" : "\(result.createdIDs.count) days"
        return "Logged on \(logged). Skipped \(list)."
    }

    static func reasonText(_ reason: MultiDaySkipReason) -> String {
        switch reason {
        case .entryDay: return "this entry's day"
        case .laterToday: return "later today"
        case .future: return "in the future"
        case .notADate: return "not a date"
        }
    }

    /// A yyyy-MM-dd day as the device shows a month and day; the key itself when it is not one.
    static func dayText(_ key: String, thisYear: Int, locale: Locale, calendar: Calendar) -> String {
        guard var parts = IntakeMultiDayLogger.dayParts(key) else { return key }
        // Noon, so no clock change moves the date to another day.
        parts.hour = 12
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard let date = gregorian.date(from: parts) else { return key }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if parts.year != thisYear { style = style.year() }
        return date.formatted(style)
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
                let at = now()
                switch model.logOnDays(days, now: at) {
                case .logged(let result):
                    // Skipped days are said before the entry closes; with none, it closes at once.
                    if let notice = LogOnOtherDaysSheet.loggedText(result, now: at) { return .loggedWithSkips(notice) }
                    showing = false
                    onFinished()
                    return .close
                case .leftEntries:
                    // The entry screen says what was left; the sheet closes so the days are not logged twice.
                    showing = false
                    return .close
                case .nothingLogged:
                    return .stay
                }
            }, onCancel: { showing = false }, onDone: {
                showing = false
                onFinished()
            })
            .onAppear { model.clearMultiDayMessage() }
        }
    }
}
