import Foundation

/// Why a JSON document could not be read as an intake-context payload.
///
/// The contract rejects a malformed document while parsing it, before schema validation and before any digest
/// is computed, so every reason here is a parse-time failure and not a schema failure.
enum IntakeContextJSONError: Error, Equatable, Sendable {
    /// The document ends in the middle of a value.
    case unexpectedEnd
    /// A byte at `offset` does not start any JSON value.
    case unexpectedByte(offset: Int)
    /// An object has the same name twice, which the contract calls invalid input.
    case duplicateObjectName(String)
    /// An object member is missing, or a separator is missing.
    case malformedObject(offset: Int)
    /// An array is not closed, or an element is missing.
    case malformedArray(offset: Int)
    /// A string is not closed, or holds a control character that JSON requires to be escaped.
    case malformedString(offset: Int)
    /// An escape sequence is not one JSON allows.
    case invalidEscape(offset: Int)
    /// An escape names a code unit in the surrogate range without its partner.
    case unpairedSurrogate
    /// A number was written with a decimal point or an exponent. This contract has no floating-point numbers.
    case floatSpelling(offset: Int)
    /// A number is not a JSON integer, for example because it carries a leading zero.
    case malformedNumber(offset: Int)
    /// A member the caller needs is missing, or holds a value of another kind.
    case missingMember(String)
    /// A number does not fit the signed 64-bit range the receiver stores integers in.
    case integerOutOfRange(String)
}

/// A JSON value of an intake-context payload.
///
/// This contract has no binary floating point anywhere: every amount is a decimal string and only
/// `revision`, `projection_sequence` and `sync_version` are integers. An integer therefore keeps the literal
/// spelling the document used, so no value ever passes through a binary floating point type on its way to a
/// digest.
enum IntakeContextJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// A JSON integer, as its literal text: `-27`, `0`, `9223372036854775807`.
    case integer(String)
    case string(String)
    case array([IntakeContextJSONValue])
    case object([String: IntakeContextJSONValue])
}

extension IntakeContextJSONValue {
    var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    var arrayValue: [IntakeContextJSONValue]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }

    var objectValue: [String: IntakeContextJSONValue]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    /// A member of an object, or nil when this value is not an object or has no such member.
    func member(_ key: String) -> IntakeContextJSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// A member of an object as a string, or nil when it is missing or is not a string.
    func string(_ key: String) -> String? {
        member(key)?.stringValue
    }

    /// A member of an object as an array, or nil when it is missing or is not an array.
    func array(_ key: String) -> [IntakeContextJSONValue]? {
        member(key)?.arrayValue
    }

    /// A copy of an object with `key` set to `value`, which is how a caller builds the tampered variants a
    /// test compares against. The order of members is never part of the value: canonical JSON sorts keys.
    func settingMember(_ key: String, to value: IntakeContextJSONValue) -> IntakeContextJSONValue {
        guard case .object(var members) = self else { return self }
        members[key] = value
        return .object(members)
    }

    /// A copy of an object without `key`, which the digest scopes use to exclude fields.
    func removingMember(_ key: String) -> IntakeContextJSONValue {
        guard case .object(var members) = self else { return self }
        members.removeValue(forKey: key)
        return .object(members)
    }
}

extension IntakeContextJSONValue {
    /// The string a member must hold, or a failure naming the key that is missing or of the wrong type.
    func string(named key: String) throws -> String {
        guard let found = member(key), case .string(let text) = found else {
            throw IntakeContextJSONError.missingMember(key)
        }
        return text
    }

    /// The member a value must have, or a failure naming the key that is missing.
    func value(named key: String) throws -> IntakeContextJSONValue {
        guard let found = member(key) else {
            throw IntakeContextJSONError.missingMember(key)
        }
        return found
    }

    /// The array a member must hold, or a failure naming the key that is missing or of the wrong type.
    func array(named key: String) throws -> [IntakeContextJSONValue] {
        guard let found = member(key), case .array(let elements) = found else {
            throw IntakeContextJSONError.missingMember(key)
        }
        return elements
    }
}

