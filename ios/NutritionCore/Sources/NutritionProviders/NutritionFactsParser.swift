import Foundation
import NutritionDomain

/// Reads the text lines of a US Nutrition Facts panel into `ParsedNutritionFacts`.
///
/// The parser is the pure core of label capture: text lines in, a panel out. It reads no image and
/// sends nothing anywhere; the capture session that produces the lines does that in a later task.
///
/// What it reads: the serving size, the servings per container, and one row per nutrient it recognises.
/// Amounts are read exactly with `Decimal(string:)` and never pass through a binary floating point type.
/// What it never guesses:
///
/// - A nutrient the panel does not state is `.unknown`, never zero. A label that says nothing about
///   potassium does not say that potassium is zero.
/// - The % Daily Value column is never read as an amount. Only a number that stands on its own, next to
///   a nutrient name and its unit, becomes a value.
/// - "Less than 1g" and "<1g" are bounds, so they become `.belowReportingThreshold`, never a known 1 g.
/// - A unit the registry does not carry is not resolved into one that it does, and a nutrient printed in
///   a unit it does not usually carry keeps its own unit instead of being rewritten into the usual one.
/// - Every correction the parser makes to printed text is recorded, so the confirmation screen can ask
///   the user about the value instead of saving it on the parser's word.
public enum NutritionFactsParser {
    /// One recognised panel row: the journal key it fills, the names a label may print for it, and the
    /// unit the row usually carries. Aliases match as whole words and the earliest match on a line wins,
    /// so "Total Fat" beats the "fat" inside it and "Total Sugars" beats the "sugars" inside it.
    private struct PanelRow: Sendable {
        let key: NutritionFactKey
        let aliases: [String]
        let usualUnit: MeasureUnit

        init(key: NutritionFactKey, aliases: [String], usualUnit: MeasureUnit) {
            self.key = key
            self.aliases = aliases
            self.usualUnit = usualUnit
        }
    }

    private static let rows: [PanelRow] = [
        PanelRow(key: .calories, aliases: ["calories", "energy"], usualUnit: .kcal),
        PanelRow(key: .fat, aliases: ["total fat", "fat"], usualUnit: .g),
        PanelRow(key: .saturatedFat, aliases: ["saturated fat"], usualUnit: .g),
        PanelRow(key: .transFat, aliases: ["trans fat"], usualUnit: .g),
        PanelRow(key: .cholesterol, aliases: ["cholesterol"], usualUnit: .mg),
        PanelRow(key: .sodium, aliases: ["sodium"], usualUnit: .mg),
        PanelRow(key: .carbohydrates, aliases: ["total carbohydrate", "carbohydrate", "carbs"], usualUnit: .g),
        PanelRow(key: .fiber, aliases: ["dietary fiber", "fibre", "fiber"], usualUnit: .g),
        PanelRow(key: .sugars, aliases: ["total sugars", "sugars"], usualUnit: .g),
        PanelRow(key: .addedSugars, aliases: ["added sugars"], usualUnit: .g),
        PanelRow(key: .protein, aliases: ["protein"], usualUnit: .g),
        PanelRow(key: .vitaminD, aliases: ["vitamin d", "vit d"], usualUnit: .mcg),
        PanelRow(key: .calcium, aliases: ["calcium"], usualUnit: .mg),
        PanelRow(key: .iron, aliases: ["iron"], usualUnit: .mg),
        PanelRow(key: .potassium, aliases: ["potassium"], usualUnit: .mg),
    ]

