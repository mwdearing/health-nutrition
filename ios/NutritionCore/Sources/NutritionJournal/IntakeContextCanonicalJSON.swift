import Foundation

/// The canonical JSON form every intake-context digest is taken over.
///
/// Two implementations in any language must produce the same bytes for the same value, because the receiver
/// recomputes each digest from the operation it received and rejects a mismatch. The rules, from the
/// contract's "Canonical JSON" section:
///
/// 1. Object keys are sorted by Unicode code point at every depth, and are never renamed.
/// 2. There is no whitespace: `,` between members and `:` between a key and its value.
/// 3. Strings are UTF-8 with no ASCII escaping. Only `\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t` and `\u00xx`
///    with lowercase hex for any other control character below U+0020. Everything else, including non-ASCII
///    text, U+007F and U+2028, is written as its raw UTF-8 bytes.
/// 4. There are no floating-point numbers anywhere. Integers are plain decimal digits with a leading `-` only
///    when negative, no leading zeros, no `+`, and no fraction or exponent.
/// 5. Arrays keep their order, so order inside `facts` and `members` is part of the content.
/// 6. `true`, `false` and `null` are lowercase.
enum IntakeContextCanonicalJSON {
    /// The canonical bytes of a value.
    static func encode(_ value: IntakeContextJSONValue) -> Data {
        var bytes: [UInt8] = []
        append(value, to: &bytes)
        return Data(bytes)
    }

    /// Whether `lhs` sorts before `rhs` by Unicode code point.
    ///
    /// Swift's own `String` comparison is not code point order: it compares canonical equivalents, so a
    /// combining sequence and its precomposed character compare as equal and two keys that differ only in
    /// composition would come out in an order the receiver never produces. Code points are compared one by one
    /// instead, which is also UTF-8 byte order.
    static func precedesByCodePoint(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.unicodeScalars.makeIterator()
        var right = rhs.unicodeScalars.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let first?, let second?):
                if first.value != second.value { return first.value < second.value }
            }
        }
    }

    private static func append(_ value: IntakeContextJSONValue, to bytes: inout [UInt8]) {
        switch value {
        case .null:
            bytes.append(contentsOf: Array("null".utf8))
        case .bool(let flag):
            bytes.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .integer(let text):
            // The literal text the document used. A decimal amount is a string in this contract, so the only
            // numbers reaching here are integers, already checked against the signed 64-bit range.
            bytes.append(contentsOf: Array(text.utf8))
        case .string(let text):
            appendQuoted(text, to: &bytes)
        case .array(let elements):
            bytes.append(UInt8(ascii: "["))
            for (position, element) in elements.enumerated() {
                if position > 0 { bytes.append(UInt8(ascii: ",")) }
                append(element, to: &bytes)
            }
            bytes.append(UInt8(ascii: "]"))
        case .object(let members):
            bytes.append(UInt8(ascii: "{"))
            let keys = members.keys.sorted(by: IntakeContextCanonicalJSON.precedesByCodePoint)
            for (position, key) in keys.enumerated() {
                if position > 0 { bytes.append(UInt8(ascii: ",")) }
                appendQuoted(key, to: &bytes)
                bytes.append(UInt8(ascii: ":"))
                append(members[key]!, to: &bytes)
            }
            bytes.append(UInt8(ascii: "}"))
        }
    }

    private static func appendQuoted(_ text: String, to bytes: inout [UInt8]) {
        bytes.append(UInt8(ascii: "\""))
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: bytes.append(contentsOf: Array("\\\"".utf8))
            case 0x5C: bytes.append(contentsOf: Array("\\\\".utf8))
            case 0x08: bytes.append(contentsOf: Array("\\b".utf8))
            case 0x0C: bytes.append(contentsOf: Array("\\f".utf8))
            case 0x0A: bytes.append(contentsOf: Array("\\n".utf8))
            case 0x0D: bytes.append(contentsOf: Array("\\r".utf8))
            case 0x09: bytes.append(contentsOf: Array("\\t".utf8))
            case 0x00...0x1F:
                bytes.append(contentsOf: Array("\\u00".utf8))
                bytes.append(contentsOf: Array(hexByte(scalar.value).utf8))
            default:
                bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }

    /// The two lowercase hex digits of a byte, so a control character is written as `\u00xx`.
    private static func hexByte(_ value: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        let high = Int((value >> 4) & 0xF)
        let low = Int(value & 0xF)
        return String(digits[high]) + String(digits[low])
    }
}
