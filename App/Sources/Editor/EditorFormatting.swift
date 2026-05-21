import Cocoa

/// Markdown formatting actions wired into the Format menu and exposed to
/// the responder chain. All edits go through `NSTextView.shouldChangeText`
/// + `didChangeText` so undo and the editor's normal change broadcast both
/// see the operation as a single user step.
///
/// Design notes:
///  - Inline wraps (bold/italic/strike/code) **toggle**: if the selection
///    is already wrapped by the marker pair, unwrap; otherwise wrap.
///  - With an empty selection, wraps insert the markers and place the
///    cursor between them so the user can keep typing.
///  - Line-affecting commands (headings, lists, block quote) operate on
///    every line touched by the selection, not the line of the caret only.
///  - Headings toggle: ⌘1 on an existing H1 line removes the `# `; ⌘1 on
///    an H2 line replaces `##` with `#`. Idempotent under repeated press.
extension EditorViewController {

    // MARK: - Inline wraps

    @objc func formatBold(_ sender: Any?)          { toggleInlineWrap(marker: "**") }
    @objc func formatItalic(_ sender: Any?)        { toggleInlineWrap(marker: "*") }
    @objc func formatStrikethrough(_ sender: Any?) { toggleInlineWrap(marker: "~~") }
    @objc func formatInlineCode(_ sender: Any?)    { toggleInlineWrap(marker: "`") }

    // MARK: - Link

    @objc func formatLink(_ sender: Any?) { insertLink() }

    // MARK: - Headings — Cmd-1…Cmd-6

    @objc func formatHeading1(_ sender: Any?) { toggleHeading(level: 1) }
    @objc func formatHeading2(_ sender: Any?) { toggleHeading(level: 2) }
    @objc func formatHeading3(_ sender: Any?) { toggleHeading(level: 3) }
    @objc func formatHeading4(_ sender: Any?) { toggleHeading(level: 4) }
    @objc func formatHeading5(_ sender: Any?) { toggleHeading(level: 5) }
    @objc func formatHeading6(_ sender: Any?) { toggleHeading(level: 6) }

    // MARK: - Block level

    @objc func formatFencedCodeBlock(_ sender: Any?) { wrapFencedCode() }
    @objc func formatOrderedList(_ sender: Any?)     { applyOrderedListPrefix() }
    @objc func formatUnorderedList(_ sender: Any?)   { applyLinePrefix("- ") }
    @objc func formatBlockquote(_ sender: Any?)      { applyLinePrefix("> ") }

    // MARK: - Implementation

    /// Wrap or unwrap the selected range with the given marker (e.g. `**`,
    /// `*`, `~~`, `` ` ``). Empty selection inserts the markers and parks
    /// the caret between them.
    private func toggleInlineWrap(marker: String) {
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        let markerNS = marker as NSString
        let markerLen = markerNS.length

        // Toggle-off path: selection is exactly the marker-wrapped text.
        if range.length >= markerLen * 2 {
            let inner = ns.substring(with: range)
            if inner.hasPrefix(marker) && inner.hasSuffix(marker) {
                let unwrapped = (inner as NSString).substring(with: NSRange(location: markerLen, length: (inner as NSString).length - markerLen * 2))
                replace(range: range, with: unwrapped)
                textView.setSelectedRange(NSRange(location: range.location, length: (unwrapped as NSString).length))
                return
            }
        }
        // Toggle-off path: markers immediately outside the selection.
        if range.location >= markerLen && range.location + range.length + markerLen <= ns.length {
            let before = ns.substring(with: NSRange(location: range.location - markerLen, length: markerLen))
            let after = ns.substring(with: NSRange(location: range.location + range.length, length: markerLen))
            if before == marker && after == marker {
                let inner = ns.substring(with: range)
                let outerRange = NSRange(location: range.location - markerLen, length: range.length + markerLen * 2)
                replace(range: outerRange, with: inner)
                textView.setSelectedRange(NSRange(location: outerRange.location, length: (inner as NSString).length))
                return
            }
        }

        // Wrap path.
        if range.length == 0 {
            let combined = marker + marker
            replace(range: range, with: combined)
            // Caret between the two markers.
            textView.setSelectedRange(NSRange(location: range.location + markerLen, length: 0))
        } else {
            let selected = ns.substring(with: range)
            let combined = marker + selected + marker
            replace(range: range, with: combined)
            // Re-select the formerly-selected text, now sitting between markers.
            textView.setSelectedRange(NSRange(location: range.location + markerLen, length: (selected as NSString).length))
        }
    }

    /// `[selected](url)` if there's a selection, otherwise
    /// `[text](url)` with `text` selected so the user can type the label.
    private func insertLink() {
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        if range.length == 0 {
            let template = "[text](url)"
            replace(range: range, with: template)
            // Select the `text` placeholder so typing replaces it.
            textView.setSelectedRange(NSRange(location: range.location + 1, length: 4))
        } else {
            let selected = ns.substring(with: range)
            let combined = "[\(selected)](url)"
            replace(range: range, with: combined)
            // Place the cursor inside `(url)` and select `url` so the
            // user can paste/type the destination.
            let urlOffset = range.location + (selected as NSString).length + 3
            textView.setSelectedRange(NSRange(location: urlOffset, length: 3))
        }
    }

