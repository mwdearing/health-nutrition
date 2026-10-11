import Foundation

public struct CustomProductFieldError: Error, Sendable, Equatable {
    public enum Code: String, Sendable { case required, tooLong, tooManyFacts, duplicateKey, unsupportedKey, invalidAmount, unsupportedDimension, servingRequired, invalidBarcode }
    public let field: String
    public let code: Code
    public init(field: String, code: Code) { self.field = field; self.code = code }
}

public enum CustomProductValidation {
    /// Standard panel keys are case sensitive. Additional compounds use ingredient: keys.
    public static let standardDimensions: [String: UnitDimension] = [
        "energyKcal": .energy, "fat": .mass, "saturatedFat": .mass, "transFat": .mass,
        "cholesterol": .mass, "sodium": .mass, "carbohydrates": .mass, "fiber": .mass,
        "sugars": .mass, "addedSugars": .mass, "protein": .mass, "vitaminD": .mass,
        "calcium": .mass, "iron": .mass, "potassium": .mass,
    ]
    public static func validate(_ content: CustomProductContent) throws {
        try text(content.name, field: "name", limit: 120, required: true)
        if let barcode = content.barcode {
            let digits = barcode.unicodeScalars.map { Int($0.value) - 48 }
            guard barcode.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }), [8, 12, 13].contains(digits.count) else {
                throw CustomProductFieldError(field: "barcode", code: .invalidBarcode)
            }
            let sum = digits.dropLast().reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 3 : 1) }
            guard (10 - sum % 10) % 10 == digits.last else { throw CustomProductFieldError(field: "barcode", code: .invalidBarcode) }
        }
        if let brand = content.brand { try text(brand, field: "brand", limit: 80) }
        if let serving = content.serving {
            try amount(serving.quantity, field: "serving.quantity", positive: true)
            guard [.mass, .volume, .count].contains(serving.unit.dimension) else {
                throw CustomProductFieldError(field: "serving.unit", code: .unsupportedDimension)
            }
            if let value = serving.text { try text(value, field: "serving.text", limit: 80) }
        }
        guard content.facts.count <= 64 else { throw CustomProductFieldError(field: "facts", code: .tooManyFacts) }
        var keys = Set<String>()
        for (index, fact) in content.facts.enumerated() {
            let path = "facts[\(index)]"
            try text(fact.key, field: path + ".key", limit: 64, required: true)
            try text(fact.displayName, field: path + ".display_name", limit: 120, required: true)
            guard keys.insert(fact.key).inserted else { throw CustomProductFieldError(field: path + ".key", code: .duplicateKey) }
            guard standardDimensions[fact.key] != nil || (fact.key.hasPrefix("ingredient:") && fact.key.unicodeScalars.count > 11) else {
                throw CustomProductFieldError(field: path + ".key", code: .unsupportedKey)
            }
            let unit: MeasureUnit?
            switch fact.value {
            case .known(let value, let knownUnit):
                try amount(value, field: path + ".amount")
                if content.basis == .perServing && content.serving == nil { throw CustomProductFieldError(field: "serving", code: .servingRequired) }
                unit = knownUnit
            case .belowReportingThreshold(let thresholdUnit): unit = thresholdUnit
            case .unknown, .notApplicable: unit = nil
            }
            if let unit, let dimension = standardDimensions[fact.key], dimension != unit.dimension {
                throw CustomProductFieldError(field: path + ".unit", code: .unsupportedDimension)
            }
        }
    }
    private static func text(_ value: String, field: String, limit: Int, required: Bool = false) throws {
        if required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CustomProductFieldError(field: field, code: .required) }
        guard value.unicodeScalars.count <= limit else { throw CustomProductFieldError(field: field, code: .tooLong) }
    }
    private static func amount(_ value: Decimal, field: String, positive: Bool = false) throws {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 6, .plain)
        guard !value.isNaN, value >= 0, value <= 1_000_000_000, rounded == value, !positive || value > 0 else {
            throw CustomProductFieldError(field: field, code: .invalidAmount)
        }
    }
}
