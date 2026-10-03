import Foundation
import NutritionDomain
import NutritionJournal

/// Parses amount text with a fixed POSIX format: digits with at most one ".", no locale, no sign.
public enum AmountParser {
    public static let locale = Locale(identifier: "en_US_POSIX")

    /// Returns a positive Decimal, or nil for anything else.
    public static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var dots = 0
        var digits = 0
        for character in trimmed {
            if character == "." {
                dots += 1
            } else if character.isASCII, character.isNumber {
                digits += 1
            } else {
                return nil
            }
        }
        guard dots <= 1, digits > 0 else { return nil }
        guard let value = Decimal(string: trimmed, locale: locale), !value.isNaN, value > 0 else { return nil }
        return value
    }
}

@MainActor
public final class AddIntakeViewModel: ObservableObject {
    @Published public var name: String = ""
    @Published public var amountText: String = ""
    @Published public var unit: MeasureUnit = .g
    @Published public var category: String = "food"
    @Published public var occurredAt: Date
    @Published public private(set) var nameError: String?
    @Published public private(set) var amountError: String?
    @Published public private(set) var saveError: String?

    public let timeZoneIdentifier: String
    public let units: [MeasureUnit] = UnitRegistry.all

    private let store: JournalStore
    private let makeID: () -> String

    public init(
        store: JournalStore,
        now: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.occurredAt = now
        self.timeZoneIdentifier = timeZoneIdentifier
        self.makeID = makeID
    }

    /// Validates and writes one intake. Invalid input sets field errors and writes nothing.
    @discardableResult
    public func save(now: Date) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nameError = trimmedName.isEmpty ? "Enter a name." : nil
        let amount = AmountParser.parse(amountText)
        amountError = amount == nil ? "Enter an amount greater than zero, using digits and a point." : nil
        saveError = nil
        guard nameError == nil, let amount else { return false }

        let intake = Intake(
            id: makeID(), category: category, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
        let component = IntakeComponent(
            componentID: Self.slug(trimmedName), name: trimmedName, amount: amount, unit: unit)
        do {
            try store.create(intake, components: [component], product: nil, now: now)
            return true
        } catch {
            saveError = "Could not save the intake."
            return false
        }
    }

    /// Component ids are slugs: `[a-z0-9][a-z0-9._-]{0,63}`.
    static func slug(_ text: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in text.lowercased().unicodeScalars {
            let isAllowed = scalar.isASCII && (("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)))
            if isAllowed {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty { return "item" }
        return String(result.prefix(64))
    }
}
