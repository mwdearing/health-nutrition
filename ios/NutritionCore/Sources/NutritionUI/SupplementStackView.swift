import NutritionDomain
import SwiftUI

/// The supplement list: each item with today's times, a "Taken" button that logs one entry now, and the
/// way to add items and change their times. Reached from the Library.
public struct SupplementStackView: View {
    @ObservedObject var model: SupplementStackViewModel
    private let now: () -> Date
    /// Called after an entry was logged or undone, so the other screens reload.
    private let onLogged: () -> Void
    @State private var adding = false
    @State private var editing: SupplementStackRow?
    @Environment(\.scenePhase) private var scenePhase

    public init(
        model: SupplementStackViewModel, now: @escaping () -> Date = { Date() }, onLogged: @escaping () -> Void = {}
    ) {
        self.model = model
        self.now = now
        self.onLogged = onLogged
    }

    public var body: some View {
        List {
            if model.unreadableEntriesToday > 0 {
                InlineNotice(
                    "\(model.unreadableEntriesToday) of today's entries can't be read, so a time may show "
                        + "Not logged when it was taken.",
                    tone: .waiting)
            }
            // A list that could not be read is not an empty one, so the empty state waits for a good read.
            if model.rows.isEmpty, !model.readFailed {
                EmptyState(
                    title: "No supplements on your list",
                    message: "Add something you take and the times you take it. Each tap on Taken logs one entry.",
                    systemImage: "pills", actionTitle: "Add a supplement", action: { self.adding = true })
            } else {
                Section {
                    ForEach(model.rows) { row in
                        self.stackRow(row)
                    }
                } footer: {
                    Text(
                        "Taken counts today's entries of each item, including ones logged from the Library. "
                            + "Each Taken is an ordinary entry, written to Apple Health like any other once you connect it.")
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("My supplements")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { self.adding = true } label: {
                    Label("Add a supplement", systemImage: "plus")
                }
            }
        }
        .onAppear { self.model.appeared(now: self.now()) }
        .onDisappear { self.model.disappeared() }
        // Back from the background, anything may have been logged elsewhere, so everything is read again.
        // While on screen, the times move on once a minute from what was already read (a time that passes
        // reads "Not logged"); only a new day reads the journal again, which clears yesterday's marks.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { self.model.load(now: self.now()) }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self.model.refreshClock(now: self.now())
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                SupplementStackPicker(model: model, now: now, onDone: { self.adding = false })
            }
        }
        .sheet(item: $editing) { row in
            NavigationStack {
                SupplementScheduleEditor(
                    model: model, title: row.title, initial: row.schedule,
                    onSave: { schedule in
                        if self.model.setSchedule(schedule, for: row.id, now: self.now()) { self.editing = nil }
                    },
                    onRemove: {
                        if self.model.remove(favoriteID: row.id, now: self.now()) { self.editing = nil }
                    },
                    onCancel: { self.editing = nil })
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let token = model.undoToken {
                UndoToast(token.message) {
                    if self.model.undo(now: self.now()) { self.onLogged() }
                }
                .padding(DesignSpacing.m)
                .task(id: token.intakeID) {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self.model.expireUndo(token)
                }
            }
        }
    }

