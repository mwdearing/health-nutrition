import Foundation

public enum BarcodeValidator: Sendable {
    /// Digits only, length 8 (EAN-8), 12 (UPC-A) or 13 (EAN-13), with a correct GS1 check digit.
    public static func isValid(_ barcode: String) -> Bool {
        let digits = barcode.unicodeScalars.map { Int($0.value) - 48 }
        guard barcode.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return false
        }
        guard [8, 12, 13].contains(digits.count) else {
            return false
        }
        var sum = 0
        for (offset, digit) in digits.dropLast().reversed().enumerated() {
            sum += digit * (offset % 2 == 0 ? 3 : 1)
        }
        let expected = (10 - sum % 10) % 10
        return expected == digits[digits.count - 1]
    }
}
