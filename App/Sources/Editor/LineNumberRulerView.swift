import Cocoa

/// A `NSRulerView` subclass that draws line numbers down the left margin of
/// the editor.
///
/// Implementation notes:
/// - The editor uses TextKit 2 (`NSTextLayoutManager`), so we walk
///   `enumerateTextLayoutFragments` rather than the old `NSLayoutManager`
///   line-fragment API.
/// - Scrollable: rebuilds the visible range on every
///   `drawHashMarksAndLabels` so it tracks the scroll position without us
///   doing manual offset math.
/// - Cheap on large documents: only enumerates fragments inside the visible
///   rect.
/// - Honors light / dark appearance through `NSColor.tertiaryLabelColor`.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0] // UTF-16 offsets where each line begins
    private var lineStartsForLength: Int = -1

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 42

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textChanged(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not implemented") }

    @objc private func textChanged(_ note: Notification) {
        needsDisplay = true
    }

    @objc private func boundsChanged(_ note: Notification) {
        needsDisplay = true
    }

    private func ensureLineStarts(for text: String) {
        if lineStartsForLength == text.utf16.count { return }
        lineStarts.removeAll(keepingCapacity: true)
        lineStarts.append(0)
        var index = 0
        for unit in text.utf16 {
            index += 1
            if unit == 0x0A { lineStarts.append(index) }
        }
        lineStartsForLength = text.utf16.count
    }

    /// Binary search: find the largest line index whose start offset ≤ target.
    private func lineNumber(for utf16Offset: Int) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= utf16Offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1 // 1-indexed
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let textLayoutManager = textView.textLayoutManager,
              let textContainer = textView.textContainer else {
            super.drawHashMarksAndLabels(in: rect)
            return
        }

        // Only fill the ruler's own bounds (capped to `ruleThickness` wide)
        // so we never paint over the text-editing area. Some earlier diagnostic
        // versions filled the full passed-in rect which, on Retina with a
        // wider dirty rect, wiped out the editor's text background.
        let fillRect = NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height).intersection(rect)
        NSColor.textBackgroundColor.setFill()
        fillRect.fill()


        // Separator line at right edge.
        let separatorRect = NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)
        NSColor.separatorColor.setFill()
        separatorRect.fill()

        let text = textView.string
        ensureLineStarts(for: text)

        let visibleRect = textView.visibleRect
        let containerOriginY = textView.textContainerOrigin.y
        _ = textContainer // silence unused warning; reserved for future text-container tweaks

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let textColor = NSColor.tertiaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        // Walk visible text layout fragments. Each fragment corresponds to a
        // line fragment (possibly a continuation of a wrapped source line).
        // We number only the first fragment per source line.
        var lastNumberedLine: Int = -1
        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.textViewportLayoutController.viewportRange?.location,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentRect = fragment.layoutFragmentFrame
            // Stop when we've moved past the visible rect.
            if fragmentRect.minY > visibleRect.maxY { return false }
            if fragmentRect.maxY < visibleRect.minY { return true }

            // The fragment's range start gives us the source character offset.
            let location = fragment.rangeInElement.location
            let offsetFromStart = textLayoutManager.offset(
                from: textLayoutManager.documentRange.location,
                to: location
            )

            let lineNum = self.lineNumber(for: offsetFromStart)
            if lineNum == lastNumberedLine { return true }
            lastNumberedLine = lineNum

            let label = "\(lineNum)"
            let labelSize = (label as NSString).size(withAttributes: attrs)
            let y = fragmentRect.minY + containerOriginY - visibleRect.minY
            let drawRect = NSRect(
                x: self.bounds.width - labelSize.width - 8,
                y: y + (fragmentRect.height - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            (label as NSString).draw(in: drawRect, withAttributes: attrs)
            return true
        }
    }
}
