import Foundation
import NutritionDomain
import NutritionJournal

/// One medication's reminder: whether it is on is whether a setting exists, and the time of day it fires.
public struct MedicationReminderSetting: Codable, Equatable, Sendable {
    public let medicationID: UUID
    public private(set) var hour: Int
    public private(set) var minute: Int

    public init(medicationID: UUID, time: ReminderTime) {
        self.medicationID = medicationID
        self.hour = time.hour
        self.minute = time.minute
    }

    public var time: ReminderTime {
        get { ReminderTime(hour: hour, minute: minute) }
        set {
            hour = newValue.hour
            minute = newValue.minute
        }
    }
}

/// One notification that should be pending: the day and time it fires and the identifier it is filed under.
public struct MedicationReminderRequest: Equatable, Sendable {
    public let medicationID: UUID
    public let day: CalendarDay
    public let time: ReminderTime
    public let identifier: String

    public init(medicationID: UUID, day: CalendarDay, time: ReminderTime, identifier: String) {
        self.medicationID = medicationID
        self.day = day
        self.time = time
        self.identifier = identifier
    }
}

/// Which medication reminders are pending. A pure function of the log, the settings and the clock.
public enum MedicationReminderPlan {
    /// The prefix of every medication reminder's request identifier.
    public static let identifierPrefix = "medication-reminder-"
    /// At most this many requests are pending at once, so the daily and custom reminders keep room under the system's limit.
    public static let maximumPending = 20
    /// The text names no medication and no dose.
    public static let notificationTitle = "Medication log"
    public static let notificationBody = "A dose in your medication log is due today."

    /// One request per medication that has a setting, is active, keeps a schedule and has a dose with a readable day:
    /// on the schedule's next day at the picked time, when that moment is still ahead. Nothing while the log is off.
    public static func requests(
        medications: [Medication], doses: [MedicationDose], settings: [MedicationReminderSetting],
        logIsOn: Bool, now: Date, timeZone: TimeZone
    ) -> [MedicationReminderRequest] {
        guard logIsOn else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var seen = Set<UUID>()
        var found: [MedicationReminderRequest] = []
        for setting in settings where seen.insert(setting.medicationID).inserted {
            guard let medication = medications.first(where: { $0.id == setting.medicationID }),
                  !medication.isArchived, medication.scheduleDays != nil,
                  let last = MedicationLog.lastDose(of: medication.id, in: doses),
                  let day = MedicationLog.nextByScheduleDay(medication, lastDose: last)
            else { continue }
            let parts = DateComponents(
                year: day.year, month: day.month, day: day.day, hour: setting.time.hour, minute: setting.time.minute)
            guard let moment = calendar.date(from: parts), moment > now else { continue }
            found.append(MedicationReminderRequest(
                medicationID: medication.id, day: day, time: setting.time,
                identifier: identifierPrefix + medication.id.uuidString))
        }
        found.sort { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.time.hour != rhs.time.hour { return lhs.time.hour < rhs.time.hour }
            if lhs.time.minute != rhs.time.minute { return lhs.time.minute < rhs.time.minute }
            return lhs.identifier < rhs.identifier
        }
        return Array(found.prefix(maximumPending))
    }
}

/// The seam to the system's local notifications for the medication reminders.
public protocol MedicationReminderScheduling: AnyObject, Sendable {
    /// Makes the pending medication requests exactly `requests`; removes any other one. Throws when the system refuses.
    func replaceAll(with requests: [MedicationReminderRequest]) async throws
    /// Removes every pending and delivered request under `MedicationReminderPlan.identifierPrefix`, and has done so
    /// when it returns, so an erase can finish before its readback runs.
    func cancelAll()
    /// Removes the pending and delivered requests of these medications, synchronously, so an erase has finished
    /// removing them when it returns. The default removes every medication request.
    func cancel(medicationIDs: [UUID])
}

extension MedicationReminderScheduling {
    public func cancel(medicationIDs: [UUID]) { cancelAll() }
}

