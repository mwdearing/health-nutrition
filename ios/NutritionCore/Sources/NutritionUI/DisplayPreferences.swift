import Foundation
import NutritionDomain

/// Which units the app offers and shows. It changes what a person is OFFERED and what is DISPLAYED;
/// it never changes what is stored, exported or delivered.
public enum UnitSystem: String, Sendable, CaseIterable, Equatable {
    case metric
    case usCustomary

    /// The name shown in the picker.
    public var label: String {
        switch self {
        case .metric: return "Metric (g, mL)"
        case .usCustomary: return "US (oz, fl oz)"
        }
    }
}

/// The two settings that decide how amounts are shown: which units are offered, and how much water
/// the quick-add button adds.
///
/// Deliberately small and general. It is about display only, so it holds no journal data and nothing
/// else in the app may store settings on top of it.
public protocol DisplayPreferences: AnyObject {
    var unitSystem: UnitSystem { get }
    /// The quick-water amount in milliliters, an exact decimal.
    var quickWaterMilliliters: Decimal { get }
}

/// Somewhere to write a display preference.
public protocol DisplayPreferencesWriting: DisplayPreferences {
    func setUnitSystem(_ system: UnitSystem)
    /// Ignores an amount that is not a positive decimal, so a bad value can never be stored.
    func setQuickWaterMilliliters(_ milliliters: Decimal)
    /// Puts both settings back to the defaults a person has before changing anything, removing what
    /// was stored rather than writing the defaults over it.
    ///
    /// Erase all data needs this: it promises to remove everything this app stores on the device, and
    /// a unit system and a glass size are stored values like any other.
    func resetToDefaults()
}

/// What the first run has already shown. Stored with the display preferences and erased with them.
public protocol FirstRunPreferences: AnyObject {
    var hasSeenWelcome: Bool { get }
    var isChecklistHidden: Bool { get }
    var hasReviewedUnits: Bool { get }
    func setHasSeenWelcome(_ seen: Bool)
    func setChecklistHidden(_ hidden: Bool)
    func setHasReviewedUnits(_ reviewed: Bool)
}

/// The defaults a person has before they change anything: metric, and a 250 mL glass.
public enum DisplayPreferenceDefaults {
    public static let unitSystem = UnitSystem.metric
    public static let quickWaterMilliliters = Decimal(250)
}

/// Holds the preferences in this app's own defaults domain, under namespaced keys.
///
/// Written synchronously rather than deferred, so a preference a person just changed is read back
/// the moment the next screen asks for it, and so a setting screen can never show a value the rest
/// of the app has not seen yet.
public final class UserDefaultsDisplayPreferences: DisplayPreferencesWriting, FirstRunPreferences, ReminderPreferences, GoalVisibilityPreferences {
    /// Every key this type owns carries this prefix, so a preference can never collide with another
    /// part of the app or with a value written by an OS framework into the same domain.
    public static let keyPrefix = "display."

    private let defaults: UserDefaults
    private let unitSystemKey: String
    private let quickWaterKey: String
    private let hasSeenWelcomeKey: String
    private let checklistHiddenKey: String
    private let hasReviewedUnitsKey: String
    /// The daily reminder's stored keys: "display.reminder.on" holds a bool and "display.reminder.time"
    /// holds the time as text, "HH:mm". Both carry the same prefix as every other key here.
    private let reminderOnKey = "display.reminder.on"
    private let reminderTimeKey = "display.reminder.time"
    /// The goals hidden from Today: a comma-joined, sorted list of nutrient keys, absent when none is.
    private let hiddenTodayGoalsKey = "display.goals.hiddenOnToday"

