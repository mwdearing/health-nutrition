import Foundation

/// Turns what the camera scanner read into the digits the barcode field accepts, or nothing.
///
/// This is deliberately a pure function in the UI package rather than camera code: the app target
/// owns VisionKit and hands over the raw payload, and this decides whether that payload is a
/// barcode the form would have accepted if it had been typed. A scan therefore cannot put a code in
/// the field that a typed one of the same digits would have been refused for, and nothing here
/// looks anything up: the lookup still runs only on the explicit Look up action.
public enum ScannedBarcode: Sendable {
    /// The lengths the barcode field accepts, as the scanner does.
    public static let acceptedLengths = BarcodeShape.acceptedLengths

    /// The payload with its whitespace trimmed, when it is a barcode this app looks up:
    /// digits only, 8 (EAN-8), 12 (UPC-A) or 13 (EAN-13) digits, with a valid GS1 check digit.
    /// Anything else is nil, and the caller keeps scanning rather than filling the field.
    ///
    /// A UPC-E payload is eight digits that pass this check as an EAN-8 while standing for a
    /// different number, so it goes through `expandUPCE(_:)` first. The caller knows which
    /// symbology the scanner read, and expands on that basis only.
    public static func normalize(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        // Digits only, checked on scalars so no non-ASCII numeral sneaks in as a digit.
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        guard BarcodeShape.isValid(trimmed) else { return nil }
        return trimmed
    }

    /// The GTIN-12 a UPC-E payload stands for, or nil when it is not a UPC-E payload.
    ///
    /// UPC-E is a compressed way of printing a UPC-A code: it carries a number system digit, six
    /// digits and a check digit, and leaves out the zeros that sit between the manufacturer and
    /// product digits in the expanded code. The check digit in the payload is the one of the
    /// *expanded* code, so it is checked there. Left compressed, the eight digits would pass the
    /// EAN-8 check and the lookup would ask about a number that was never on the package.
    public static func expandUPCE(_ payload: String) -> String? {
        // Digits only: a payload with anything else in it is not a barcode this can read.
        guard payload.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        let values = payload.unicodeScalars.map { Int($0.value) - 48 }
        guard values.count == 8 else { return nil }
        // UPC-E has two number systems, 0 and 1. Any other leading digit is a different symbology.
        guard values[0] == 0 || values[0] == 1 else { return nil }
        let (manufacturer, product) = expansion(for: values)
        let body = String(values[0]) + written(manufacturer) + written(product)
        guard checkDigit(for: body) == String(values[7]) else { return nil }
        return body + String(values[7])
    }

    /// Which digits the compressed code stands for. The last of the six says how the zeros were
    /// left out, so it is read first and is not itself one of the expanded digits.
    private static func expansion(for values: [Int]) -> (manufacturer: [Int], product: [Int]) {
        switch values[6] {
        case 0, 1, 2:
            // The last digit closes the manufacturer code; the product code lost its zeros.
            return (
                [values[1], values[2], values[6], 0, 0],
                [0, 0, values[3], values[4], values[5]]
            )
        case 3:
            return ([values[1], values[2], values[3], 0, 0], [0, 0, 0, values[4], values[5]])
        case 4:
            return ([values[1], values[2], values[3], values[4], 0], [0, 0, 0, 0, values[5]])
        default:
            // 5 to 9: only the product code lost zeros.
            return ([values[1], values[2], values[3], values[4], values[5]], [0, 0, 0, 0, values[6]])
        }
    }

    private static func written(_ values: [Int]) -> String {
        values.map { String($0) }.joined()
    }

    /// The GS1 check digit of a body of digits, with weight 3, 1, 3, 1... from the right.
    private static func checkDigit(for body: String) -> String {
        let values = body.unicodeScalars.map { Int($0.value) - 48 }
        var sum = 0
        for (offset, value) in values.reversed().enumerated() {
            sum += value * (offset.isMultiple(of: 2) ? 3 : 1)
        }
        return String((10 - sum % 10) % 10)
    }
}