/// Where the medication reminder settings are kept.
public protocol MedicationReminderStoring: AnyObject {
    var settings: [MedicationReminderSetting] { get }
    func save(_ settings: [MedicationReminderSetting])
    func clear()
}

/// Keeps the settings as JSON under one key in the app's defaults domain. Unreadable data reads as none.
public final class UserDefaultsMedicationReminderStore: MedicationReminderStoring {
    public static let key = "display.reminders.medication"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: [MedicationReminderSetting] {
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([MedicationReminderSetting].self, from: data)
        else { return [] }
        return list
    }

    public func save(_ settings: [MedicationReminderSetting]) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Settings held in memory, for tests.
public final class InMemoryMedicationReminderStore: MedicationReminderStoring {
    public private(set) var settings: [MedicationReminderSetting] = []

    public init() {}

    public func save(_ settings: [MedicationReminderSetting]) { self.settings = settings }
    public func clear() { settings = [] }
}

/// Drives the per-medication reminders and keeps the system's pending requests equal to the plan.
@MainActor
public final class MedicationReminderController: ObservableObject {
    public static let refusedMessage =
        "The reminders could not be set. Check the notification settings for this app and try again."

    @Published public private(set) var settings: [MedicationReminderSetting]
    @Published public private(set) var message: String?

    private let store: MedicationReminderStoring
    private let permissions: ReminderScheduling
    private let scheduler: MedicationReminderScheduling
    private let medications: MedicationStore
    private let preferences: MedicationLogPreferences
    private let erasures: ReminderErasures
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private var tail: Task<Void, Never>?

    public init(
        store: MedicationReminderStoring, permissions: ReminderScheduling, scheduler: MedicationReminderScheduling,
        medications: MedicationStore, preferences: MedicationLogPreferences,
        erasures: ReminderErasures = ReminderErasures(), now: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.store = store
        self.permissions = permissions
        self.scheduler = scheduler
        self.medications = medications
        self.preferences = preferences
        self.erasures = erasures
        self.now = now
        self.timeZone = timeZone
        self.settings = store.settings
    }

    /// The time the medication's reminder fires at, nil while it is off.
    public func time(for medicationID: UUID) -> ReminderTime? {
        settings.first { $0.medicationID == medicationID }?.time
    }

    /// Switches the medication's reminder on at `time`, changes its time, or switches it off with nil. Switching on
    /// asks for permission only when it is not yet decided.
    public func setReminder(_ time: ReminderTime?, for medicationID: UUID) async {
        var list = store.settings.filter { $0.medicationID != medicationID }
        if let time { list.append(MedicationReminderSetting(medicationID: medicationID, time: time)) }
        commit(list)
        await apply(askForPermission: time != nil)
    }

    /// Brings the system in line with the stored settings and the log. Never asks for permission.
    public func sync() async {
        settings = store.settings
        if message == ReminderController.withdrawnMessage, await permissions.permission() == .allowed { message = nil }
        await apply(askForPermission: false)
    }

    /// Re-reads the stored settings after Erase all data cleared them.
    public func refreshFromStore() {
        erasures.record()
        settings = store.settings
        message = nil
    }

    /// One line on what is pending for the medication, or why nothing is. Nil while its reminder is off.
    public func footer(for medicationID: UUID) -> String? {
        guard let picked = time(for: medicationID) else { return nil }
        guard preferences.isMedicationLogOn else { return "Nothing is scheduled while the Medication log is off." }
        guard let list = try? medications.medications(), let doses = try? medications.allDoses() else {
            return "The medication log could not be read, so nothing is scheduled."
        }
        let zone = timeZone()
        let planned = MedicationReminderPlan.requests(
            medications: list, doses: doses, settings: store.settings, logIsOn: true, now: now(), timeZone: zone)
        if let request = planned.first(where: { $0.medicationID == medicationID }) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = DateComponents(
                year: request.day.year, month: request.day.month, day: request.day.day, hour: picked.hour,
                minute: picked.minute)
            guard let date = calendar.date(from: parts) else { return nil }
            return "Next reminder: " + date.formatted(date: .abbreviated, time: .shortened) + "."
        }
        guard let medication = list.first(where: { $0.id == medicationID }),
              let last = MedicationLog.lastDose(of: medicationID, in: doses)
        else { return "Nothing is scheduled until a dose is logged." }
        guard let next = MedicationLog.nextByScheduleDay(medication, lastDose: last) else {
            return "Nothing is scheduled because the day of the last dose cannot be read."
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        if let year = parts.year, let month = parts.month, let day = parts.day,
           let today = CalendarDay(year: year, month: month, day: day), next < today {
            return "Nothing is scheduled: the day after the last dose has passed. Logging a dose sets the next one."
        }
        return "Nothing is scheduled: the time you picked has already passed today."
    }

