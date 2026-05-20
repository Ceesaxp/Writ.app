import Foundation

/// GitHub-style heading slug used for stable HTML `id` attributes
/// on headings and for TOC `href="#..."` links. Public so both the
/// HTML emitter (which writes the id) and downstream TOC builders
/// (which need to produce the same anchor) can compute identical
/// slugs from the same text.
public enum HeadingSlug {
    /// Lowercase, spaces/underscores/hyphens → single hyphen, drop
    /// everything else (punctuation, accents-with-marks, emoji).
    public static func make(_ text: String) -> String {
        var out = ""
        var lastWasHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            let isAlphaNum =
                (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                (scalar.value >= 0x61 && scalar.value <= 0x7A)
            if isAlphaNum {
                out.append(Character(scalar))
                lastWasHyphen = false
            } else if scalar == " " || scalar == "-" || scalar == "_" {
                if !lastWasHyphen && !out.isEmpty {
                    out.append("-")
                    lastWasHyphen = true
                }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
