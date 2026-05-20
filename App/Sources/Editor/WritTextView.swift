import Cocoa

/// NSTextView subclass that paints a full-width background behind
/// fenced code-block ranges, addressing the limitation that
/// `.backgroundColor` attributes only colour the glyph bounding rect.
///
/// The editor's syntax highlighter pushes the current set of code-block
/// UTF-16 ranges via `codeBlockRanges`. On every `drawBackground(in:)`
/// — which fires before glyph rendering — we walk those ranges, find each
/// one's vertical span using `NSTextLayoutManager.enumerateTextSegments`,
/// and fill across the textView's full width.
@MainActor
final class WritTextView: NSTextView {
    /// UTF-16 ranges of code blocks. Sets the source of truth for the
    /// background painting; assigning triggers a redraw.
    var codeBlockRanges: [NSRange] = [] {
        didSet { needsDisplay = true }
    }

    /// Background colour for code-block lines. Defaults to a subtle tint.
    var codeBlockBackgroundColor: NSColor = NSColor(calibratedWhite: 0.93, alpha: 1) {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !codeBlockRanges.isEmpty,
              let textLayoutManager = textLayoutManager else { return }

        codeBlockBackgroundColor.setFill()
        let textViewWidth = bounds.width
        let containerOrigin = textContainerOrigin

        for range in codeBlockRanges {
            // Resolve UTF-16 NSRange → NSTextRange in the layout manager.
            let docStart = textLayoutManager.documentRange.location
            guard let start = textLayoutManager.location(docStart, offsetBy: range.location),
                  let end = textLayoutManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }

            // Enumerate visual segments inside the range. Each segment
            // gives us a rect in text-container coordinates. We translate
            // to textView coordinates and stretch horizontally to the
            // full editor width.
            textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, segmentFrame, _, _ in
                let viewRect = NSRect(
                    x: 0,
                    y: segmentFrame.minY + containerOrigin.y,
                    width: textViewWidth,
                    height: segmentFrame.height
                )
                if viewRect.intersects(rect) {
                    viewRect.fill()
                }
                return true
            }
        }
    }
}
