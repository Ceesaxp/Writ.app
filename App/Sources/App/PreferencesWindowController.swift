import Cocoa
import WritCore

/// Simple preferences window. M3 scope is intentionally narrow:
///   - Large-document byte / line thresholds
///   - Debounce intervals (normal / large)
///   - Show line numbers toggle
///
/// Values persist in UserDefaults. The large-document mode helper
/// reads them through `LargeDocumentMode.Thresholds.fromDefaults()`.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let byteField = NSTextField()
    private let lineField = NSTextField()
    private let debounceNormalField = NSTextField()
    private let debounceLargeField = NSTextField()
    private let lineNumbersCheckbox = NSButton(checkboxWithTitle: "Show line numbers", target: nil, action: nil)
    private let fontPopup = NSPopUpButton()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Writ Preferences"
        super.init(window: window)
        installContent()
        loadFromDefaults()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func installContent() {
        guard let contentView = window?.contentView else { return }
        let titleLabel = NSTextField(labelWithString: "Large-document mode kicks in when either limit is reached.")
        titleLabel.font = NSFont.systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let byteLabel = NSTextField(labelWithString: "Byte threshold:")
        let lineLabel = NSTextField(labelWithString: "Line threshold:")
        let normalLabel = NSTextField(labelWithString: "Normal debounce (ms):")
        let largeLabel = NSTextField(labelWithString: "Large debounce (ms):")

        for label in [byteLabel, lineLabel, normalLabel, largeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 13)
        }

        for field in [byteField, lineField, debounceNormalField, debounceLargeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.alignment = .right
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.bezelStyle = .roundedBezel
            field.target = self
            field.action = #selector(fieldDidCommit(_:))
        }

        lineNumbersCheckbox.translatesAutoresizingMaskIntoConstraints = false
        lineNumbersCheckbox.target = self
        lineNumbersCheckbox.action = #selector(lineNumbersToggled(_:))

        let fontLabel = NSTextField(labelWithString: "Editor font:")
        fontLabel.translatesAutoresizingMaskIntoConstraints = false
        fontLabel.font = NSFont.systemFont(ofSize: 13)

        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))
        fontPopup.addItem(withTitle: "System Monospace")
        fontPopup.lastItem?.representedObject = NSNull() // sentinel for "no override"
        for family in EditorViewController.availableFontFamilies() {
            fontPopup.addItem(withTitle: family)
            fontPopup.lastItem?.representedObject = family
        }

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded

        contentView.addSubview(titleLabel)
        contentView.addSubview(byteLabel)
        contentView.addSubview(byteField)
        contentView.addSubview(lineLabel)
        contentView.addSubview(lineField)
        contentView.addSubview(normalLabel)
        contentView.addSubview(debounceNormalField)
        contentView.addSubview(largeLabel)
        contentView.addSubview(debounceLargeField)
        contentView.addSubview(lineNumbersCheckbox)
        contentView.addSubview(fontLabel)
        contentView.addSubview(fontPopup)
        contentView.addSubview(resetButton)

        let row1Y = contentView.bottomAnchor
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            byteLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            byteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            byteLabel.widthAnchor.constraint(equalToConstant: 180),

            byteField.centerYAnchor.constraint(equalTo: byteLabel.centerYAnchor),
            byteField.leadingAnchor.constraint(equalTo: byteLabel.trailingAnchor, constant: 12),
            byteField.widthAnchor.constraint(equalToConstant: 140),

            lineLabel.topAnchor.constraint(equalTo: byteLabel.bottomAnchor, constant: 10),
            lineLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            lineLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            lineField.centerYAnchor.constraint(equalTo: lineLabel.centerYAnchor),
            lineField.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            lineField.widthAnchor.constraint(equalTo: byteField.widthAnchor),

            normalLabel.topAnchor.constraint(equalTo: lineLabel.bottomAnchor, constant: 10),
            normalLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            normalLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            debounceNormalField.centerYAnchor.constraint(equalTo: normalLabel.centerYAnchor),
            debounceNormalField.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            debounceNormalField.widthAnchor.constraint(equalTo: byteField.widthAnchor),

            largeLabel.topAnchor.constraint(equalTo: normalLabel.bottomAnchor, constant: 10),
            largeLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            largeLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            debounceLargeField.centerYAnchor.constraint(equalTo: largeLabel.centerYAnchor),
            debounceLargeField.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            debounceLargeField.widthAnchor.constraint(equalTo: byteField.widthAnchor),

            lineNumbersCheckbox.topAnchor.constraint(equalTo: largeLabel.bottomAnchor, constant: 16),
            lineNumbersCheckbox.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),

            fontLabel.topAnchor.constraint(equalTo: lineNumbersCheckbox.bottomAnchor, constant: 16),
            fontLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            fontLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            fontPopup.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            fontPopup.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            fontPopup.widthAnchor.constraint(equalToConstant: 200),

            resetButton.topAnchor.constraint(equalTo: fontLabel.bottomAnchor, constant: 16),
            resetButton.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor)
        ])
        _ = row1Y
    }

    private func loadFromDefaults() {
        let thresholds = LargeDocumentMode.Thresholds.fromDefaults()
        byteField.integerValue = thresholds.byteThreshold
        lineField.integerValue = thresholds.lineThreshold
        debounceNormalField.integerValue = Int(thresholds.debounceNormal.milliseconds)
        debounceLargeField.integerValue = Int(thresholds.debounceLarge.milliseconds)
        lineNumbersCheckbox.state = EditorViewController.lineNumbersEnabled ? .on : .off
        // Select the persisted font family if it's still in the menu,
        // otherwise fall back to "System Monospace".
        let current = EditorViewController.selectedFontFamily
        let matchIndex = fontPopup.itemArray.firstIndex {
            ($0.representedObject as? String) == current
        }
        fontPopup.selectItem(at: matchIndex ?? 0)
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        EditorViewController.selectedFontFamily = sender.selectedItem?.representedObject as? String
    }

    @objc private func fieldDidCommit(_ sender: NSTextField) {
        let thresholds = LargeDocumentMode.Thresholds(
            byteThreshold: max(1024, byteField.integerValue),
            lineThreshold: max(10, lineField.integerValue),
            debounceNormal: .milliseconds(max(50, debounceNormalField.integerValue)),
            debounceLarge: .milliseconds(max(100, debounceLargeField.integerValue))
        )
        thresholds.persist()
    }

    @objc private func lineNumbersToggled(_ sender: NSButton) {
        EditorViewController.lineNumbersEnabled = (sender.state == .on)
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        LargeDocumentMode.Thresholds.default.persist()
        EditorViewController.lineNumbersEnabled = true
        EditorViewController.selectedFontFamily = nil
        loadFromDefaults()
    }
}

// Tiny utility — Duration's components don't have a `milliseconds` getter.
private extension Duration {
    var milliseconds: Int64 {
        let secs = components.seconds * 1000
        let attoMs = components.attoseconds / 1_000_000_000_000_000
        return secs + attoMs
    }
}