    private func commit(_ list: [MedicationReminderSetting]) {
        store.save(list)
        settings = list
        message = nil
    }

    /// Queues one reconcile behind the last. Each reads the stored settings when its turn comes.
    private func apply(askForPermission: Bool) async {
        let erased = erasures.count
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard erased == self.erasures.count else { return }
            await self.reconcile(askForPermission: askForPermission, erased: erased)
        }
        tail = task
        await task.value
    }

    private func reconcile(askForPermission: Bool, erased: Int) async {
        guard !store.settings.isEmpty else {
            try? await scheduler.replaceAll(with: [])
            return
        }
        let list: [Medication]
        let doses: [MedicationDose]
        do {
            list = try medications.medications()
            doses = try medications.allDoses()
        } catch {
            // The log cannot be read: nothing can be said to be due, so nothing stays pending. The settings stay.
            scheduler.cancelAll()
            return
        }
        let stored = Set(list.map(\.id))
        let kept = store.settings.filter { stored.contains($0.medicationID) }
        if kept.count != store.settings.count { commit(kept, keepingMessage: true) }
        guard !kept.isEmpty, preferences.isMedicationLogOn else {
            try? await scheduler.replaceAll(with: [])
            return
        }
        var permission = await permissions.permission()
        guard erased == erasures.count else { return }
        if permission == .notDetermined, askForPermission {
            let granted = await permissions.requestPermission()
            guard erased == erasures.count else { return }
            permission = granted ? .allowed : .denied
        }
        guard permission == .allowed else {
            switchAllOff(message: ReminderController.withdrawnMessage)
            try? await scheduler.replaceAll(with: [])
            return
        }
        let requests = MedicationReminderPlan.requests(
            medications: list, doses: doses, settings: kept, logIsOn: true, now: now(), timeZone: timeZone())
        do {
            try await scheduler.replaceAll(with: requests)
        } catch {
            if erased == erasures.count {
                switchAllOff(message: Self.refusedMessage)
                try? await scheduler.replaceAll(with: [])
            }
            return
        }
        if erased != erasures.count { scheduler.cancelAll() }
    }

    private func commit(_ list: [MedicationReminderSetting], keepingMessage: Bool) {
        store.save(list)
        settings = list
        if !keepingMessage { message = nil }
    }

    private func switchAllOff(message text: String) {
        store.save([])
        settings = []
        message = text
    }
}

/// Removes the medication reminders' pending requests and stored settings when Erase all data runs.
public final class MedicationReminderEraser: JournalErasing, @unchecked Sendable {
    private let store: MedicationReminderStoring
    private let scheduler: MedicationReminderScheduling
    private let erasures: ReminderErasures

    public init(store: MedicationReminderStoring, scheduler: MedicationReminderScheduling, erasures: ReminderErasures) {
        self.store = store
        self.scheduler = scheduler
        self.erasures = erasures
    }

    public var erasureName: String { "medication reminders" }

    public func eraseAll() {
        erasures.record()
        let ids = store.settings.map(\.medicationID)
        store.clear()
        scheduler.cancel(medicationIDs: ids)
        // Settings that could not be read leave no ids, so every request under the prefix goes too.
        scheduler.cancelAll()
    }
}
