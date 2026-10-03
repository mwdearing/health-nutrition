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

/// Where the last barcode lookup stands. A lookup only ever starts from an explicit user action,
/// so there is no state that changes while the user types.
public enum BarcodeLookupState: Sendable, Equatable {
    case idle
    case loading
    case found(LookedUpProduct)
    case notFound
    case invalidBarcode
    case rateLimited
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

@MainActor
public final class AddIntakeViewModel: ObservableObject {
    @Published public var name: String = ""
    @Published public var brand: String = ""
    @Published public var barcode: String = ""
    @Published public var amountText: String = ""
    @Published public var unit: MeasureUnit = .g
    @Published public var category: String = "food"
    @Published public var occurredAt: Date
    @Published public private(set) var nameError: String?
    @Published public private(set) var amountError: String?
    @Published public private(set) var saveError: String?
    @Published public private(set) var lookupState: BarcodeLookupState = .idle
    /// Nutrients prefilled from the last successful lookup; a nutrient the source did not give
    /// stays `.unknown` and is never stored as zero.
    @Published public private(set) var prefilledNutrients: [String: NutrientValue] = [:]
    @Published public private(set) var lookupBasis: BarcodeLookupBasis?

    public let timeZoneIdentifier: String
    public let units: [MeasureUnit] = UnitRegistry.all

    private let store: JournalStore
    private let makeID: () -> String
    private let lookup: BarcodeProductLookup?

    public var canLookUpBarcode: Bool { lookup != nil }

    public init(
        store: JournalStore,
        now: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
        lookup: BarcodeProductLookup? = nil
    ) {
        self.store = store
        self.occurredAt = now
        self.timeZoneIdentifier = timeZoneIdentifier
        self.makeID = makeID
        self.lookup = lookup
    }

    /// One line explaining the last lookup, or nil when there is nothing to say.
    public var lookupMessage: String? {
        switch lookupState {
        case .idle:
            return nil
        case .loading:
            return "Looking up the barcode…"
        case .found(let product):
            let basis = product.basis.label
            return "Filled in from the barcode (\(basis)). Check the amount, then save."
        case .notFound:
            return "No product found for that barcode. Fill in the details yourself."
        case .invalidBarcode:
            return "A barcode has 8, 12 or 13 digits. Nothing was looked up."
        case .rateLimited:
            return "Too many lookups just now. Try again in a minute."
        case .failed:
            return "The lookup did not finish. Try again in a moment."
        }
    }

    /// Looks up the barcode the user typed, after checking its shape. An invalid barcode is
    /// reported without calling the lookup at all.
    public func lookUpBarcode() async {
        guard let lookup else { return }
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BarcodeShape.isValid(trimmed) else {
            lookupState = .invalidBarcode
            return
        }
        barcode = trimmed
        lookupState = .loading
        let result = await lookup.lookUp(barcode: trimmed)
        switch result {
        case .found(let product):
            apply(product)
            lookupState = .found(product)
        case .notFound:
            lookupState = .notFound
        case .rateLimited:
            lookupState = .rateLimited
        case .failed(let reason):
            lookupState = .failed(reason)
        }
    }

    /// Fills the form from a looked-up product. The amount is left alone: the user confirms how much
    /// they actually ate.
    private func apply(_ product: LookedUpProduct) {
        if let productName = product.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !productName.isEmpty
        {
            name = productName
        }
        if let productBrand = product.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !productBrand.isEmpty
        {
            brand = productBrand
        }
        var filled: [String: NutrientValue] = [:]
        for key in LookedUpProduct.standardKeys {
            filled[key] = product.nutrients[key] ?? .unknown
        }
        prefilledNutrients = filled
        lookupBasis = product.basis
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
