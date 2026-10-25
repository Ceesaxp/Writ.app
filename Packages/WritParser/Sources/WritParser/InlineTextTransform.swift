import Foundation

/// Post-processes the plain-text content of an inline `Text` AST node
/// before it's emitted as HTML. Two transforms:
///
///   1. **Emoji shortcodes** — `:smile:` → 😄, matched against a static
///      table of GitHub-style names. Patterns not in the table are
///      left literal (no error, no warning). Always applied.
///   2. **Autolink bare URLs (GFM)** — `https://example.com` and
///      `www.example.com` are emitted as `<a href="…">…</a>`.
///      Trailing punctuation is trimmed from the link's text. Skipped
///      when `allowAutolink` is false (the caller is already emitting
///      text inside a `Link` node and we don't want to double-link).
///
/// HTML escaping is the caller's responsibility for the non-URL text
/// runs; we hand each run back as a plain string so the emitter can
/// reuse its own escape function.
enum InlineTextTransform {
    /// Emits `text` into `out`, interleaving any autolink anchors.
    /// `escape` is the emitter's HTML-escape helper.
    static func emit(
        text: String,
        allowAutolink: Bool,
        into out: inout String,
        escape: (String) -> String
    ) {
        let substituted = EmojiShortcodes.substitute(in: text)
        guard allowAutolink else {
            out.append(escape(substituted))
            return
        }
        let nsText = substituted as NSString
        let matches = AutolinkExtractor.scan(substituted)
        if matches.isEmpty {
            out.append(escape(substituted))
            return
        }
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let prefix = nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                out.append(escape(prefix))
            }
            let display = nsText.substring(with: match.range)
            out.append("<a href=\"\(escape(match.href))\">\(escape(display))</a>")
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tail = nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
            out.append(escape(tail))
        }
    }
}

// MARK: - Autolink

enum AutolinkExtractor {
    struct Match {
        /// UTF-16 range in the input text (NSRange-compatible).
        let range: NSRange
        /// What goes into the `href` — for `www.foo.com` matches we
        /// prepend `http://` so the link is clickable.
        let href: String
    }

    // Scheme prefixes we look for, pre-lowercased as UTF-16 code
    // units so the scan never has to allocate a String to compare.
    private static let httpsScheme: [unichar] = [0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F]  // "https://"
    private static let httpScheme: [unichar] = [0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F]          // "http://"
    private static let wwwHost: [unichar] = [0x77, 0x77, 0x77, 0x2E]                               // "www."

    /// Scan `text` for autolinkable URL spans. Returns matches in left-
    /// to-right order, non-overlapping. Skips URLs already wrapped in
    /// angle brackets (`<https://…>`) — those are CommonMark's own
    /// autolinks which the parser has already handled.
    ///
    /// The whole scan runs over one UTF-16 buffer taken from `text`
    /// up front: text nodes are line-sized, so that is a single small
    /// allocation, and every probe below is an integer compare.
    static func scan(_ text: String) -> [Match] {
        let units = Array(text.utf16)
        let length = units.count
        var results: [Match] = []
        var cursor = 0
        while cursor < length {
            guard let startInfo = findNextStart(units, from: cursor) else { break }
            let urlStart = startInfo.start
            let isWWW = startInfo.isWWW

            // Walk forward as long as characters look URL-shaped.
            var end = urlStart
            while end < length {
                if isURLChar(units[end]) {
                    end += 1
                } else {
                    break
                }
            }
            var url = String(decoding: units[urlStart..<end], as: UTF16.self)

            // Need a `.` somewhere after the scheme/host start for it
            // to be a plausible URL.
            if !url.contains(".") {
                cursor = end > urlStart ? end : urlStart + 1
                continue
            }

            // Trim trailing punctuation that's not part of the URL
            // (`.`, `,`, `;`, `:`, `!`, `?`).
            while let last = url.last, "., ;:!?".contains(last) {
                url.removeLast()
            }
            // Strip a trailing `)` if it has no matching `(` inside —
            // covers Markdown links / wiki citations like "(see
            // https://example.com)".
            while let last = url.last, last == ")",
                  url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count {
                url.removeLast()
            }
            // After trimming we still need a `.` and at least one
            // character after it (domain at minimum: `a.bc`).
            if !url.contains("."), url.count < 4 {
                cursor = end
                continue
            }
            // www.bare hosts need an explicit scheme.
            let href = isWWW ? "http://\(url)" : url

            let finalRange = NSRange(location: urlStart, length: (url as NSString).length)
            results.append(Match(range: finalRange, href: href))
            cursor = finalRange.location + finalRange.length
        }
        return results
    }