    /// `defaults` is a parameter so a test can pass a suite of its own rather than touching the
    /// standard domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.unitSystemKey = Self.keyPrefix + "unitSystem"
        self.quickWaterKey = Self.keyPrefix + "quickWaterMilliliters"
        self.hasSeenWelcomeKey = Self.keyPrefix + "hasSeenWelcome"
        self.checklistHiddenKey = Self.keyPrefix + "checklistHidden"
        self.hasReviewedUnitsKey = Self.keyPrefix + "hasReviewedUnits"
    }

    /// An absent key reads as false: nothing of the first run has been shown yet.
    public var hasSeenWelcome: Bool {
        defaults.bool(forKey: hasSeenWelcomeKey)
    }

    public var isChecklistHidden: Bool {
        defaults.bool(forKey: checklistHiddenKey)
    }

    public var hasReviewedUnits: Bool {
        defaults.bool(forKey: hasReviewedUnitsKey)
    }

    public var isReminderOn: Bool {
        defaults.bool(forKey: reminderOnKey)
    }

    /// The stored time when it reads as a clock time, 20:00 otherwise.
    public var reminderTime: ReminderTime {
        guard let text = defaults.string(forKey: reminderTimeKey),
              let time = ReminderTime(storedText: text)
        else { return ReminderTime.standard }
        return time
    }

    /// Absent or blank reads as none hidden. Empty entries are dropped, so a stray comma is harmless.
    public var hiddenTodayGoals: Set<String> {
        guard let text = defaults.string(forKey: hiddenTodayGoalsKey) else { return [] }
        return Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func setGoalShownOnToday(_ nutrient: String, shown: Bool) {
        var hidden = hiddenTodayGoals
        if shown { hidden.remove(nutrient) } else { hidden.insert(nutrient) }
        if hidden.isEmpty {
            defaults.removeObject(forKey: hiddenTodayGoalsKey)
        } else {
            defaults.set(hidden.sorted().joined(separator: ","), forKey: hiddenTodayGoalsKey)
        }
    }

    public func setReminderOn(_ on: Bool) {
        defaults.set(on, forKey: reminderOnKey)
    }

    public func setReminderTime(_ time: ReminderTime) {
        defaults.set(time.storedText, forKey: reminderTimeKey)
    }

    public func setHasSeenWelcome(_ seen: Bool) {
        defaults.set(seen, forKey: hasSeenWelcomeKey)
    }

    public func setChecklistHidden(_ hidden: Bool) {
        defaults.set(hidden, forKey: checklistHiddenKey)
    }

    public func setHasReviewedUnits(_ reviewed: Bool) {
        defaults.set(reviewed, forKey: hasReviewedUnitsKey)
    }

    /// An unreadable or absent value reads as the default, never as a crash and never as a guess:
    /// a domain written by an older build simply has no key yet.
    public var unitSystem: UnitSystem {
        guard let raw = defaults.string(forKey: unitSystemKey) else {
            return DisplayPreferenceDefaults.unitSystem
        }
        return UnitSystem(rawValue: raw) ?? DisplayPreferenceDefaults.unitSystem
    }

    /// The stored amount when it is a positive decimal, the default otherwise. A value written by an
    /// older build, or one that cannot be read back as a number, offers the default rather than an
    /// amount the quick-add button could not use.
    public var quickWaterMilliliters: Decimal {
        guard let raw = defaults.string(forKey: quickWaterKey),
              let value = Decimal(string: raw, locale: AmountParser.locale), !value.isNaN, value > 0
        else {
            return DisplayPreferenceDefaults.quickWaterMilliliters
        }
        return value
    }

    public func setUnitSystem(_ system: UnitSystem) {
        defaults.set(system.rawValue, forKey: unitSystemKey)
    }

    public func setQuickWaterMilliliters(_ milliliters: Decimal) {
        guard !milliliters.isNaN, milliliters > 0 else { return }
        defaults.set(
            NSDecimalNumber(decimal: milliliters).stringValue, forKey: quickWaterKey)
    }

    /// Removes every key this type owns, so nothing of this app's remains in the domain. The getters
    /// already read an absent key as the default, so removing is enough and nothing is written back.
    public func resetToDefaults() {
        defaults.removeObject(forKey: unitSystemKey)
        defaults.removeObject(forKey: quickWaterKey)
        defaults.removeObject(forKey: hasSeenWelcomeKey)
        defaults.removeObject(forKey: checklistHiddenKey)
        defaults.removeObject(forKey: hasReviewedUnitsKey)
        defaults.removeObject(forKey: reminderOnKey)
        defaults.removeObject(forKey: reminderTimeKey)
        defaults.removeObject(forKey: hiddenTodayGoalsKey)
    }
}

/// The preferences held in memory. For tests and for previews, so neither needs a defaults domain.
public final class InMemoryDisplayPreferences: DisplayPreferencesWriting, FirstRunPreferences, ReminderPreferences, GoalVisibilityPreferences {
    public var unitSystem: UnitSystem
    public var quickWaterMilliliters: Decimal
    public private(set) var hasSeenWelcome = false
    public private(set) var isChecklistHidden = false
    public private(set) var hasReviewedUnits = false
    public private(set) var isReminderOn = false
    public private(set) var reminderTime = ReminderTime.standard
    public private(set) var hiddenTodayGoals: Set<String> = []

    public func setGoalShownOnToday(_ nutrient: String, shown: Bool) {
        if shown { hiddenTodayGoals.remove(nutrient) } else { hiddenTodayGoals.insert(nutrient) }
    }

    public init(
        unitSystem: UnitSystem = DisplayPreferenceDefaults.unitSystem,
        quickWaterMilliliters: Decimal = DisplayPreferenceDefaults.quickWaterMilliliters
    ) {
        self.unitSystem = unitSystem
        self.quickWaterMilliliters = quickWaterMilliliters
    }

    public func setUnitSystem(_ system: UnitSystem) {
        unitSystem = system
    }

    public func setQuickWaterMilliliters(_ milliliters: Decimal) {
        guard !milliliters.isNaN, milliliters > 0 else { return }
        quickWaterMilliliters = milliliters
    }

    public func setReminderOn(_ on: Bool) {
        isReminderOn = on
    }

    public func setReminderTime(_ time: ReminderTime) {
        reminderTime = time
    }

    public func setHasSeenWelcome(_ seen: Bool) {
        hasSeenWelcome = seen
    }

    public func setChecklistHidden(_ hidden: Bool) {
        isChecklistHidden = hidden
    }

    public func setHasReviewedUnits(_ reviewed: Bool) {
        hasReviewedUnits = reviewed
    }

    public func resetToDefaults() {
        unitSystem = DisplayPreferenceDefaults.unitSystem
        quickWaterMilliliters = DisplayPreferenceDefaults.quickWaterMilliliters
        hasSeenWelcome = false
        isChecklistHidden = false
        hasReviewedUnits = false
        isReminderOn = false
        reminderTime = ReminderTime.standard
        hiddenTodayGoals = []
    }
}