    /// Toggle heading marker on every line touched by the selection.
    /// If a line already has exactly `level` `#`s, strip them; otherwise
    /// rewrite (replacing any existing `#…#` prefix or prepending fresh).
    private func toggleHeading(level: Int) {
        guard level >= 1, level <= 6 else { return }
        let target = String(repeating: "#", count: level)
        transformLines { line in
            let (existing, rest) = stripExistingHeading(line)
            if existing == target {
                return rest
            } else {
                return rest.isEmpty ? "\(target) " : "\(target) \(rest)"
            }
        }
    }

    private func stripExistingHeading(_ line: String) -> (markers: String, rest: String) {
        var hashes = ""
        var i = line.startIndex
        while i < line.endIndex, line[i] == "#", hashes.count < 6 {
            hashes.append("#")
            i = line.index(after: i)
        }
        if hashes.isEmpty {
            return ("", line)
        }
        // Must be followed by a space (or be alone on the line) to count
        // as a heading. `#tag` style is left alone.
        if i < line.endIndex, line[i] != " " {
            return ("", line)
        }
        if i < line.endIndex, line[i] == " " {
            i = line.index(after: i)
        }
        return (hashes, String(line[i...]))
    }

    /// Wraps the selection in a fenced code block. Empty selection
    /// inserts ```\n\n``` with the caret on the empty middle line.
    private func wrapFencedCode() {
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        // Ensure we start the fence on a fresh line.
        let prefix = (range.location > 0 && ns.character(at: range.location - 1) != UInt16(UnicodeScalar("\n").value))
            ? "\n" : ""
        if range.length == 0 {
            let body = "\(prefix)```\n\n```"
            replace(range: range, with: body)
            // Caret on the empty middle line.
            let caret = range.location + (prefix as NSString).length + 4
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            let selected = ns.substring(with: range)
            let endsWithNewline = selected.hasSuffix("\n")
            let body = endsWithNewline
                ? "\(prefix)```\n\(selected)```"
                : "\(prefix)```\n\(selected)\n```"
            replace(range: range, with: body)
            // Select the inner block (the formerly-selected text).
            let innerStart = range.location + (prefix as NSString).length + 4
            textView.setSelectedRange(NSRange(location: innerStart, length: (selected as NSString).length))
        }
    }

    /// Prefix every line touched by the selection with `prefix` (e.g.
    /// `"- "`, `"> "`). Lines already prefixed get the prefix stripped
    /// — toggle semantics.
    private func applyLinePrefix(_ prefix: String) {
        transformLines { line in
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
            return prefix + line
        }
    }

    /// Ordered list: renumber from 1 for each contiguous numbered block
    /// the user is touching. Toggling: if every selected line already
    /// matches `N. `, strip it.
    private func applyOrderedListPrefix() {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let lines = splitPreservingTrailingNewline(block)

        // Detect "every line already numbered" → toggle off.
        let allNumbered = lines.allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .newlines)
            return trimmed.isEmpty || trimmed.range(of: "^\\d+\\.\\s", options: .regularExpression) != nil
        }

        let transformed: [String]
        if allNumbered {
            transformed = lines.map { line in
                guard let match = line.range(of: "^\\d+\\.\\s", options: .regularExpression) else {
                    return line
                }
                return String(line[match.upperBound...])
            }
        } else {
            var counter = 1
            transformed = lines.map { line in
                let raw = line.replacingOccurrences(of: "\n", with: "")
                let newline = line.hasSuffix("\n") ? "\n" : ""
                if raw.isEmpty { return line }
                let result = "\(counter). \(raw)\(newline)"
                counter += 1
                return result
            }
        }

        let joined = transformed.joined()
        replace(range: lineRange, with: joined)
        // Re-select the transformed block so the user can see what changed.
        textView.setSelectedRange(NSRange(location: lineRange.location, length: (joined as NSString).length))
    }

    /// Helper for line-by-line transforms (headings, list, blockquote).
    /// Expands the selection to full lines, applies `transform` per line,
    /// writes the result back, and re-selects the transformed range.
    private func transformLines(_ transform: (String) -> String) {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let lines = splitPreservingTrailingNewline(block)
        let transformed = lines.map { line -> String in
            let raw = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let result = transform(raw)
            return line.hasSuffix("\n") ? "\(result)\n" : result
        }
        let joined = transformed.joined()
        replace(range: lineRange, with: joined)
        textView.setSelectedRange(NSRange(location: lineRange.location, length: (joined as NSString).length))
    }

    /// Splits a block into lines keeping trailing newlines on each line.
    /// `"a\nb\n"` → `["a\n", "b\n"]`; `"a\nb"` → `["a\n", "b"]`.
    private func splitPreservingTrailingNewline(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if ch == "\n" {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Wraps `textView.replaceCharacters` in the standard shouldChangeText
    /// + didChangeText dance so undo and the editor's change broadcast
    /// both see the operation.
    private func replace(range: NSRange, with replacement: String) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        currentSource = textView.string
    }
}
