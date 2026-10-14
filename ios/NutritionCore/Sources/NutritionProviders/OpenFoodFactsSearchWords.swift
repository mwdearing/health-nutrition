import Foundation

/// Decides whether a search result shows the words a person typed. The search service also matches on
/// category, label and names in other languages, so a result can come back without the typed words
/// anywhere in its name or brand; the client keeps only results that show them.
///
/// Both sides are written the same way before comparing: case and accents folded, ligatures spelled
/// out, apostrophes removed inside words ("Kellogg's" and "Kelloggs" are one word), and "&" read as
/// "and". A typed word is shown when it begins a shown word ("choc" begins "chocolate"), or when one of
/// its singular forms is a whole shown word or the singular of one ("loaves" and "loaf"). Singular forms
/// are only ever compared as whole words, so a guess such as "frie" from "fries" cannot start
/// "Friendly". Words in scripts written without spaces (Chinese, Japanese, Thai and similar) are matched
/// anywhere in the text, because there a name is one unbroken run.
enum OpenFoodFactsSearchWords {
    /// Lowercased with accents removed and ligatures spelled out, so "Crème", "creme", "Œuf" and "oeuf"
    /// compare equal.
    static func folded(_ text: String) -> String {
        var folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        for (ligature, spelled) in [("œ", "oe"), ("æ", "ae"), ("ø", "o"), ("ß", "ss"), ("ł", "l"), ("đ", "d"), ("þ", "th")] {
            folded = folded.replacingOccurrences(of: ligature, with: spelled)
        }
        return folded
    }

    /// The words of a text after folding: "&" becomes "and", apostrophes are removed, and the text is
    /// split at anything that is not a letter or digit.
    static func words(_ text: String) -> [String] {
        folded(text)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// A word with every singular it could have under English plural endings. More than one guess is
    /// made on purpose ("cases" gives "case" and "cas", "cookies" gives "cookie" and "cooky"); the wrong
    /// guesses are harmless because these forms are only compared as whole words.
    static func forms(_ word: String) -> Set<String> {
        var forms: Set<String> = [word]
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else {
            return forms
        }
        forms.insert(String(word.dropLast()))
        if word.hasSuffix("es") {
            forms.insert(String(word.dropLast(2)))
        }
        if word.count > 4, word.hasSuffix("ies") {
            let base = word.dropLast(3)
            forms.insert(base + "y")
            forms.insert(base + "i")
        }
        if word.count > 4, word.hasSuffix("ves") {
            let base = word.dropLast(3)
            forms.insert(base + "f")
            forms.insert(base + "fe")
        }
        return forms
    }

    /// True when the text shows every typed word.
    static func shows(_ typed: [String], in text: String) -> Bool {
        let shown = words(text)
        let shownForms = Set(shown.flatMap(forms))
        let unbroken = shown.joined(separator: " ")
        return typed.allSatisfy { word in
            if isWrittenWithoutSpaces(word) {
                return unbroken.contains(word)
            }
            return shown.contains { $0.hasPrefix(word) } || !forms(word).isDisjoint(with: shownForms)
        }
    }

    /// Han, Hiragana, Katakana, Thai, Lao, Khmer and Myanmar are written without spaces between words.
    static func isWrittenWithoutSpaces(_ word: String) -> Bool {
        word.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3040...0x30FF, 0x3400...0x4DBF,
                 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
