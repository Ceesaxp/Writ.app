import Cocoa

/// Custom NSView that draws line numbers down the left edge of the editor.
///
/// Sits as a sibling of the scroll view (not inside it as an `NSRulerView`)
/// because NSRulerView interacts poorly with our layout container setup.
/// Taking full control of layout and drawing sidesteps that.
///
/// The gutter:
/// - is a fixed-width view to the left of the scroll view
/// - observes the scroll view's `contentView` bounds notifications so it
///   redraws every time the text scrolls
/// - asks `NSLayoutManager` for the visible glyph range, then enumerates
///   line fragments inside it, deduplicating source lines that span
///   multiple fragments (wrapped lines) before painting the (1-indexed)
///   source-line number right-aligned in the gutter
/// - rebuilds a sparse "line starts" array on text change and keeps it
///   warm between draws so per-scroll work is O(visible fragments)
final class LineNumberGutter: NSView {
    /// Default gutter width in points; matches conventional macOS editors.
    static let defaultWidth: CGFloat = 44

    weak var textView: NSTextView?
    weak var clipView: NSClipView?

    private var lineStarts: [Int] = [0]
    private var lineStartsForLength: Int = -1

    init(textView: NSTextView, clipView: NSClipView) {
        self.textView = textView
        self.clipView = clipView
        super.init(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 100))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Programmatic loads via `textStorage.setAttributedString` (used by
        // EditorViewController.setSource) don't trigger NSText's
        // didChangeNotification — that one only fires on user input. To catch
        // *both* user edits and programmatic loads we observe the underlying
        // NSTextStorage's didProcessEditing notification, which fires for any
        // edit.
        if let storage = textView.textStorage {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textChanged(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    @objc private func textChanged(_ note: Notification) { needsDisplay = true }
    @objc private func boundsChanged(_ note: Notification) { needsDisplay = true }
    @objc private func frameChanged(_ note: Notification) { needsDisplay = true }

    override var isFlipped: Bool { true }

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

    private func lineNumber(for utf16Offset: Int) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= utf16Offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let drawStart = LatencyProbe.enabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if LatencyProbe.enabled {
                let ms = (CFAbsoluteTimeGetCurrent() - drawStart) * 1000
                LatencyProbe.log.info("gutter.draw \(ms, format: .fixed(precision: 2))ms")
            }
        }
        guard let textView,
              let clipView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        // A subtly tinted background distinguishes the gutter from the
        // editing area; the separator marks the boundary clearly.
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let separator = NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)
        NSColor.separatorColor.setFill()
        separator.fill()

        let text = textView.string
        ensureLineStarts(for: text)

        let visibleRect = clipView.documentVisibleRect
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        // 1-2pt inset puts the number's baseline on the same row as the
        // source text's first baseline for the typical 13pt monospace.
        let labelTopInset: CGFloat = 2

        // Translate textView-coordinate visibleRect into container coords
        // by subtracting the container's origin inside the textView.
        let containerOrigin = textView.textContainerOrigin
        let containerVisible = NSRect(
            x: visibleRect.minX - containerOrigin.x,
            y: visibleRect.minY - containerOrigin.y,
            width: visibleRect.width,
            height: visibleRect.height
        )
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: containerVisible,
            in: textContainer
        )

        var lastNumberedLine: Int = -1
        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { lineRect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let lineNum = self.lineNumber(for: charIndex)
            if lineNum == lastNumberedLine { return }
            lastNumberedLine = lineNum

            let label = "\(lineNum)"
            let labelSize = (label as NSString).size(withAttributes: attrs)
            // Translate from container Y to gutter-local Y (we're flipped).
            let fragmentTop = (lineRect.minY + containerOrigin.y) - visibleRect.minY
            let drawRect = NSRect(
                x: self.bounds.width - labelSize.width - 8,
                y: fragmentTop + labelTopInset,
                width: labelSize.width,
                height: labelSize.height
            )
            (label as NSString).draw(in: drawRect, withAttributes: attrs)
        }
    }
}
