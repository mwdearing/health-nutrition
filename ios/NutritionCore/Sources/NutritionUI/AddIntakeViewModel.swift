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
    /// How long the source asked the caller to wait, when it said.
    case rateLimited(retryAfterSeconds: Int?)
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
    /// What one serving is, when the values are per serving.
    @Published public private(set) var serving: ServingDefinition?
    /// The attribution the source requires next to its values.
    @Published public private(set) var attribution: ProductAttribution?
    /// The product the prefilled values came from, written as a snapshot on save. Nil until a lookup
    /// succeeds, so an entry typed by hand stays exactly as it was, and nil again as soon as a later
    /// lookup finds nothing.
    @Published public private(set) var lookedUp: LookedUpProduct?
    /// The name and brand the last successful lookup filled in, so a later lookup can tell an edited
    /// field from one it filled itself.
    private var filledName: String?
    private var filledBrand: String?

    public let timeZoneIdentifier: String
    public let units: [MeasureUnit] = UnitRegistry.all

    private let store: JournalStore
    private let makeID: () -> String
    private let lookup: BarcodeProductLookup?
    /// Counts the lookups this form has started. A reply is applied only if it is still the newest
    /// one and the field still holds the barcode that was asked for.
    private var lookupGeneration = 0

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
            return "Filled in from the barcode (\(product.labelBasis)). Check the amount, then save."
        case .notFound:
            return "No product found for that barcode. Fill in the details yourself."
        case .invalidBarcode:
            return "A barcode has 8, 12 or 13 digits and a correct check digit. Nothing was looked up."
        case .rateLimited(let retryAfterSeconds):
            return Self.rateLimitMessage(retryAfterSeconds: retryAfterSeconds)
        case .failed:
            return "The lookup did not finish. Try again in a moment."
        }
    }

    /// Tells the user how long the source asked them to wait, rather than always one minute: a
    /// source that asked for longer would rate-limit an eager retry straight away.
    static func rateLimitMessage(retryAfterSeconds: Int?) -> String {
        guard let seconds = retryAfterSeconds, seconds > 0 else {
            return "Too many lookups just now. Try again in a minute."
        }
        if seconds < 60 {
            return "Too many lookups just now. Try again in \(seconds) seconds."
        }
        let minutes = (seconds + 59) / 60
        return "Too many lookups just now. Try again in about \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    /// Looks up the barcode the user typed, after checking its shape and check digit. An invalid
    /// barcode is reported without calling the lookup at all.
    ///
    /// A reply is applied only when it is still the newest lookup this form started and the field
    /// still holds the barcode that was asked for, so a slow reply can never fill the form with
    /// another product's values.
    public func lookUpBarcode() async {
        guard let lookup else { return }
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BarcodeShape.isValid(trimmed) else {
            lookupState = .invalidBarcode
            return
        }
        barcode = trimmed
        lookupGeneration += 1
        let generation = lookupGeneration
        lookupState = .loading
        let result = await lookup.lookUp(barcode: trimmed)
        guard generation == lookupGeneration, barcode == trimmed else { return }
        switch result {
        case .found(let product):
            // A source may answer with a different spelling of the same code (a UPC-A padded to 13
            // digits), but an answer for a genuinely different product must not fill this form.
            guard BarcodeShape.areEquivalent(product.barcode, trimmed) else { return }
            apply(product)
            lookupState = .found(product)
        case .notFound:
            invalidateLookup()
            lookupState = .notFound
        case .rateLimited(let retryAfterSeconds):
            invalidateLookup()
            lookupState = .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case .failed(let reason):
            invalidateLookup()
            lookupState = .failed(reason)
        }
    }

    /// Puts a scanned code in the field, dropping everything an earlier lookup put into the form.
    ///
    /// This is the path a lookup that finds nothing takes. A different code means every value on the
    /// form belongs to another product, so the scanned value goes through the same invalidation: the
    /// name, brand and nutrients the lookup filled in, the attribution and the product snapshot all
    /// go with it. Writing the field alone would keep them, and saving then would store the previous
    /// product's snapshot under the code now on screen. A reply still on its way is answered for the
    /// code it was asked about and is dropped by the generation check.
    public func setScannedBarcode(_ scanned: String) {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Scanning the code already on the field changes nothing, so the values that code filled in
        // stay where they are.
        guard trimmed != barcode.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        lookupGeneration += 1
        invalidateLookup()
        lookupState = .idle
        barcode = trimmed
    }

    /// Drops everything an earlier lookup put into the form, so a failed or empty lookup for a second
    /// barcode cannot leave the first product's values, or its snapshot, attached to the next entry.
    ///
    /// A field the user has since edited is left alone: only what the lookup itself filled in is
    /// cleared, so typing over a looked-up name and then getting a rate limit does not lose the typing.
    func invalidateLookup() {
        if let filledName, name == filledName { name = "" }
        if let filledBrand, brand == filledBrand { brand = "" }
        filledName = nil
        filledBrand = nil
        prefilledNutrients = [:]
        lookupBasis = nil
        serving = nil
        attribution = nil
        lookedUp = nil
    }

    /// Fills the form from a looked-up product. The amount is left alone: the user confirms how much
    /// they actually ate.
    private func apply(_ product: LookedUpProduct) {
        if let productName = product.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !productName.isEmpty
        {
            name = productName
            filledName = productName
        }
        if let productBrand = product.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !productBrand.isEmpty
        {
            brand = productBrand
            filledBrand = productBrand
        }
        var filled: [String: NutrientValue] = [:]
        for key in LookedUpProduct.standardKeys {
            filled[key] = product.nutrients[key] ?? .unknown
        }
        prefilledNutrients = filled
        lookupBasis = product.basis
        serving = product.basis == .perServing ? product.serving : nil
        attribution = product.attribution
        lookedUp = product
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
            try store.create(intake, components: [component], product: productSnapshot(), now: now)
            return true
        } catch {
            saveError = "Could not save the intake."
            return false
        }
    }

    /// The product snapshot to store with the entry, or nil for an entry typed by hand.
    ///
    /// Everything the snapshot carries is carried here, including the attribution source, the
    /// source's own version and the nutrient values the lookup gave, so a later reader can resolve
    /// the values for this entry without asking the source again. The values are the source's own,
    /// on the basis `labelBasis` names; a nutrient the source did not give stays `.unknown`.
    func productSnapshot() -> ProductDefinition? {
        guard let lookedUp else { return nil }
        // The name and brand are the ones in the form, not the source's: the user may have corrected
        // or cleared them, and the snapshot has to say what was actually recorded.
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return ProductDefinition(
            snapshotID: lookedUp.snapshotIdentity(name: trimmedName, brand: trimmedBrand),
            productID: lookedUp.barcode,
            name: trimmedName,
            brand: trimmedBrand,
            barcode: lookedUp.barcode,
            labelBasis: lookedUp.labelBasis,
            catalogOrigin: lookedUp.attribution?.source ?? "unknown",
            catalogVersion: lookedUp.version ?? "unknown",
            nutrients: lookedUp.nutrients
        )
    }

    /// Component ids are slugs: `[a-z0-9][a-z0-9._-]{0,63}`. A pure function, so it is callable
    /// from outside the main actor (the snapshot identity in `BarcodeLookup.swift` needs it).
    nonisolated static func slug(_ text: String) -> String {
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

extension String {
    /// nil when the string holds nothing but whitespace, so an empty brand is stored as absent
    /// rather than as an empty string.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
