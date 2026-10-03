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
            units.append(contentsOf: Array(String(decoding: bytes[start..<index], as: UTF8.self).utf16))
        }
        throw DSLDAdapterError.malformedJSON(reason: "a string is not closed", offset: index)
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
        try readDigits(atLeastOne: true)
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
        return .number(text)
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