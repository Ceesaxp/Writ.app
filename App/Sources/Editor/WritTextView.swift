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

    // TextKit 2's NSTextLayoutManager does not honour the legacy
    // `widthTracksTextView` flag the way TextKit 1 did — the text
    // container holds onto whatever width it was first sized with,
    // so lines wrap at that fixed width regardless of the actual
    // visible area. Bridge it manually by resizing the container
    // every time the text view's frame width changes.
    //
    // NOTE on padding: `NSTextContainer.size.width` is the layout width
    // INCLUDING the per-side `lineFragmentPadding`. The glyph layout
    // area inside is automatically reduced by the padding. So the
    // container width should equal the view width, not the view width
    // minus the padding.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let container = textContainer else { return }
        if container.size.width != newSize.width {
            container.size = NSSize(width: newSize.width, height: container.size.height)
            // TextKit 2's layout manager doesn't invalidate automatically
            // on container resize; force a re-layout so wrap takes effect.
            textLayoutManager?.invalidateLayout(for: textLayoutManager!.documentRange)
        }
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
