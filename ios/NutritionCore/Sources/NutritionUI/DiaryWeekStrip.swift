import SwiftUI

/// The seven days the Diary's "This week" summary covers, one column each, and the figures of the chosen day.
///
/// A plain value built by `JournalViewModel.weekStrip(chosen:now:)`, so the days, the dots and the figures are tested
/// without a screen. A day is logged by the rule the summary counts logged days with.
public struct DiaryWeekStripModel: Equatable {
    /// One day of the strip.
    public struct Day: Equatable, Identifiable {
        /// The Diary's yyyy-MM-dd key for the day.
        public let id: String
        /// The start of the day in the Diary's zone, the date the jump takes.
        public let date: Date
        /// The one-letter weekday, such as "M".
        public let letter: String
        /// The day of the month, such as "14".
        public let number: String
        /// The full weekday name, such as "Tuesday", for VoiceOver.
        public let weekday: String
        public let isLogged: Bool
        /// Where the arrows and the date sheet land for this date.
        public let jumpTarget: JournalJumpTarget

        /// "Tuesday 14, logged" or "Tuesday 14, not logged".
        public var accessibilityText: String {
            "\(weekday) \(number), \(isLogged ? "logged" : "not logged")"
        }
    }

    /// The seven days, oldest first, today last.
    public let days: [Day]
    /// The key of the chosen day.
    public let chosenID: String
    /// Calories, protein and water for the chosen day, as its day header words them.
    public let figures: JournalDayFigures

    public init(days: [Day], chosenID: String, figures: JournalDayFigures) {
        self.days = days
        self.chosenID = chosenID
        self.figures = figures
    }
}

/// The week strip inside the "This week" hero: a letter and a date circle per day, a dot under each logged day, and the
/// chosen day's calories, protein and water. A tap on a day chooses it and asks for its jump.
public struct DiaryWeekStrip: View {
    private let model: DiaryWeekStripModel
    private let onSelect: (DiaryWeekStripModel.Day) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(model: DiaryWeekStripModel, onSelect: @escaping (DiaryWeekStripModel.Day) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(model.days) { day in
                    dayButton(day)
                }
            }
            Rectangle()
                .fill(TokenColors.heroTrack)
                .frame(height: 1)
                .accessibilityHidden(true)
            figures
        }
    }

    private func dayButton(_ day: DiaryWeekStripModel.Day) -> some View {
        let chosen = day.id == model.chosenID
        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: DesignSpacing.xs) {
                Text(day.letter)
                    .font(.caption)
                    .foregroundStyle(TokenColors.heroSecondaryText)
                Text(day.number)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(chosen ? TokenColors.hero : TokenColors.heroText)
                    .frame(width: 36, height: 36)
                    .background(chosen ? TokenColors.mint : Color.clear, in: Circle())
                Circle()
                    .fill(day.isLogged && !chosen ? TokenColors.mint : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibilityText)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var figures: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DesignSpacing.s))
        layout {
            figure("Calories", model.figures.calories)
            if let protein = model.figures.protein { figure("Protein", protein) }
            if let water = model.figures.water { figure("Water", water) }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(TokenColors.heroSecondaryText)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TokenColors.heroText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension JournalViewModel {
    /// What a figure reads on a day logged only in Apple Health when Health states no value for it.
    static let loggedInHealthText = "Logged in Apple Health"

    /// The strip for the week summary's seven days, or nil when the journal has no week card. `chosen` is a day key
    /// from the strip; nil, or a key outside the week, chooses today. The figures come from the chosen day's section, so
    /// they read exactly as its header does; a day with no section reads the header's empty wording.
    public func weekStrip(chosen: String?, now: Date) -> DiaryWeekStripModel? {
        let zone = dayZone
        guard let found = Self.weekLogged(sections: sections, now: now, zone: zone, outsideByDay: outsideIntakeByDay)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = locale
        let loggedKeys = found.loggedKeys
        let startOfToday = calendar.startOfDay(for: now)
        let days: [DiaryWeekStripModel.Day] = (0..<7).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: startOfToday) else { return nil }
            let key = Self.dayKey(date, zone: zone)
            let parts = calendar.dateComponents([.weekday, .day], from: date)
            let index = (parts.weekday ?? 1) - 1
            return DiaryWeekStripModel.Day(
                id: key, date: date,
                letter: calendar.veryShortWeekdaySymbols[index],
                number: String(parts.day ?? 0),
                weekday: calendar.weekdaySymbols[index],
                isLogged: loggedKeys.contains(key),
                jumpTarget: jumpTarget(for: date, now: now))
        }
        guard let today = days.last else { return nil }
        let chosenID = chosen.flatMap { id in days.contains { $0.id == id } ? id : nil } ?? today.id
        let empty = JournalDayFigures(
            calories: Self.nothingLoggedText, protein: Self.nothingLoggedText, water: Self.nothingLoggedText)
        let figures: JournalDayFigures
        if let section = diarySections.first(where: { $0.id == chosenID }) {
            figures = section.stripFigures
        } else if let outside = outsideIntakeByDay[chosenID], outside.statesIntake {
            // A day logged only through Apple Health has no section: show what Health states, and say where the rest is.
            let fromHealth = Self.stripFigures(
                totals: DailyTotals(totals: [:]), goals: storedGoalsForStrip(), hasFoodEntries: false,
                unitSystem: preferences.unitSystem, hidden: hiddenTodayGoals(in: preferences), outside: outside)
            func fill(_ text: String) -> String { text == Self.nothingLoggedText ? Self.loggedInHealthText : text }
            figures = JournalDayFigures(
                calories: fill(fromHealth.calories), protein: fromHealth.protein.map(fill),
                water: fromHealth.water.map(fill))
        } else {
            figures = empty
        }
        return DiaryWeekStripModel(days: days, chosenID: chosenID, figures: figures)
    }
}