    @ViewBuilder
    private func stackRow(_ row: SupplementStackRow) -> some View {
        HStack(alignment: .top) {
            Button { self.editing = row } label: {
                VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                    Text(row.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                    Text(row.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                    Text(SupplementStackText.summary(row.schedule))
                        .font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    ForEach(Array(row.slots.enumerated()), id: \.offset) { _, slot in
                        SupplementSlotLine(slot: slot)
                    }
                    Text(row.statusText).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens its times and days")
            Spacer()
            QuietCapsule("Taken") {
                if self.model.markTaken(row, now: self.now()) { self.onLogged() }
            }
            .disabled(!row.canLog)
            .accessibilityLabel("Log \(row.title) as taken now")
        }
    }
}

/// One of today's times: a mark and the words, never color alone.
private struct SupplementSlotLine: View {
    let slot: SupplementSlot

    var body: some View {
        Label {
            Text(SupplementStackText.slot(slot))
        } icon: {
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(slot.state == .taken ? TokenColors.accent : TokenColors.textSecondary)
    }

    private var symbol: String {
        switch slot.state {
        case .taken: return "checkmark.circle.fill"
        case .later: return "circle"
        case .notLogged: return "circle.dashed"
        }
    }
}

/// What can go on the list: favorites first, then supplements logged recently. Picking one opens its times.
struct SupplementStackPicker: View {
    @ObservedObject var model: SupplementStackViewModel
    let now: () -> Date
    let onDone: () -> Void

    var body: some View {
        List {
            if model.candidates.isEmpty {
                EmptyState(
                    title: "Nothing to add yet",
                    message: "Log a supplement, or star something in the Library, and it shows up here.",
                    systemImage: "star")
            }
            ForEach(model.candidates) { candidate in
                NavigationLink {
                    SupplementScheduleEditor(
                        model: model, title: candidate.title, initial: .standard,
                        onSave: { schedule in
                            if self.model.add(candidate, schedule: schedule, now: self.now()) { self.onDone() }
                        },
                        onRemove: nil, onCancel: nil)
                } label: {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                        Text(candidate.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                        Text(candidate.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                        if let tag = KindTag(kind: candidate.kind) { tag }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Add a supplement")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDone)
            }
        }
    }
}

/// The times and days of one item. Save is off until the times and days make a schedule.
struct SupplementScheduleEditor: View {
    /// One time on the form. Identified, so removing a time never shifts another row's picker.
    private struct EditableTime: Identifiable {
        let id = UUID()
        var time: ReminderTime
    }

    @ObservedObject var model: SupplementStackViewModel
    let title: String
    let onSave: (SupplementSchedule) -> Void
    let onRemove: (() -> Void)?
    let onCancel: (() -> Void)?
    @State private var times: [EditableTime]
    @State private var weekdays: Set<Int>

    init(
        model: SupplementStackViewModel, title: String, initial: SupplementSchedule,
        onSave: @escaping (SupplementSchedule) -> Void, onRemove: (() -> Void)?, onCancel: (() -> Void)?
    ) {
        self.model = model
        self.title = title
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        _times = State(initialValue: initial.times.map { EditableTime(time: $0) })
        _weekdays = State(initialValue: initial.weekdays)
    }

    private var schedule: SupplementSchedule? {
        SupplementSchedule(times: times.map(\.time), weekdays: weekdays)
    }

    /// Why Save is off, in words.
    private var problem: String? {
        if weekdays.isEmpty { return "Choose at least one day." }
        if Set(times.map { SupplementSchedule.minuteOfDay($0.time) }).count != times.count {
            return "Two times are the same."
        }
        return nil
    }

    var body: some View {
        Form {
            Section("Times") {
                ForEach($times) { $item in
                    HStack {
                        DatePicker(
                            "Time", selection: Binding(
                                get: { Self.date(for: item.time) },
                                set: { item.time = Self.time(from: $0) }),
                            displayedComponents: .hourAndMinute)
                        if times.count > 1 {
                            Button {
                                self.times.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "minus.circle").accessibilityHidden(true)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(SupplementStackText.time(item.time))")
                        }
                    }
                }
                if times.count < SupplementSchedule.maxTimesPerDay {
                    Button("Add a time") { self.times.append(EditableTime(time: self.nextTime)) }
                }
            }
            Section("Days") {
                ForEach(SupplementStackText.weekdayOrder, id: \.self) { weekday in
                    Toggle(SupplementStackText.weekdayNames[weekday - 1], isOn: Binding(
                        get: { self.weekdays.contains(weekday) },
                        set: { on in
                            if on { self.weekdays.insert(weekday) } else { self.weekdays.remove(weekday) }
                        }))
                }
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(TokenColors.error)
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            if let onRemove {
                Section {
                    Button("Remove from my supplements", role: .destructive, action: onRemove)
                } footer: {
                    Text("The favorite and every entry you logged stay.")
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if let onCancel { Button("Cancel", action: onCancel) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let schedule { self.onSave(schedule) }
                }
                .disabled(schedule == nil)
            }
        }
    }

    /// The first of a few usual times that is not on the form yet.
    private var nextTime: ReminderTime {
        let taken = Set(times.map { SupplementSchedule.minuteOfDay($0.time) })
        let usual = [(8, 0), (20, 0), (12, 0), (18, 0), (22, 0), (6, 0)].map { ReminderTime(hour: $0.0, minute: $0.1) }
        return usual.first { !taken.contains(SupplementSchedule.minuteOfDay($0)) } ?? ReminderTime(hour: 12, minute: 0)
    }

    /// The picker's date for a stored time: that time on a fixed day with no clock change (15 January
    /// 2001), as the reminder picker does. Today may be the day clocks spring forward, when 02:30 does not
    /// exist and would read, and save, as 03:30.
    static func date(for time: ReminderTime, calendar: Calendar = .current) -> Date {
        var parts = DateComponents(year: 2001, month: 1, day: 15, hour: time.hour, minute: time.minute)
        parts.calendar = calendar
        return parts.date ?? Date()
    }

    static func time(from date: Date, calendar: Calendar = .current) -> ReminderTime {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return ReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}
