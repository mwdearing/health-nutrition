import Foundation
import NutritionJournal

/// What a custom reminder is about. The notification text names no health data.
public enum CustomReminderKind: String, Codable, CaseIterable, Sendable {
    case water
    case supplement

    public var title: String {
        switch self {
        case .water: return "Water"
        case .supplement: return "Supplements"
        }
    }

    public var notificationTitle: String {
        switch self {
        case .water: return "Time for some water"
        case .supplement: return "Time for your supplements"
        }
    }

    public var notificationBody: String {
        switch self {
        case .water: return "Open Health Nutrition to log a glass."
        case .supplement: return "Open Health Nutrition to log them."
        }
    }

    /// The time a new reminder of this kind starts at, before the person changes it.
    public var defaultTime: ReminderTime {
        switch self {
        case .water: return ReminderTime(hour: 10, minute: 0)
        case .supplement: return ReminderTime(hour: 8, minute: 0)
        }
    }
}

/// One local reminder: a kind, a time of day, and whether it is on.
public struct CustomReminder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: CustomReminderKind
    public private(set) var hour: Int
    public private(set) var minute: Int
    public var isOn: Bool

    public init(id: UUID = UUID(), kind: CustomReminderKind, time: ReminderTime, isOn: Bool = true) {
        self.id = id
        self.kind = kind
        self.hour = time.hour
        self.minute = time.minute
        self.isOn = isOn
    }

    public var time: ReminderTime {
        get { ReminderTime(hour: hour, minute: minute) }
        set {
            hour = newValue.hour
            minute = newValue.minute
        }
    }
}

/// Where the list of custom reminders is kept.
public protocol CustomReminderStoring: AnyObject {
    var reminders: [CustomReminder] { get }
    func save(_ reminders: [CustomReminder])
    func clear()
}

/// Keeps the list as JSON under one key in the app's defaults domain. Unreadable data reads as no reminders.
public final class UserDefaultsCustomReminderStore: CustomReminderStoring {
    public static let key = "display.reminders.custom"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var reminders: [CustomReminder] {
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([CustomReminder].self, from: data)
        else { return [] }
        return list
    }

    public func save(_ reminders: [CustomReminder]) {
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The seam to the system's local notifications for the custom reminders. The app target supplies the
/// system implementation; tests supply a fake.
public protocol CustomReminderScheduling: AnyObject, Sendable {
    /// Makes the pending custom requests exactly `reminders`: adds or replaces each, removes any other custom
    /// request. Throws when the system refuses a request.
    func replaceAll(with reminders: [CustomReminder]) async throws
    /// Removes the pending and delivered requests of these reminders. Synchronous so an erase can finish
    /// before it returns.
    func cancel(ids: [UUID])
}

/// Drives the list of custom reminders: adding, removing, switching on and off, changing the time, and
/// keeping the system's pending requests equal to the reminders that are on.
@MainActor
public final class CustomReminderController: ObservableObject {
    public static let maximumCount = 10
    public static let withdrawnMessage =
        "Notifications are turned off for this app. You can allow them in the iPhone Settings app."
    public static let refusedMessage =
        "The reminders could not be set. Check the notification settings for this app and try again."

    @Published public private(set) var reminders: [CustomReminder]
    @Published public private(set) var message: String?

    private let store: CustomReminderStoring
    private let permissions: ReminderScheduling
    private let scheduler: CustomReminderScheduling
    private let erasures: ReminderErasures
    private var tail: Task<Void, Never>?

    public init(
        store: CustomReminderStoring, permissions: ReminderScheduling, scheduler: CustomReminderScheduling,
        erasures: ReminderErasures = ReminderErasures()
    ) {
        self.store = store
        self.permissions = permissions
        self.scheduler = scheduler
        self.erasures = erasures
        self.reminders = store.reminders
    }

    public var canAdd: Bool { reminders.count < Self.maximumCount }

    public func add(_ kind: CustomReminderKind, at time: ReminderTime? = nil) async {
        guard canAdd else { return }
        let list = store.reminders + [CustomReminder(kind: kind, time: time ?? kind.defaultTime)]
        commit(list)
        await apply(askForPermission: true)
    }

    public func remove(id: UUID) async {
        commit(store.reminders.filter { $0.id != id })
        scheduler.cancel(ids: [id])
        await apply(askForPermission: false)
    }

    public func setOn(_ on: Bool, id: UUID) async {
        commit(store.reminders.map { var r = $0; if r.id == id { r.isOn = on }; return r })
        await apply(askForPermission: on)
    }

    public func setTime(_ time: ReminderTime, id: UUID) async {
        commit(store.reminders.map { var r = $0; if r.id == id { r.time = time }; return r })
        await apply(askForPermission: false)
    }

    /// Brings the system in line with the stored list. Never asks for permission. Called at launch and
    /// each time the app becomes active.
    public func sync() async {
        reminders = store.reminders
        await apply(askForPermission: false)
    }

    /// Re-reads the stored list after Erase all data cleared it.
    public func refreshFromStore() {
        erasures.record()
        reminders = store.reminders
        message = nil
    }

    private func commit(_ list: [CustomReminder]) {
        store.save(list)
        reminders = list
        message = nil
    }

    /// Queues one reconcile behind the last. Each reads the stored list when its turn comes, so the last
    /// thing a person did decides the outcome.
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
        let wanted = store.reminders.filter(\.isOn)
        guard !wanted.isEmpty else {
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
            switchAllOff(message: Self.withdrawnMessage)
            try? await scheduler.replaceAll(with: [])
            return
        }
        do {
            try await scheduler.replaceAll(with: wanted)
        } catch {
            if erased == erasures.count {
                switchAllOff(message: Self.refusedMessage)
                try? await scheduler.replaceAll(with: [])
            }
            return
        }
        if erased != erasures.count { scheduler.cancel(ids: wanted.map(\.id)) }
    }

    private func switchAllOff(message text: String) {
        let list = store.reminders.map { var r = $0; r.isOn = false; return r }
        store.save(list)
        reminders = list
        message = text
    }
}

/// Removes the custom reminders' pending requests and stored list when Erase all data runs.
public final class CustomReminderEraser: JournalErasing, @unchecked Sendable {
    private let store: CustomReminderStoring
    private let scheduler: CustomReminderScheduling
    private let erasures: ReminderErasures

    public init(store: CustomReminderStoring, scheduler: CustomReminderScheduling, erasures: ReminderErasures) {
        self.store = store
        self.scheduler = scheduler
        self.erasures = erasures
    }

    public func eraseAll() throws {
        erasures.record()
        let ids = store.reminders.map(\.id)
        store.clear()
        scheduler.cancel(ids: ids)
    }
}