    /// Returns the location of the next URL candidate start, or nil.
    /// Skips matches already wrapped in `<…>` (CommonMark autolinks).
    private static func findNextStart(_ units: [unichar], from: Int) -> (start: Int, isWWW: Bool)? {
        var i = from
        let length = units.count
        while i < length {
            // Only `h` and `w` can begin a candidate, so reject on the
            // first code unit before probing a whole prefix. This is
            // what keeps the scan near-free on prose with no URLs.
            switch units[i] {
            case 0x68, 0x48:  // h H
                if startsWith(units, at: i, httpsScheme) || startsWith(units, at: i, httpScheme) {
                    // Reject if immediately preceded by `<` (already a
                    // CommonMark autolink) or by a URL character
                    // (already mid-token).
                    if !precededByExcluded(units, at: i) {
                        return (i, false)
                    }
                }
            case 0x77, 0x57:  // w W
                if startsWith(units, at: i, wwwHost) {
                    if !precededByExcluded(units, at: i) {
                        return (i, true)
                    }
                }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    /// Case-insensitive prefix compare against an already-lowercase
    /// needle. Folding is ASCII-only, which loses nothing here: no
    /// non-ASCII code point lowercases to `h`, `t`, `p`, `s` or `w`.
    @inline(__always)
    private static func startsWith(_ units: [unichar], at index: Int, _ needle: [unichar]) -> Bool {
        let n = needle.count
        guard index + n <= units.count else { return false }
        for k in 0..<n {
            if asciiLowercased(units[index + k]) != needle[k] { return false }
        }
        return true
    }

    @inline(__always)
    private static func asciiLowercased(_ c: unichar) -> unichar {
        (0x41...0x5A).contains(c) ? c | 0x20 : c  // A-Z
    }

    @inline(__always)
    private static func precededByExcluded(_ units: [unichar], at index: Int) -> Bool {
        guard index > 0 else { return false }
        let prev = units[index - 1]
        // `<` means we're inside a CommonMark autolink — leave alone.
        if prev == 0x3C { return true }  // '<'
        // Word-continuation character means we're inside another
        // token (e.g. "foohttps://x" shouldn't autolink).
        return isURLChar(prev) && prev != 0x20
    }

    @inline(__always)
    private static func isURLChar(_ c: unichar) -> Bool {
        // ASCII letters, digits, and URL-safe punctuation. Avoid
        // breaking on Unicode — bare URLs are ASCII-only in practice.
        if (0x30...0x39).contains(c) { return true }  // 0-9
        if (0x41...0x5A).contains(c) { return true }  // A-Z
        if (0x61...0x7A).contains(c) { return true }  // a-z
        switch c {
        case 0x2D, 0x2E, 0x5F, 0x7E:                     // - . _ ~
            return true
        case 0x21, 0x24, 0x26, 0x27, 0x28, 0x29:         // ! $ & ' ( )
            return true
        case 0x2A, 0x2B, 0x2C, 0x3B, 0x3D:               // * + , ; =
            return true
        case 0x25, 0x2F, 0x3A, 0x3F, 0x40, 0x23:         // % / : ? @ #
            return true
        case 0x5B, 0x5D:                                   // [ ]
            return true
        default:
            return false
        }
    }
}
