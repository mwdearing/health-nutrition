import Foundation

/// The one spelling of a key the app stores a name under.
///
/// A component id, a captured compound and a snapshot identity all address the same kind of thing: a
/// name the user gave or a label printed, held as a key something else can look up. Keeping the
/// spelling here means a compound read off a panel and a component typed into an entry sort the same
/// way, rather than each place inventing its own rules and quietly disagreeing.
public enum Slug {
    /// `[a-z0-9][a-z0-9._-]{0,63}`: the text lowercased, every run of anything else collapsed into a
    /// single dash, trailing dashes dropped and the result capped. Text with nothing a slug can hold
    /// becomes `item`, so a key is never the empty string.
    ///
    /// Pure, so it is callable from anywhere: the parser reads a label's own name into one, and the
    /// intake form builds a component id from what the user typed.
    public static func make(_ text: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in text.lowercased().unicodeScalars {
            let isAllowed = scalar.isASCII && (("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)))
            if isAllowed {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty { return "item" }
        return String(result.prefix(64))
    }
}