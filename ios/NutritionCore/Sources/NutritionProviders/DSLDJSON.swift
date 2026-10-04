import Foundation

/// A JSON value that keeps every number as the exact text the source used.
///
/// `JSONSerialization` hands numbers over as `NSNumber`, which routes them through a binary
/// floating point type, so the decimal text of a quantity would be lost before the adapter sees it.
/// This value keeps the literal instead, and the adapter turns it into a `Decimal` from that text.
enum DSLDJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([DSLDJSON])
    case object([String: DSLDJSON])
}

extension DSLDJSON {
    var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    var numberText: String? {
        guard case .number(let text) = self else { return nil }
        return text
    }

    var arrayValue: [DSLDJSON]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }

    var objectValue: [String: DSLDJSON]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    /// A boolean flag. DSLD writes `offMarket` and `inSFB` as the integers 0 and 1, so both spellings
    /// are accepted; anything else is nil and the caller decides what to do.
    var flagValue: Bool? {
        switch self {
        case .bool(let flag):
            return flag
        case .number(let text):
            switch text {
            case "1": return true
            case "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// A small recursive-descent JSON reader. It reads the whole document, keeps number literals as text
/// and throws `DSLDAdapterError.malformedJSON` for anything that is not well-formed JSON.
struct DSLDJSONReader {
    private static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index: Int = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    static func read(_ data: Data) throws -> DSLDJSON {
        var reader = DSLDJSONReader(data)
        return try reader.readDocument()
    }

    private mutating func readDocument() throws -> DSLDJSON {
        skipWhitespace()
        guard index < bytes.count else {
            throw DSLDAdapterError.malformedJSON(reason: "the document is empty", offset: index)
        }
        let value = try readValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw DSLDAdapterError.malformedJSON(reason: "the document has trailing content", offset: index)
        }
        return value
    }

    private mutating func readValue(depth: Int) throws -> DSLDJSON {
        guard depth <= Self.maximumDepth else {
            throw DSLDAdapterError.malformedJSON(reason: "the document nests too deeply", offset: index)
        }
        guard index < bytes.count else {
            throw DSLDAdapterError.malformedJSON(reason: "the document ends unexpectedly", offset: index)
        }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            return try readObject(depth: depth)
        case UInt8(ascii: "["):
            return try readArray(depth: depth)
        case UInt8(ascii: "\""):
            return .string(try readString())
        case UInt8(ascii: "t"):
            try read(literal: "true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try read(literal: "false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try read(literal: "null")
            return .null
        default:
            return try readNumber()
        }
    }

    private mutating func readObject(depth: Int) throws -> DSLDJSON {
        try read(literal: "{")
        var members: [String: DSLDJSON] = [:]
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                throw DSLDAdapterError.malformedJSON(reason: "an object key is missing", offset: index)
            }
            let key = try readString()
            skipWhitespace()
            try read(literal: ":")
            skipWhitespace()
            let value = try readValue(depth: depth + 1)
            members[key] = value
            skipWhitespace()
            guard let byte = peek() else {
                throw DSLDAdapterError.malformedJSON(reason: "an object is not closed", offset: index)
            }
            if byte == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            throw DSLDAdapterError.malformedJSON(reason: "an object needs a , or a closing brace", offset: index)
        }
    }

    private mutating func readArray(depth: Int) throws -> DSLDJSON {
        try read(literal: "[")
        var elements: [DSLDJSON] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try readValue(depth: depth + 1))
            skipWhitespace()
            guard let byte = peek() else {
                throw DSLDAdapterError.malformedJSON(reason: "an array is not closed", offset: index)
            }
            if byte == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            throw DSLDAdapterError.malformedJSON(reason: "an array needs a , or a closing bracket", offset: index)
        }
    }

    private mutating func readString() throws -> String {
        try read(literal: "\"")
        var units: [UInt16] = []
        while let byte = peek() {
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: units, as: UTF16.self)
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard let escape = peek() else { break }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): units.append(0x22)
                case UInt8(ascii: "\\"): units.append(0x5C)
                case UInt8(ascii: "/"): units.append(0x2F)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"): units.append(try readUnicodeEscape())
                default:
                    throw DSLDAdapterError.malformedJSON(reason: "an escape sequence is not valid", offset: index)
                }
                continue
            }
            let start = index
            while let current = peek(), current != UInt8(ascii: "\""), current != UInt8(ascii: "\\") {
                index += 1
            }
            try appendLiteralRun(Array(bytes[start..<index]), documentStart: start, to: &units)
        }
        throw DSLDAdapterError.malformedJSON(reason: "a string is not closed", offset: index)
    }

    /// Appends a run of unescaped bytes to the string being read.
    ///
    /// `documentStart` is where the run begins in the whole document, so every position reported from
    /// here is an absolute byte offset and not one relative to the start of the run.
    ///
    /// The bytes must be well-formed UTF-8, and JSON requires every control character below U+0020 to
    /// be escaped, so a literal one is rejected instead of being carried into the value or replaced by
    /// a substitution character.
    private func appendLiteralRun(
        _ run: [UInt8],
        documentStart: Int,
        to units: inout [UInt16]
    ) throws {
        var position = 0
        while position < run.count {
            let start = position
            let scalar = try readScalar(from: run, at: &position, documentStart: documentStart)
            guard scalar.value >= 0x20 else {
                throw DSLDAdapterError.malformedJSON(
                    reason: "a control character in a string is not escaped",
                    offset: documentStart + start
                )
            }
            units.append(contentsOf: Array(String(scalar).utf16))
        }
    }

    /// Reads one UTF-8 scalar at `position`, rejecting overlong forms, surrogates and out-of-range values.
    /// Positions are reported as absolute offsets into the document.
    private func readScalar(
        from bytes: [UInt8],
        at position: inout Int,
        documentStart: Int
    ) throws -> Unicode.Scalar {
        let start = position
        let first = bytes[start]
        let length: Int
        switch first {
        case 0x00...0x7F: length = 1
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default:
            throw DSLDAdapterError.malformedJSON(
                reason: "a byte is not valid UTF-8",
                offset: documentStart + start
            )
        }
        guard start + length <= bytes.count else {
            throw DSLDAdapterError.malformedJSON(
                reason: "a UTF-8 sequence is truncated",
                offset: documentStart + start
            )
        }
        for offset in 1..<length {
            let continuation = bytes[start + offset]
            guard (continuation & 0xC0) == 0x80 else {
                throw DSLDAdapterError.malformedJSON(
                    reason: "a byte is not valid UTF-8",
                    offset: documentStart + start + offset
                )
            }
        }
        if length > 1 {
            let second = bytes[start + 1]
            if length == 3, (first == 0xE0 && second < 0xA0) || (first == 0xED && second > 0x9F) {
                throw DSLDAdapterError.malformedJSON(
                    reason: "a UTF-8 sequence is not a scalar value",
                    offset: documentStart + start
                )
            }
            if length == 4, (first == 0xF0 && second < 0x90) || (first == 0xF4 && second > 0x8F) {
                throw DSLDAdapterError.malformedJSON(
                    reason: "a UTF-8 sequence is not a scalar value",
                    offset: documentStart + start
                )
            }
        }
        let text = String(decoding: bytes[start..<(start + length)], as: UTF8.self)
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else {
            throw DSLDAdapterError.malformedJSON(
                reason: "a byte is not valid UTF-8",
                offset: documentStart + start
            )
        }
        position = start + length
        return scalar
    }

    private mutating func readUnicodeEscape() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = peek() else {
                throw DSLDAdapterError.malformedJSON(reason: "a unicode escape is truncated", offset: index)
            }
            let digit: UInt16
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                digit = UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                digit = UInt16(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                digit = UInt16(byte - UInt8(ascii: "A")) + 10
            default:
                throw DSLDAdapterError.malformedJSON(reason: "a unicode escape is not hexadecimal", offset: index)
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    /// Reads a JSON number and returns its literal text unchanged, so no binary floating point value
    /// ever exists for an amount. The grammar is checked here and the text is still handed to
    /// `Decimal(string:)` before the adapter trusts it.
    private mutating func readNumber() throws -> DSLDJSON {
        let start = index
        if peek() == UInt8(ascii: "-") {
            index += 1
        }
        try readIntegerPart()
        if peek() == UInt8(ascii: ".") {
            index += 1
            try readDigits(atLeastOne: true)
        }
        if let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            index += 1
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                index += 1
            }
            try readDigits(atLeastOne: true)
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) != nil else {
            throw DSLDAdapterError.malformedJSON(reason: "a number is not decimal", offset: start)
        }
        // `Decimal(string:)` succeeds after rounding when a literal carries more digits or a larger
        // exponent than a Decimal can hold, which would publish a rounded amount as if it were exact.
        // Such a literal is refused instead.
        if let reason = Self.exactnessProblem(in: text) {
            throw DSLDAdapterError.malformedJSON(reason: reason, offset: start)
        }
        return .number(text)
    }

    /// The number of significant digits a `Decimal` keeps, and the range of its adjusted exponent.
    private static let maximumSignificantDigits = 38
    private static let maximumAdjustedExponent = 127

    /// Returns why a valid JSON number cannot be represented exactly, or nil when it can.
    private static func exactnessProblem(in text: String) -> String? {
        let characters = Array(text)
        var index = 0
        if characters[index] == "-" {
            index += 1
        }
        var integerDigits = ""
        while index < characters.count, characters[index].isNumber {
            integerDigits.append(characters[index])
            index += 1
        }
        var fractionDigits = ""
        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isNumber {
                fractionDigits.append(characters[index])
                index += 1
            }
        }
        var literalExponent = 0
        if index < characters.count {
            index += 1
            var negative = false
            if index < characters.count, characters[index] == "-" {
                negative = true
                index += 1
            } else if index < characters.count, characters[index] == "+" {
                index += 1
            }
            var magnitude = 0
            while index < characters.count, characters[index].isNumber {
                if magnitude < 1_000 {
                    magnitude = magnitude * 10 + (Int(characters[index].asciiValue ?? 0) - 48)
                }
                index += 1
            }
            literalExponent = negative ? -magnitude : magnitude
        }

        let digits = integerDigits + fractionDigits
        let significant = digits.drop { $0 == "0" }
        guard !significant.isEmpty else { return nil }
        let leadingZeros = digits.count - significant.count
        if significant.count > Self.maximumSignificantDigits {
            return "a number has more significant digits than a decimal keeps exactly"
        }
        // The place value of the leading significant digit, moved by any exponent the literal carries.
        let adjustedExponent = (integerDigits.count - 1 - leadingZeros) + literalExponent
        if adjustedExponent > Self.maximumAdjustedExponent || adjustedExponent < -Self.maximumAdjustedExponent {
            return "a number is outside the range a decimal keeps exactly"
        }
        return nil
    }

    /// Reads the integer part of a number. JSON allows a single leading zero and nothing more, so a zero