    /// The pattern of the % Daily Value column: a number in front of a percent sign. It is matched only
    /// so the parser can step over that column, because a number in this column is never an amount.
    ///
    /// The pattern is built where it is used rather than kept in a static property, because a `Regex`
    /// value is not `Sendable` and this type is used from any context.
    private static func percentDailyValue() -> Regex<Substring> {
        #/(?:\d+(?:\.\d+)?)\s*%/#
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Reads the lines of one panel. A line that states nothing the parser recognises is ignored, so
    /// surrounding print, a brand line or a footnote cannot turn into a value.
    public static func parse(lines: [String]) -> ParsedNutritionFacts {
        let cleaned = lines.map { cleanLine($0) }
        var size: ParsedServingSize?
        var perContainer: Decimal?
        var amounts: [String: NutrientValue] = [:]
        var reviews: [String: ParsedValueReview] = [:]

        var index = 0
        while index < cleaned.count {
            let line = cleaned[index]
            if let read = servingSize(in: line) {
                if size == nil { size = read }
                index += 1
                continue
            }
            if let count = servingsPerContainer(in: line) {
                if perContainer == nil { perContainer = count }
                index += 1
                continue
            }
            let following = index + 1 < cleaned.count ? cleaned[index + 1] : nil
            let usedNext = absorbRows(in: line, following: following, amounts: &amounts, reviews: &reviews)
            index += usedNext ? 2 : 1
        }

        return ParsedNutritionFacts(
            servingSize: size,
            servingsPerContainer: perContainer,
            nutrients: amounts,
            valuesNeedingReview: reviews
        )
    }

    // MARK: - Serving size and servings per container

    /// The serving size a line states, read after the words "serving size" and past any colon.
    private static func servingSize(in line: String) -> ParsedServingSize? {
        let lower = line.lowercased()
        guard let marker = lower.range(of: "serving size") else { return nil }
        var text = after(marker, in: line, lowercased: lower)
        if let colon = text.firstIndex(of: ":") {
            text = String(text[text.index(after: colon)...])
        }
        text = trimmed(text)
        guard !text.isEmpty else { return nil }
        let measure = servingMeasure(in: text)
        return ParsedServingSize(text: text, quantity: measure.quantity, review: measure.review)
    }

    /// The count a "servings per container" line states. The number may stand before the phrase
    /// ("About 6 servings per container") or after it ("Servings Per Container: 12").
    private static func servingsPerContainer(in line: String) -> Decimal? {
        let lower = line.lowercased()
        guard let marker = lower.range(of: "servings per container") else { return nil }
        var tail = after(marker, in: line, lowercased: lower)
        if let colon = tail.firstIndex(of: ":") {
            tail = String(tail[tail.index(after: colon)...])
        }
        if let count = firstDecimal(in: tail) { return count }
        let offset = lower.distance(from: lower.startIndex, to: marker.lowerBound)
        let headEnd = line.index(line.startIndex, offsetBy: offset, limitedBy: line.endIndex) ?? line.endIndex
        return firstDecimal(in: String(line[..<headEnd]))
    }

    /// The measure a serving size states: the one in parentheses when the label writes one, otherwise the
    /// first amount the text carries. A household word on its own stays no amount at all.
    ///
    /// The corrections the measure needed come back with it, because the serving size scales every
    /// nutrient saved from this panel.
    private static func servingMeasure(in text: String) -> (quantity: Quantity?, review: ParsedValueReview?) {
        if let open = text.firstIndex(of: "("),
           let close = text[open...].firstIndex(of: ")"),
           close > open
        {
            let inner = String(text[text.index(after: open)..<close])
            if let scan = scanAmount(in: inner), let unit = scan.unit, !scan.isBound {
                return measure(from: scan, unit: unit)
            }
        }
        if let scan = scanAmount(in: text), let unit = scan.unit, !scan.isBound {
            return measure(from: scan, unit: unit)
        }
        return (nil, nil)
    }

    /// The measure one scan read, with the reasons it needed a correction, or none when it was read
    /// exactly as printed.
    private static func measure(
        from scan: ScannedAmount,
        unit: MeasureUnit
    ) -> (quantity: Quantity, review: ParsedValueReview?) {
        let review = scan.reasons.isEmpty ? nil : ParsedValueReview(reasons: scan.reasons)
        return (Quantity(value: scan.amount, unit: unit), review)
    }

    // MARK: - Nutrient rows

    /// Reads every nutrient row a line carries, because a capture can flatten the panel onto one line.
    ///
    /// Returns whether the next line was consumed, which happens when a row states its name on one line
    /// and its amount on the next.
    private static func absorbRows(
        in line: String,
        following nextLine: String?,
        amounts: inout [String: NutrientValue],
        reviews: inout [String: ParsedValueReview]
    ) -> Bool {
        var cursor = line
        var usedNextLine = false

        while let match = firstRow(in: cursor) {
            let row = match.row
            if isBreakdownLine(cursor, context: rowContext(around: match, in: cursor), for: row) { break }
            let remainder = trimmed(String(cursor[match.end...]))
            if let scan = scanAmount(in: remainder), statesAmount(scan, for: row) {
                record(scan, for: row, amounts: &amounts, reviews: &reviews)
                cursor = scan.remaining
                continue
            }
            // A panel states some rows with the amount in front of the name: "Includes 5g Added Sugars".
            // It states its unit like any other amount, and a number in front of a percent sign belongs
            // to the Daily Value column rather than to this row.
            if let scan = leadingAmount(before: String(cursor[..<match.nameStart])), statesAmount(scan, for: row) {
                record(scan, for: row, amounts: &amounts, reviews: &reviews)
                break
            }
            if remainder.isEmpty, let nextLine, let scan = scanAmount(in: trimmed(nextLine)),
               statesAmount(scan, for: row)
            {
                // A name and its amount can also land on separate lines when the panel was read column by
                // column.
                record(scan, for: row, amounts: &amounts, reviews: &reviews)
                usedNextLine = true
                break
            }
            // The row states no amount the parser can read, so it keeps none. The rest of the line is
            // still read: one damaged row does not cost the rows that follow it. The cursor is always
            // shorter here, because this row's own name is behind us.
            let after = String(cursor[match.end...])
            if let next = firstRow(in: after) {
                cursor = String(after[next.nameStart...])
                continue
            }
            break
        }
        return usedNextLine
    }

    /// The text that qualifies a row: what stands around its name, up to the nutrient names on either
    /// side of it. A word further along a flattened line belongs to its own row, not to this one.
    private static func rowContext(around match: RowMatch, in cursor: String) -> String {
        let head = String(cursor[..<match.nameStart])
        let before = firstRow(in: head).map { String(head[$0.end...]) } ?? head
        let tail = String(cursor[match.end...])
        let after = firstRow(in: tail).map { String(tail[..<$0.nameStart]) } ?? tail
        return before + " " + after
    }

    /// Whether a scanned number is the row's amount rather than a number the row did not print a unit for.
    ///
    /// The Calories row is the only row of a panel that prints no unit of its own, so a bare number is
    /// read there and nowhere else. Everywhere else a number without a unit is left alone: it is either a
    /// % Daily Value column or a row whose unit the capture lost, and neither is guessed at.
    private static func statesAmount(_ scan: ScannedAmount, for row: PanelRow) -> Bool {
        scan.unit != nil || row.usualUnit == .kcal
    }

    /// An amount written in front of its nutrient name. Only the words and the number immediately in
    /// front of the name are read, so an earlier row's amount is never pulled onto this row. A token in
    /// front of a percent sign is a Daily Value of another row and is never an amount here.
    private static func leadingAmount(before text: String) -> ScannedAmount? {
        let tokens = text.split(separator: " ")
        for count in [2, 1] {
            let tail = tokens.suffix(count).joined(separator: " ")
            guard !tail.contains("%") else { continue }
            if let scan = scanAmount(in: tail) { return scan }
        }
        return nil
    }

    /// A nutrient name found on a line, with the span the name occupies.
    private struct RowMatch {
        let row: PanelRow
        let nameStart: String.Index
        let end: String.Index
    }

    /// The first nutrient name a line carries, with the span just around the name.
    private static func firstRow(in line: String) -> RowMatch? {
        let lower = line.lowercased()
        var best: (start: Int, length: Int, row: PanelRow)?

        for row in rows {
            for alias in row.aliases {
                guard let found = lower.range(of: alias), isWholeWord(found, in: lower) else { continue }
                let start = lower.distance(from: lower.startIndex, to: found.lowerBound)
                let length = alias.count
                if let current = best {
                    // Keep the earliest name on the line; at the same start keep the longer one, so
                    // "Saturated Fat" wins over the "fat" inside it and "Added Sugars" over "sugars".
                    if start > current.start || (start == current.start && length <= current.length) { continue }
                }
                best = (start, length, row)
            }
        }

        guard let best else { return nil }
        let nameStart = line.index(line.startIndex, offsetBy: best.start)
        let end = line.index(nameStart, offsetBy: best.length)
        return RowMatch(row: best.row, nameStart: nameStart, end: end)
    }

    /// Whether a line names a nutrient without stating its own amount.
    ///
    /// - "Calories from Fat" is the fat inside the calories, not the calories themselves.
    /// - "Saturated Fat ... Includes 2g Trans Fat" states the trans fat inside the saturated fat, which
    ///   is a breakdown of another row and not a row of its own. Only an `Includes` in the text that
    ///   qualifies this occurrence marks it: on a flattened panel the `Includes` of a later added-sugars
    ///   row belongs to that row and must not reject the trans fat in front of it.
    /// - A Daily Value heading names the column and no amount.
    private static func isBreakdownLine(_ line: String, context: String, for row: PanelRow) -> Bool {
        let lower = line.lowercased()
        if lower.contains("daily value") { return true }
        if row.key == .calories, lower.contains("from fat") { return true }
        if row.key == .transFat, context.lowercased().contains("includes") { return true }
        return false
    }

    /// Stores the first amount read for a nutrient. A nutrient the panel states twice keeps the first
    /// row that carried an amount.
    private static func record(
        _ scan: ScannedAmount,
        for row: PanelRow,
        amounts: inout [String: NutrientValue],
        reviews: inout [String: ParsedValueReview]
    ) {
        let key = row.key.rawValue
        guard amounts[key] == nil else { return }

        var reasons = scan.reasons
        if let printed = scan.unit, printed != row.usualUnit {
            // The amount is kept exactly as printed. A nutrient in a unit it does not usually carry is
            // highlighted for review instead of being rewritten into the unit it usually carries.
            reasons.insert(.unexpectedUnit)
        }
        let unit = scan.unit ?? row.usualUnit
        amounts[key] = scan.isBound ? .belowReportingThreshold(unit) : .known(scan.amount, unit)
        if !reasons.isEmpty {
            reviews[key] = ParsedValueReview(reasons: reasons)
        }
    }

    // MARK: - Amounts

    /// One amount as the text states it, with the text that follows it once the amount and the % Daily
    /// Value column have been stepped over.
    private struct ScannedAmount {
        let amount: Decimal
        let unit: MeasureUnit?
        let isBound: Bool
        let reasons: Set<ParsedValueReview.Reason>
        let remaining: String
    }

    /// Reads the amount at the front of `text`.
    ///
    /// Nothing else becomes an amount: the number has to stand at the front of the text, and the text has
    /// to say a unit the registry carries. A unit the registry does not carry is never resolved into one
    /// it does carry, so such a row keeps no amount rather than an amount in a unit nobody printed.
    private static func scanAmount(in rawText: String) -> ScannedAmount? {
        let text = trimmed(rawText)
        guard !text.isEmpty else { return nil }
        let characters = Array(text)

        // A bound: "less than 1g", "< 1g", "under 2mg". A bound states a limit, never an amount.
        if characters[0] == "<" {
            return bound(in: characters, from: 1)
        }
        let prefix = boundPrefix(in: characters, from: 0)
        if prefix.isBound {
            return bound(in: characters, from: prefix.consumed)
        }

        // The number itself. A letter O that touches a digit, or that is the whole number with a unit
        // after it, is the zero OCR read as a letter. A comma is read as part of the token and is only
        // kept when it groups thousands, so "1,000" is one thousand and not one.
        var digits = ""
        var index = 0
        var reasons: Set<ParsedValueReview.Reason> = []
        while index < characters.count {
            let character = characters[index]
            if isDigit(character) {
                digits.append(character)
                index += 1
                continue
            }
            if character == ".", !digits.isEmpty {
                digits.append(character)
                index += 1
                continue
            }
            if character == ",", !digits.isEmpty {
                digits.append(character)
                index += 1
                continue
            }
            if character == "O" || character == "o", isZeroLetter(characters, at: index) {
                digits.append("0")
                reasons.insert(.correctedLetterO)
                index += 1
                continue
            }
            break
        }
        guard let amount = decimal(digits) else { return nil }

        // The unit, which the capture may or may not have spaced away from the number.
        var unitText = ""
        var look = index
        while look < characters.count, characters[look] == " " || characters[look] == "\t" { look += 1 }
        while look < characters.count, characters[look].isLetter, unitText.count < 6 {
            unitText.append(characters[look])
            look += 1
        }

        var printed: MeasureUnit?
        if unitText.isEmpty {
            printed = nil
        } else if let unit = unit(for: unitText) {
            printed = unit
            if unitText.lowercased() == "ug" || unitText.contains("\u{00B5}") || unitText.contains("\u{03BC}") {
                reasons.insert(.normalisedMicrogramSymbol)
            }
        } else {
            // A word the registry does not carry is not resolved into a unit it does carry, so the row
            // keeps no amount rather than an amount in a unit nobody printed.
            return nil
        }

        return ScannedAmount(
            amount: amount,
            unit: printed,
            isBound: false,
            reasons: reasons,
            remaining: remaining(after: look, in: characters)
        )
    }

    /// Reads the amount of a line that states a bound, which becomes `.belowReportingThreshold`.
    private static func bound(in characters: [Character], from start: Int) -> ScannedAmount? {
        let tail = String(characters[min(start, characters.count)...])
        guard let scan = scanAmount(in: tail) else { return nil }
        return ScannedAmount(
            amount: scan.amount,
            unit: scan.unit,
            isBound: true,
            reasons: scan.reasons,
            remaining: scan.remaining
        )
    }

    /// The phrases a bound may be written with. "less than" is checked before "less", and a word that
    /// merely starts with one of them, such as "ltr", is not a bound.
    private static func boundPrefix(in characters: [Character], from start: Int) -> (isBound: Bool, consumed: Int) {
        let phrases = ["less than", "fewer than", "under", "below", "less", "lt"]
        let head = String(characters[start...].prefix(12)).lowercased()
        for phrase in phrases where head.hasPrefix(phrase) {
            let next = start + phrase.count
            let spaced = next >= characters.count || characters[next] == " " || characters[next] == "\t"
            if spaced { return (true, next) }
        }
        return (false, 0)
    }

    /// The text after an amount, with the % Daily Value column of this row stepped over.
    ///
    /// The search stops at the next nutrient name on the line, because a Daily Value belongs to the row
    /// that printed it. A flattened line that runs a row without a Daily Value into one that has it must
    /// not lose the second row's amount to the first row's removal.
    private static func remaining(after index: Int, in characters: [Character]) -> String {
        let tail = String(characters[min(index, characters.count)...])
        let scopeEnd = firstRow(in: tail)?.nameStart ?? tail.endIndex
        let scope = String(tail[..<scopeEnd])
        let column = percentDailyValue()
        guard let match = try? column.firstMatch(in: scope) else { return tail }
        let offset = scope.distance(from: scope.startIndex, to: match.range.upperBound)
        let start = scope.index(scope.startIndex, offsetBy: offset)
        return String(scope[start...]) + String(tail[scopeEnd...])
    }

    /// Whether the letter `O` stands where a zero belongs: it touches a digit, it is the whole number
    /// and a unit follows it as in "O g", or it opens a decimal number as in "O.5g".
    private static func isZeroLetter(_ characters: [Character], at index: Int) -> Bool {
        if index > 0, isDigit(characters[index - 1]) { return true }
        if index + 2 < characters.count, characters[index + 1] == ".", isDigit(characters[index + 2]) {
            return true
        }
        var look = index + 1
        while look < characters.count, characters[look] == " " || characters[look] == "\t" { look += 1 }
        guard look < characters.count, characters[look].isLetter else { return false }
        return true
    }

    // MARK: - Text helpers

    /// The units a panel row may carry, and nothing else. "mcg", "µg" and "μg" are one mass and become
    /// `mcg`; a unit outside this table is never resolved into one inside it.
    private static func unit(for text: String) -> MeasureUnit? {
        switch text.lowercased() {
        case "g": return .g
        case "mg": return .mg
        case "mcg", "ug", "\u{00B5}g", "\u{03BC}g": return .mcg
        case "kg": return .kg
        case "ml": return .mL
        case "l": return .L
        case "kcal": return .kcal
        default: return nil
        }
    }

    /// One value read exactly from its own text, or nil when the text states no number.
    ///
    /// A comma is only a thousands separator: the first group is one to three digits and every group
    /// after it is exactly three, as in `1,000` and `12,500`. Anything else is ambiguous, so the row keeps
    /// no amount at all rather than the smaller number the digits before the comma spell.
    private static func decimal(_ digits: String) -> Decimal? {
        var text = digits
        while text.hasSuffix(".") { text.removeLast() }
        guard text.contains(where: { isDigit($0) }) else { return nil }
        guard isGroupedThousands(text) else { return nil }
        return Decimal(string: text.replacingOccurrences(of: ",", with: ""), locale: posix)
    }

    /// Whether the commas in a numeric token only group thousands.
    private static func isGroupedThousands(_ text: String) -> Bool {
        guard text.contains(",") else { return true }
        let groups = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let first = groups.first else { return false }
        guard (1...3).contains(first.count), first.allSatisfy({ isDigit($0) }) else { return false }
        for group in groups.dropFirst() {
            guard group.count == 3, group.allSatisfy({ isDigit($0) }) else { return false }
        }
        return true
    }

    /// The first number anywhere in a piece of text, for a count the label states in words around it.
    private static func firstDecimal(in rawText: String) -> Decimal? {
        let characters = Array(trimmed(rawText))
        var index = 0
        while index < characters.count {
            guard isDigit(characters[index]) || characters[index] == "." else {
                index += 1
                continue
            }
            var digits = ""
            while index < characters.count, isDigit(characters[index]) || characters[index] == "." {
                digits.append(characters[index])
                index += 1
            }
            if let value = decimal(digits) { return value }
        }
        return nil
    }

    /// Whether a match is a whole word, so the "fat" of "Saturated Fat" is not read as the fat row when
    /// nothing longer matched before it.
    private static func isWholeWord(_ range: Range<String.Index>, in lower: String) -> Bool {
        if range.lowerBound != lower.startIndex {
            let before = lower[lower.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound != lower.endIndex {
            let after = lower[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    /// The text of `line` from a match found in its lowercased copy. Lowercasing can move a Swift string
    /// index, so the offset is measured in the lowercased text and applied to the original.
    private static func after(_ range: Range<String.Index>, in line: String, lowercased lower: String) -> String {
        let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
        guard let start = line.index(line.startIndex, offsetBy: offset, limitedBy: line.endIndex) else { return "" }
        return String(line[start...])
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    /// One line with its surrounding whitespace removed and its inner runs of whitespace collapsed, so a
    /// name and its amount read the same whether the capture wrote "Total Fat 7g" or "Total Fat  7 g".
    private static func cleanLine(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
