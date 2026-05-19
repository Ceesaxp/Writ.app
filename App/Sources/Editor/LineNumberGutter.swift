import Cocoa

/// Custom NSView that draws line numbers down the left edge of the editor.
///
/// Sits as a sibling of the scroll view (not inside it as an `NSRulerView`)
/// because NSRulerView + TextKit 2 has a layout/visibility issue on macOS 15
/// where the ruler attaches at the correct thickness but is not visually
/// rendered. By taking full control of layout and drawing we sidestep the
/// problem entirely.
///
/// The gutter:
/// - is a fixed-width view to the left of the scroll view
/// - observes the scroll view's `contentView` bounds notifications so it
///   redraws every time the text scrolls
/// - walks `NSTextLayoutManager.enumerateTextLayoutFragments(...)` to find
///   visible line fragments, translates each fragment's Y from text-
///   container space into gutter-local space, and paints the (1-indexed)
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
        guard let textView,
              let clipView,
              let textLayoutManager = textView.textLayoutManager else {
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
        // Align the label vertically with the first visual line in the
        // layout fragment, not the centre of the whole (possibly wrapped)
        // block. Empirically a 1-2pt inset from the fragment top puts the
        // number's baseline on the same row as the source text's first
        // baseline for the typical 13pt monospace editor font.
        let labelTopInset: CGFloat = 2

        var lastNumberedLine: Int = -1
        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.textViewportLayoutController.viewportRange?.location,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentRect = fragment.layoutFragmentFrame
            if fragmentRect.maxY < visibleRect.minY { return true }
            if fragmentRect.minY > visibleRect.maxY { return false }

            let location = fragment.rangeInElement.location
            let offset = textLayoutManager.offset(
                from: textLayoutManager.documentRange.location,
                to: location
            )
            let lineNum = self.lineNumber(for: offset)
            if lineNum == lastNumberedLine { return true }
            lastNumberedLine = lineNum

            let label = "\(lineNum)"
            let labelSize = (label as NSString).size(withAttributes: attrs)
            // Translate fragment Y (text-container space, flipped) to gutter
            // local space. We're flipped already.
            let containerInset = textView.textContainerOrigin.y
            let fragmentTop = (fragmentRect.minY + containerInset) - visibleRect.minY
            let drawRect = NSRect(
                x: bounds.width - labelSize.width - 8,
                y: fragmentTop + labelTopInset,
                width: labelSize.width,
                height: labelSize.height
            )
            (label as NSString).draw(in: drawRect, withAttributes: attrs)
            return true
        }
    }
}