/// A small recursive-descent JSON reader for intake-context payloads.
///
/// It exists because `JSONSerialization` hands numbers over in a binary floating point type, which would
/// rewrite the spelling of a number before a digest is taken, and because the contract rejects several
/// documents that `JSONSerialization` accepts: a duplicate object name, a number written with a decimal
/// point or an exponent, and an unpaired surrogate escape.
struct IntakeContextJSONReader {
    private static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index: Int = 0

    private init(_ data: Data) {
        self.bytes = Array(data)
    }

    /// Reads one whole document.
    static func read(_ data: Data) throws -> IntakeContextJSONValue {
        var reader = IntakeContextJSONReader(data)
        return try reader.readDocument()
    }

    private mutating func readDocument() throws -> IntakeContextJSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw IntakeContextJSONError.unexpectedEnd }
        let value = try readValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw IntakeContextJSONError.unexpectedByte(offset: index) }
        return value
    }

    private mutating func readValue(depth: Int) throws -> IntakeContextJSONValue {
        guard depth <= Self.maximumDepth else { throw IntakeContextJSONError.unexpectedByte(offset: index) }
        guard let byte = peek() else { throw IntakeContextJSONError.unexpectedEnd }
        switch byte {
        case UInt8(ascii: "{"): return try readObject(depth: depth)
        case UInt8(ascii: "["): return try readArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try readString())
        case UInt8(ascii: "t"): try read(literal: "true"); return .bool(true)
        case UInt8(ascii: "f"): try read(literal: "false"); return .bool(false)
        case UInt8(ascii: "n"): try read(literal: "null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try readInteger()
        default: throw IntakeContextJSONError.unexpectedByte(offset: index)
        }
    }

    private mutating func readObject(depth: Int) throws -> IntakeContextJSONValue {
        try read(literal: "{")
        var members: [String: IntakeContextJSONValue] = [:]
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                throw IntakeContextJSONError.malformedObject(offset: index)
            }
            let key = try readString()
            guard members[key] == nil else {
                throw IntakeContextJSONError.duplicateObjectName(key)
            }
            skipWhitespace()
            try read(literal: ":")
            skipWhitespace()
            members[key] = try readValue(depth: depth + 1)
            skipWhitespace()
            guard let byte = peek() else { throw IntakeContextJSONError.malformedObject(offset: index) }
            if byte == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            throw IntakeContextJSONError.malformedObject(offset: index)
        }
    }

    private mutating func readArray(depth: Int) throws -> IntakeContextJSONValue {
        try read(literal: "[")
        var elements: [IntakeContextJSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try readValue(depth: depth + 1))
            skipWhitespace()
            guard let byte = peek() else { throw IntakeContextJSONError.malformedArray(offset: index) }
            if byte == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            throw IntakeContextJSONError.malformedArray(offset: index)
        }
    }

    private mutating func readString() throws -> String {
        try read(literal: "\"")
        var text = ""
        var runStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                text += try literalRun(from: runStart, to: index)
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") {
                text += try literalRun(from: runStart, to: index)
                index += 1
                text += try readEscape()
                runStart = index
                continue
            }
            if byte < 0x20 {
                throw IntakeContextJSONError.malformedString(offset: index)
            }
            index += 1
        }
        throw IntakeContextJSONError.unexpectedEnd
    }

    /// Decodes a run of unescaped bytes. The bytes must be well-formed UTF-8, and a byte sequence that is not
    /// a scalar value (an overlong form, a surrogate or a value above U+10FFFF) is refused rather than
    /// replaced, because a replacement character would silently change hashed content.
    private func literalRun(from start: Int, to end: Int) throws -> String {
        guard end > start else { return "" }
        guard let text = String(bytes: bytes[start..<end], encoding: .utf8) else {
            throw IntakeContextJSONError.malformedString(offset: start)
        }
        guard !text.unicodeScalars.contains(where: { $0.value >= 0xD800 && $0.value <= 0xDFFF }) else {
            throw IntakeContextJSONError.unpairedSurrogate
        }
        return text
    }

    private mutating func readEscape() throws -> String {
        let offset = index
        guard let marker = peek() else { throw IntakeContextJSONError.unexpectedEnd }
        index += 1
        switch marker {
        case UInt8(ascii: "\""): return "\""
        case UInt8(ascii: "\\"): return "\\"
        case UInt8(ascii: "/"): return "/"
        case UInt8(ascii: "b"): return "\u{08}"
        case UInt8(ascii: "f"): return "\u{0C}"
        case UInt8(ascii: "n"): return "\u{0A}"
        case UInt8(ascii: "r"): return "\u{0D}"
        case UInt8(ascii: "t"): return "\u{09}"
        case UInt8(ascii: "u"): return try readUnicodeEscape()
        default: throw IntakeContextJSONError.invalidEscape(offset: offset)
        }
    }

    private mutating func readUnicodeEscape() throws -> String {
        let first = try readHexQuad()
        if first >= 0xD800, first <= 0xDBFF {
            // A high surrogate is only a value when its low surrogate follows as a second escape.
            guard index + 1 < bytes.count,
                  bytes[index] == UInt8(ascii: "\\"),
                  bytes[index + 1] == UInt8(ascii: "u") else {
                throw IntakeContextJSONError.unpairedSurrogate
            }
            index += 2
            let second = try readHexQuad()
            guard second >= 0xDC00, second <= 0xDFFF else {
                throw IntakeContextJSONError.unpairedSurrogate
            }
            let combined = 0x10000 + ((UInt32(first) - 0xD800) << 10) + (UInt32(second) - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else {
                throw IntakeContextJSONError.unpairedSurrogate
            }
            return String(scalar)
        }
        guard first < 0xD800 || first > 0xDFFF, let scalar = Unicode.Scalar(UInt32(first)) else {
            throw IntakeContextJSONError.unpairedSurrogate
        }
        return String(scalar)
    }

    private mutating func readHexQuad() throws -> UInt16 {
        let offset = index
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = peek(), let digit = Self.hexDigit(byte) else {
                throw IntakeContextJSONError.invalidEscape(offset: offset)
            }
            value = (value << 4) | UInt16(digit)
            index += 1
        }
        return value
    }

    private static func hexDigit(_ byte: UInt8) -> UInt16? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt16(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt16(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt16(byte - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }

    /// Reads a JSON number and keeps its literal text.
    ///
    /// Only the integer grammar is accepted. `2.0` and `2e0` are a schema failure in this contract, and
    /// taking the value as text would let a fractional amount into a payload the receiver refuses, so the
    /// document is rejected here instead.
    private mutating func readInteger() throws -> IntakeContextJSONValue {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        let digitsStart = index
        try readDigits(atLeastOne: true)
        // `digitsStart` is inside the document, because at least one digit was read.
        let first = bytes[digitsStart]
        // JSON allows a single leading zero and nothing more, so a zero followed by another integer digit is
        // not a number.
        if first == UInt8(ascii: "0"), index - digitsStart > 1 {
            throw IntakeContextJSONError.malformedNumber(offset: start)
        }
        if first != UInt8(ascii: "0") {
            try readDigits(atLeastOne: false)
        }
        if let byte = peek(), byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            throw IntakeContextJSONError.floatSpelling(offset: start)
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard Int64(text) != nil else { throw IntakeContextJSONError.integerOutOfRange(text) }
        return .integer(text)
    }

    private mutating func readDigits(atLeastOne: Bool) throws {
        let start = index
        while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            index += 1
        }
        if atLeastOne, index == start { throw IntakeContextJSONError.unexpectedEnd }
    }

    private mutating func read(literal: String) throws {
        for scalar in literal.unicodeScalars {
            guard let byte = peek(), byte == UInt8(ascii: scalar) else {
                throw IntakeContextJSONError.unexpectedByte(offset: index)
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
