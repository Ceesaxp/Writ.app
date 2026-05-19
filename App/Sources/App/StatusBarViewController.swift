import Cocoa
import WritCore

/// Compact bottom status bar — render state, word/byte counts, selection
/// position. Receives updates from `PreviewBridge` and `DocumentWindowController`.
final class StatusBarViewController: NSViewController {
    private let stateLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "Ln 1, Col 1")
    private let countsLabel = NSTextField(labelWithString: "0 bytes")

    private var lastByteCount: Int = 0
    private var lastLineCount: Int? = nil
    private var lastWordCount: Int = 0

    override func loadView() {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox()
        separator.boxType = .separator

        for label in [stateLabel, positionLabel, countsLabel] {
            label.font = NSFont.systemFont(ofSize: 10.5)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        separator.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(separator)
        host.addSubview(stateLabel)
        host.addSubview(positionLabel)
        host.addSubview(countsLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: host.topAnchor),
            separator.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            stateLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            stateLabel.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            positionLabel.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            positionLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            countsLabel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            countsLabel.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        self.view = host
    }

    func setSelection(line: Int, column: Int) {
        positionLabel.stringValue = "Ln \(line), Col \(column)"
    }

    /// Override the state label with a transient export-progress message.
    /// Pass `nil` to clear and let normal render-status updates take over again.
    private var exportStatus: String?
    func setExportStatus(_ status: String?) {
        exportStatus = status
        if let status {
            stateLabel.stringValue = status
        } else {
            stateLabel.stringValue = "Ready"
        }
    }

    func update(byteCount: Int?, lineCount: Int?, wordCount: Int? = nil, status: RenderStatus?) {
        if let byteCount {
            lastByteCount = byteCount
        }
        if let lineCount {
            lastLineCount = lineCount
        }
        if let wordCount {
            lastWordCount = wordCount
        }
        countsLabel.stringValue = formatCounts(bytes: lastByteCount, lines: lastLineCount, words: lastWordCount)
        // An export-in-progress message takes priority over the regular render
        // status until it's explicitly cleared.
        if let status, exportStatus == nil {
            stateLabel.stringValue = formatStatus(status)
        }
    }

    private func formatCounts(bytes: Int, lines: Int?, words: Int) -> String {
        let kb = Double(bytes) / 1024.0
        let bytesText: String
        if bytes < 1024 {
            bytesText = "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            bytesText = String(format: "%.1f KB", kb)
        } else {
            bytesText = String(format: "%.2f MB", kb / 1024.0)
        }
        let wordsText = words > 0 ? "\(words) words · " : ""
        if let lines {
            return "\(wordsText)\(lines) lines · \(bytesText)"
        }
        return "\(wordsText)\(bytesText)"
    }

    private func formatStatus(_ status: RenderStatus) -> String {
        switch status {
        case .idle: return "Ready"
        case .rendering(let rev): return "Rendering \(rev.description)…"
        case .current(let rev, let duration):
            return "Rendered \(rev.description) in \(formatDuration(duration))"
        case .stale(let rev): return "Stale render at \(rev.description)"
        case .failed(_, let message): return "Render error: \(message)"
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        let attos = duration.components.attoseconds
        let secs = duration.components.seconds
        let ms = Double(secs) * 1000.0 + Double(attos) / 1_000_000_000_000_000.0
        if ms < 1.0 {
            return String(format: "%.0f µs", ms * 1000.0)
        }
        return String(format: "%.0f ms", ms)
    }
}
