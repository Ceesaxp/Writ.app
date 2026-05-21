import Foundation

/// YAML (`---`) or TOML (`+++`) front matter at the top of a Markdown
/// document. Common with Jekyll/Hugo/Astro/Zola and growing in MDX.
///
/// We don't try to be a full YAML or TOML parser — front matter in
/// practice is a flat key→value bag with scalar (and very occasionally
/// inline-array) values. That's all we surface. Nested mappings are
/// preserved as the raw value string so they round-trip on save.
public struct FrontMatter: Sendable {
    public enum Format: Sendable { case yaml, toml }

    public let format: Format
    /// Ordered key→value pairs (preserves source order). Values are
    /// the raw string after the `:` / `=`, trimmed.
    public let entries: [(key: String, value: String)]
    /// UTF-16 length of the entire front-matter block including
    /// delimiters and the newline that follows the closer. Callers
    /// strip this prefix before parsing the rest as Markdown.
    public let charCount: Int

    public subscript(key: String) -> String? {
        entries.first(where: { $0.key == key })?.value
    }
}

public enum FrontMatterExtractor {
    /// Extracts a YAML or TOML front-matter block when it appears at
    /// position 0. Returns `nil` if the source doesn't start with a
    /// recognised opener or the block is malformed.
    public static func extract(_ source: String) -> (FrontMatter, remainder: String)? {
        if let result = extractDelimited(source, opener: "---", format: .yaml) {
            return result
        }
        if let result = extractDelimited(source, opener: "+++", format: .toml) {
            return result
        }
        return nil
    }

    private static func extractDelimited(_ source: String, opener: String, format: FrontMatter.Format) -> (FrontMatter, remainder: String)? {
        // Match the opener at the very start of the document, followed
        // by a newline. We don't accept indented or whitespace-padded
        // openers — front matter is a strict header.
        guard source.hasPrefix(opener + "\n") || source.hasPrefix(opener + "\r\n") else {
            return nil
        }

        let openerEnd: String.Index
        if source.hasPrefix(opener + "\r\n") {
            openerEnd = source.index(source.startIndex, offsetBy: opener.count + 2)
        } else {
            openerEnd = source.index(source.startIndex, offsetBy: opener.count + 1)
        }

        // Search for a closing delimiter (same chars) on its own line.
        // The closer must be followed by either a newline or EOF.
        let after = source[openerEnd...]
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false)
        var bodyLines: [Substring] = []
        var foundCloser = false
        var closerLineIndex = 0
        for (idx, line) in lines.enumerated() {
            // Tolerate CRLF: strip a trailing \r before comparing.
            let stripped = line.hasSuffix("\r") ? line.dropLast() : line.suffix(from: line.startIndex)
            if stripped == opener {
                foundCloser = true
                closerLineIndex = idx
                break
            }
            bodyLines.append(line)
        }
        guard foundCloser else { return nil }

        let entries = parseEntries(bodyLines.map(String.init), format: format)

        // Compute the byte/character count consumed so callers know
        // where the Markdown body begins.
        let consumedLines = closerLineIndex + 1 // body + closer line
        var totalChars = opener.count + 1 // opener + its newline
        for i in 0..<consumedLines {
            totalChars += lines[i].count + 1 // +1 for the trailing \n
        }
        // If the closer is the last line and there's no trailing \n
        // in the source, back off one.
        let openerWithNewline = opener + "\n"
        let charCount = min(totalChars, source.count)
        _ = openerWithNewline

        let cutIdx = source.index(source.startIndex, offsetBy: charCount, limitedBy: source.endIndex) ?? source.endIndex
        let remainder = String(source[cutIdx...])
        let fm = FrontMatter(format: format, entries: entries, charCount: charCount)
        return (fm, remainder)
    }

    /// Naive key→value parser. Lines that don't match `key: value`
    /// (YAML) or `key = value` (TOML) are silently dropped; comments
    /// (`#` for YAML, `#` or no convention for TOML) are also dropped.
    private static func parseEntries(_ lines: [String], format: FrontMatter.Format) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        let separator: Character = (format == .yaml) ? ":" : "="
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let sepIdx = line.firstIndex(of: separator) else { continue }
            let key = line[..<sepIdx].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: sepIdx)...].trimmingCharacters(in: .whitespaces)
            // Strip a single layer of surrounding quotes for both
            // YAML and TOML so the user sees the inner string.
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            out.append((key, value))
        }
        return out
    }
}