/// followed by another integer digit is not a number.
private mutating func readIntegerPart() throws {
        guard let first = peek() else {
            throw DSLDAdapterError.malformedJSON(reason: "a number needs a digit", offset: index)
        }
        guard first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9") else {
            throw DSLDAdapterError.malformedJSON(reason: "a number needs a digit", offset: index)
        }
        index += 1
        guard first == UInt8(ascii: "0") else {
            try readDigits(atLeastOne: false)
            return
        }
        if let next = peek(), next >= UInt8(ascii: "0"), next <= UInt8(ascii: "9") {
            throw DSLDAdapterError.malformedJSON(reason: "a number must not have a leading zero", offset: index)
        }
    }

    private mutating func readDigits(atLeastOne: Bool) throws {
        let start = index
        while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            index += 1
        }
        if atLeastOne, index == start {
            throw DSLDAdapterError.malformedJSON(reason: "a number needs a digit", offset: index)
        }
    }

    private mutating func read(literal: String) throws {
        for scalar in literal.unicodeScalars {
            guard let byte = peek(), byte == UInt8(ascii: scalar) else {
                throw DSLDAdapterError.malformedJSON(reason: "expected \(literal)", offset: index)
            }
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while let byte = peek() {
            let isSpace = byte == UInt8(ascii: " ")
                || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r")
                || byte == UInt8(ascii: "\t")
            guard isSpace else { return }
            index += 1
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}