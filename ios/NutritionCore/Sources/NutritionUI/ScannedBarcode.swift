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
    public static func normalize(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        // Digits only, checked on scalars so no non-ASCII numeral sneaks in as a digit.
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        guard BarcodeShape.isValid(trimmed) else { return nil }
        return trimmed
    }
}
