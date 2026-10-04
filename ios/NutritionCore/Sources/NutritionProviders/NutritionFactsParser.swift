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
            // A capture can flatten the serving metadata and a nutrient row onto one line, so the
            // metadata is taken off first and whatever text is left behind it is still read.
            var residual = withoutDailyValueHeading(in: cleaned[index])
            let following = index + 1 < cleaned.count ? cleaned[index + 1] : nil
            if let read = servingSize(in: residual, next: following) {
                if size == nil { size = read }
                residual = withoutServingSize(in: residual, next: following)
            }
            if let count = servingsPerContainer(in: residual) {
                if perContainer == nil { perContainer = count }
                residual = withoutServingsPerContainer(in: residual)
            }
            guard !residual.isEmpty else {
                index += 1
                continue
            }
            let usedNext = absorbRows(in: residual, following: following, amounts: &amounts, reviews: &reviews)
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
    ///
    /// The measure ends where the next piece of panel text begins, because a flattened line can carry
    /// another field behind the serving size and the serving size is only what the label printed in
    /// front of it.
    private static func servingSize(in line: String, next nextLine: String? = nil) -> ParsedServingSize? {
        let lower = line.lowercased()
        guard let marker = lower.range(of: "serving size") else { return nil }
        var text = after(marker, in: line, lowercased: lower)
        if let colon = text.firstIndex(of: ":") {
            text = String(text[text.index(after: colon)...])
        }
        text = String(text[..<nextField(in: text, next: nextLine)])
        text = trimmed(text)
        guard !text.isEmpty else { return nil }
        let measure = servingMeasure(in: text)
        return ParsedServingSize(text: text, quantity: measure.quantity, review: measure.review)
    }

    /// The count a "servings per container" line states. The number may stand before the phrase
    /// ("About 6 servings per container") or after it ("Servings Per Container: 12").
    ///
    /// Both the plural and the singular wording are read, because a single-serving package states
    /// "1 serving per container" and its count would otherwise be lost.
    private static func servingsPerContainer(in line: String) -> Decimal? {
        let lower = line.lowercased()
        guard let marker = servingsMarker(in: lower) else { return nil }
        let head = String(line[..<index(marker.lowerBound, in: line, lowercased: lower)])
        // The count is the number next to the marker: the one behind the phrase when the label wrote it
        // there ("Servings Per Container: 12"), and otherwise the one in front of it, as in "About 6
        // servings per container". An earlier number that belongs to the rest of the line, such as the
        // twelve of "Net wt 12 oz About 6 servings per container", is never read as the count.
        if let count = firstCompleteDecimal(in: after(marker, in: line, lowercased: lower)) { return count }
        return lastCompleteDecimal(in: head)
    }

    /// The span of a line a serving size is written in, from the marker to the end of the measure.
    ///
    /// The span is what `parse` takes off the line before it reads the rows behind it, so a flattened
    /// line that carries a nutrient row behind its serving metadata still has that row read.
    private static func servingSizeSpan(in line: String, next nextLine: String? = nil) -> Range<String.Index>? {
        let lower = line.lowercased()
        guard let marker = lower.range(of: "serving size") else { return nil }
        let start = index(marker.lowerBound, in: line, lowercased: lower)
        var end = index(marker.upperBound, in: line, lowercased: lower)
        var tail = String(line[end...])
        if let colon = tail.firstIndex(of: ":") {
            end = line.index(end, offsetBy: tail.distance(from: tail.startIndex, to: colon) + 1)
            tail = String(line[end...])
        }
        // The span runs to the next piece of panel text, or to the end of the line when the measure is
        // the last thing the line states.
        end = line.index(end, offsetBy: tail.distance(from: tail.startIndex, to: nextField(in: tail, next: nextLine)))
        return start..<end
    }

    /// Where the next piece of panel text begins in `text`: the next nutrient row that states an
    /// amount, or the next piece of serving metadata, whichever comes first.
    ///
    /// A nutrient name only ends a serving size when an amount follows it as a row, because a serving
    /// description can name a nutrient: "Serving size 1 protein bar (50g)" describes the bar, so the
    /// name in it is part of the measure rather than the start of a row behind it.
    ///
    /// Flattened metadata puts the two fields next to each other in either order, as in
    /// "Serving size 1 cup (240mL) 8 servings per container", so each field stops where the other begins.
    /// When the next field is the servings count, the count itself belongs to that field rather than to
    /// this one, so the boundary steps back over it.
    private static func nextField(in text: String, next nextLine: String? = nil) -> String.Index {
        let rowBoundary = firstRowThatStatesAmount(in: text, next: nextLine) ?? text.endIndex
        let lower = text.lowercased()
        guard let marker = servingsMarker(in: lower) else { return rowBoundary }
        let markerStart = index(marker.lowerBound, in: text, lowercased: lower)
        guard markerStart < rowBoundary else { return rowBoundary }

        let head = text[..<markerStart]
        let tokens = trimmed(String(head)).split(separator: " ").map(String.init)
        guard let last = tokens.last, completeDecimal(last) != nil else { return markerStart }
        // Find the count in the original text rather than doing index arithmetic: OCR can drop the
        // spaces around it, and an offset computed from assumed separators can fall before the start.
        return head.range(of: last, options: .backwards)?.lowerBound ?? markerStart
    }

    /// Where the first nutrient row that states its own amount begins in `text`.
    ///
    /// A nutrient name is only the start of a row when an amount follows it, so a name inside a
    /// serving description is skipped and the search carries on behind it: in
    /// "1 protein bar (50g) Protein 6g" the first name describes the bar and the second one opens a row.
    /// A name the text ends with is a row whose amount landed on the next line, as in
    /// "Serving size 1 bar (50g) Protein" followed by "6g", so it ends the serving description too and
    /// that row is read from the line behind it. The name is stepped over rather than the text after it,
    /// so a later whole-word name still matches.
    private static func firstRowThatStatesAmount(in text: String, next nextLine: String? = nil) -> String.Index? {
        var offset = 0
        while offset < text.count {
            let tail = String(text.dropFirst(offset))
            guard let match = firstRow(in: tail) else { return nil }
            let start = offset + tail.distance(from: tail.startIndex, to: match.nameStart)
            let remainder = String(tail[match.end...])
            if let scan = scanAmount(in: remainder), statesAmount(scan, for: match.row) {
                return text.index(text.startIndex, offsetBy: start)
            }
            if remainder.isEmpty, let nextLine, let scan = scanAmount(in: trimmed(nextLine)),
               statesAmount(scan, for: match.row)
            {
                return text.index(text.startIndex, offsetBy: start)
            }
            offset = start + tail.distance(from: tail.startIndex, to: match.end)
        }
        return nil
    }

    /// The line with its serving size taken off, so whatever else it carries is still read.
    private static func withoutServingSize(in line: String, next nextLine: String? = nil) -> String {
        guard let span = servingSizeSpan(in: line, next: nextLine) else { return line }
        return trimmed(String(line[..<span.lowerBound]) + " " + String(line[span.upperBound...]))
    }

    /// The line with its servings-per-container marker, the qualifier words and the count beside it taken
    /// off, so whatever else the flattened line carries is still read.
    private static func withoutServingsPerContainer(in line: String) -> String {
        let lower = line.lowercased()
        guard let marker = servingsMarker(in: lower) else { return line }
        var head = String(line[..<index(marker.lowerBound, in: line, lowercased: lower)])
        // The count in front of the marker belongs to it, as the six of "About 6 servings per container".
        if let last = head.split(separator: " ").last, completeDecimal(String(last)) != nil {
            head = head.split(separator: " ").dropLast().joined(separator: " ")
        }
        var end = index(marker.upperBound, in: line, lowercased: lower)
        var tail = String(line[end...])
        // A colon the capture wrote against the text behind the marker belongs to the marker and not to
        // the count, as in "Servings Per Container:12" and "Servings Per Container:About 8". It is
        // stepped over on its own, because the space that would separate it can be missing.
        while let first = tail.first, first == ":" || first == " " || first == "\t" {
            end = line.index(after: end)
            tail = String(line[end...])
        }
        // A colon and the qualifier words stand between the marker and the count, as in
        // "Servings Per Container: About 8", and are stepped over rather than read as one.
        while let first = tail.split(separator: " ").first,
              first == ":" || leadingWords.contains(String(first).lowercased())
        {
            end = line.index(end, offsetBy: first.count + 1, limitedBy: line.endIndex) ?? line.endIndex
            tail = String(line[end...])
        }
        if let count = tail.split(separator: " ").first, completeDecimal(String(count)) != nil {
            end = line.index(end, offsetBy: count.count + 1, limitedBy: line.endIndex) ?? line.endIndex
        }
        return trimmed(head + " " + String(line[end...]))
    }

    /// The line with a flattened % Daily Value heading taken off, so the rows that share the line with
    /// the heading are still read.
    ///
    /// The heading names the column and states no amount of its own, so only its own text is skipped. A
    /// percent sign is dropped only when it is the heading's own, as in "% Daily Value Total Fat 7g": a
    /// sign attached to a number belongs to that row's Daily Value, so "Calories 10% Daily Value" keeps
    /// its sign and stays a Daily Value rather than becoming a calorie count. The capture can space the
    /// sign away from the number, as in "Calories 10 % Daily Value", and it stays with the number for the
    /// same reason unless the heading was flattened with the rows behind it.
    private static func withoutDailyValueHeading(in line: String) -> String {
        var text = line
        while true {
            let lower = text.lowercased()
            guard let marker = lower.range(of: "daily value") else { break }
            let headEnd = index(marker.lowerBound, in: text, lowercased: lower)
            var head = trimmed(String(text[..<headEnd]))
            let tail = String(text[index(marker.upperBound, in: text, lowercased: lower)...])
            if isHeadingPercent(head, tail: tail) {
                head = trimmed(String(head.dropLast()))
            }
            text = trimmed(head + " " + tail)
        }
        return trimmed(text)
    }

    /// Whether the percent sign the text in front of a Daily Value heading belongs to that heading.
    ///
    /// The heading's own sign is either the one that opens it, with no number in front of it as in
    /// "% Daily Value Total Fat 7g", or the one the capture wrote in front of the heading's words while it
    /// flattened the heading together with the rows behind it, as in
    /// "Calories 250 % Daily Value* Total Fat 7g", where the row beside the heading keeps the amount the
    /// label printed. A sign that stands behind a number is that row's own Daily Value, whether the
    /// capture touched it or spaced it away, so "Calories 10 % Daily Value" keeps its sign and stays a
    /// Daily Value rather than a calorie count.
    private static func isHeadingPercent(_ head: String, tail: String) -> Bool {
        guard head.hasSuffix("%") else { return false }
        // The sign with no number in front of it opened the heading, so it is the heading's.
        guard isAttachedToNumber(head) else { return true }
        // The sign the capture spaced away from its number is the heading's only where the heading was
        // flattened with a row behind it, because that is where the heading's own sign ends up.
        return firstRow(in: tail) != nil
    }

    /// Whether the text ends in a percent sign that stands behind a number, as the ten of
    /// "Calories 10%" does. The capture can write the space between them, as in "Calories 10 %", and the
    /// sign still belongs to that number.
    private static func isAttachedToNumber(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 2, characters[characters.count - 1] == "%" else { return false }
        var look = characters.count - 2
        while look >= 0, characters[look] == " " || characters[look] == "\t" { look -= 1 }
        return look >= 0 && isDigit(characters[look])
    }

    /// The first of the two wordings of a servings-per-container marker that a line carries.
    private static func servingsMarker(in lower: String) -> Range<String.Index>? {
        var found: Range<String.Index>?
        for marker in ["servings per container", "serving per container"] {
            guard let range = lower.range(of: marker) else { continue }
            if let current = found, current.lowerBound <= range.lowerBound { continue }
            found = range
        }
        return found
    }

    /// The count written directly behind a marker, past any colon and any qualifier word, as in
    /// "Servings Per Container: 12" and "Servings Per Container About 8".
    private static func firstCompleteDecimal(in rawText: String) -> Decimal? {
        var text = trimmed(rawText)
        // The marker's colon is the label's own punctuation, so it is taken off before the text is
        // split: the count can be written against it, as in "Servings Per Container:12", and the colon
        // is then no longer a token of its own that the skip below can recognise.
        while text.hasPrefix(":") { text = trimmed(String(text.dropFirst())) }
        var tokens = text.split(separator: " ").map(String.init)
        while let first = tokens.first {
            if first == ":" || leadingWords.contains(first.lowercased()) {
                tokens.removeFirst()
                continue
            }
            return completeDecimal(first)
        }
        return nil
    }

    /// The count written directly in front of a marker, as in "About 6 servings per container".
    ///
    /// The search walks the text backwards and stops at the first number it finds, because the count
    /// stands next to the marker: in "Net wt 12 oz About 6 servings per container" the twelve belongs
    /// to the net weight and the six is the serving count.
    private static func lastCompleteDecimal(in rawText: String) -> Decimal? {
        for token in trimmed(rawText).split(separator: " ").reversed() {
            if let count = completeDecimal(String(token)) { return count }
        }
        return nil
    }

    /// The number a whitespace-separated token states, when it states one and nothing else.
    ///
    /// A token that runs straight into letters is a token the capture misread, such as `1O`: it is
    /// either a number with a zero spelled as a letter or nothing at all, and it is never read as the
    /// smaller number its digits spell.
    private static func completeDecimal(_ token: String) -> Decimal? {
        guard !token.isEmpty, token.allSatisfy({ isDigit($0) || $0 == "." || $0 == "," }) else { return nil }
        return decimal(token)
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
            // A panel states some rows with the amount in front of the name: "Includes 5g Added
            // Sugars". The rest of the line is still read, because a flattened panel runs the rows that
            // follow on the same line.
            if let scan = leadingAmount(before: String(cursor[..<match.nameStart]), for: row), statesAmount(scan, for: row) {
                record(scan, for: row, amounts: &amounts, reviews: &reviews)
                cursor = remainder
                continue
            }
            if remainder.isEmpty, !usedNextLine, let nextLine, let scan = scanAmount(in: trimmed(nextLine)),
               statesAmount(scan, for: row)
            {
                // A name and its amount can also land on separate lines when the panel was read column by
                // column. The text left beside that amount on the same line belongs to the rows behind
                // it, so it is read before the line is left behind as well.
                record(scan, for: row, amounts: &amounts, reviews: &reviews)
                usedNextLine = true
                guard scan.remaining != cursor else { break }
                cursor = scan.remaining
                continue
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
        if scan.unit != nil { return true }
        // The Calories row is the only row of a panel that prints no unit of its own, so a bare number is
        // read there and nowhere else. It is read only when it stands on its own: a number the capture
        // left in front of a percent sign, as in "Calories 10%", is the Daily Value column of a row whose
        // amount the capture lost, and it is never turned into a calorie count.
        return row.usualUnit == .kcal && !scan.isPercentSuffixed
    }

    /// An amount written in front of its nutrient name. Only the words and the number immediately in
    /// front of the name are read, so an earlier row's amount is never pulled onto this row. A token in
    /// front of a percent sign is a Daily Value of another row and is never an amount here. The words
    /// in between may be none at all when the row prints its amount first, as in "5g Added Sugars" where
    /// the capture dropped the `Includes`.
    private static func leadingAmount(before text: String, for row: PanelRow) -> ScannedAmount? {
        let tokens = text.split(separator: " ")
        for count in [2, 1] {
            let tail = tokens.suffix(count).joined(separator: " ")
            guard !tail.contains("%") else { continue }
            // Only the words a panel prints in front of such an amount stand between it and the name,
            // so a number that belongs to unrecognised text before the name is never read as this
            // row's amount: the 50mg of "Magnesium 50mg Calcium" is magnesium, not calcium.
            let words = tokens.dropLast(count)
            guard words.allSatisfy({ leadingWords.contains($0.lowercased()) }) else { continue }
            guard let scan = scanAmount(in: tail) else { continue }
            if words.isEmpty {
                // An empty prefix is read only for a row a panel prints its amount in front of, and then
                // only when the amount carries its own unit. Every other row states its amount behind its
                // name, so a bare amount in front of one is a front-of-pack callout rather than a row of
                // the panel: the 20g of "20g Protein" is not the protein of "Protein 6g". A bare number
                // with no unit is left alone as well, as the 2,000 of the standard calorie footnote.
                guard amountFirstRows.contains(row.key), scan.unit != nil else { continue }
            }
            return scan
        }
        return nil
    }

    /// The rows a panel prints with their amount in front of their name: the breakdown rows it states
    /// inside another row, as in "Includes 5g Added Sugars" and "Includes 2g Trans Fat".
    private static let amountFirstRows: Set<NutritionFactKey> = [.addedSugars, .transFat]

    /// The words a panel may print between an amount and the nutrient name it belongs to, as in
    /// "Includes 5g Added Sugars". A row that states its amount in front of its name is stated with one
    /// of these words in between, so a number with any other word in front of it is left alone.
    private static let leadingWords: Set<String> = ["includes", "contains", "about", "with", "of", "has"]

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
                // An alias can also stand inside another word, as the "sodium" of "Monosodium glutamate".
                // The search moves past such an occurrence instead of giving up on the name, so a later
                // whole-word occurrence still matches.
                var search = lower.startIndex
                while let found = lower.range(of: alias, range: search..<lower.endIndex) {
                    if isWholeWord(found, in: lower) {
                        let start = lower.distance(from: lower.startIndex, to: found.lowerBound)
                        let length = alias.count
                        if let current = best {
                            // Keep the earliest name on the line; at the same start keep the longer one, so
                            // "Saturated Fat" wins over the "fat" inside it and "Added Sugars" over "sugars".
                            if start > current.start || (start == current.start && length <= current.length) { break }
                        }
                        best = (start, length, row)
                        break
                    }
                    search = found.lowerBound < found.upperBound ? found.upperBound : lower.index(after: found.lowerBound)
                }
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
        /// Whether the number stands directly in front of a percent sign, which means it belongs to the
        /// % Daily Value column and not to the row.
        let isPercentSuffixed: Bool
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
            isPercentSuffixed: isPercentSuffix(characters, at: index),
            reasons: reasons,
            remaining: remaining(after: look, in: characters)
        )
    }

    /// Whether the number read up to `index` is written straight in front of a percent sign, as in
    /// "Calories 10%". Such a number is a % Daily Value the capture flattened onto the row, never an
    /// amount the row printed.
    private static func isPercentSuffix(_ characters: [Character], at index: Int) -> Bool {
        var look = index
        while look < characters.count, characters[look] == " " || characters[look] == "\t" { look += 1 }
        return look < characters.count && characters[look] == "%"
    }

    /// Reads the amount of a line that states a bound, which becomes `.belowReportingThreshold`.
    private static func bound(in characters: [Character], from start: Int) -> ScannedAmount? {
        let tail = String(characters[min(start, characters.count)...])
        guard let scan = scanAmount(in: tail) else { return nil }
        return ScannedAmount(
            amount: scan.amount,
            unit: scan.unit,
            isBound: true,
            isPercentSuffixed: scan.isPercentSuffixed,
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
        String(line[index(range.upperBound, in: line, lowercased: lower)...])
    }

    /// The place in `line` a position of its lowercased copy stands at.
    ///
    /// Lowercasing can move a Swift string index, so the offset is measured in the lowercased text and
    /// applied to the original.
    private static func index(_ position: String.Index, in line: String, lowercased lower: String) -> String.Index {
        let offset = lower.distance(from: lower.startIndex, to: position)
        return line.index(line.startIndex, offsetBy: offset, limitedBy: line.endIndex) ?? line.endIndex
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
