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
    private let skipSpellCheckInCodeCheckbox = NSButton(checkboxWithTitle: "Skip spell check inside code (inline and fenced)", target: nil, action: nil)
    private let tocCheckbox = NSButton(checkboxWithTitle: "Include table of contents in HTML / PDF export", target: nil, action: nil)
    private let fontPopup = NSPopUpButton()
    private let paperSizePopup = NSPopUpButton()
    private let pdfFontScaleSlider = NSSlider(value: 85, minValue: 60, maxValue: 100, target: nil, action: nil)
    private let pdfFontScaleValueLabel = NSTextField(labelWithString: "85 %")
    private let previewThemePopup = NSPopUpButton()
    private let customCSSButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let customCSSLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 570),
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

        skipSpellCheckInCodeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        skipSpellCheckInCodeCheckbox.target = self
        skipSpellCheckInCodeCheckbox.action = #selector(skipSpellCheckInCodeToggled(_:))

        tocCheckbox.translatesAutoresizingMaskIntoConstraints = false
        tocCheckbox.target = self
        tocCheckbox.action = #selector(tocToggled(_:))

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

        let paperSizeLabel = NSTextField(labelWithString: "PDF page size:")
        paperSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        paperSizeLabel.font = NSFont.systemFont(ofSize: 13)

        paperSizePopup.translatesAutoresizingMaskIntoConstraints = false
        paperSizePopup.target = self
        paperSizePopup.action = #selector(paperSizeChanged(_:))
        for size in ExportService.PDFPaperSize.allCases {
            paperSizePopup.addItem(withTitle: size.displayName)
            paperSizePopup.lastItem?.representedObject = size.rawValue
        }

        let pdfFontScaleLabel = NSTextField(labelWithString: "PDF font scale:")
        pdfFontScaleLabel.translatesAutoresizingMaskIntoConstraints = false
        pdfFontScaleLabel.font = NSFont.systemFont(ofSize: 13)

        pdfFontScaleSlider.translatesAutoresizingMaskIntoConstraints = false
        pdfFontScaleSlider.isContinuous = true
        pdfFontScaleSlider.numberOfTickMarks = 9   // 60, 65, 70, …, 100
        pdfFontScaleSlider.allowsTickMarkValuesOnly = true
        pdfFontScaleSlider.tickMarkPosition = .below
        pdfFontScaleSlider.target = self
        pdfFontScaleSlider.action = #selector(pdfFontScaleChanged(_:))

        pdfFontScaleValueLabel.translatesAutoresizingMaskIntoConstraints = false
        pdfFontScaleValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pdfFontScaleValueLabel.textColor = .secondaryLabelColor
        pdfFontScaleValueLabel.alignment = .right

        let previewThemeLabel = NSTextField(labelWithString: "Preview theme:")
        previewThemeLabel.translatesAutoresizingMaskIntoConstraints = false
        previewThemeLabel.font = NSFont.systemFont(ofSize: 13)

        previewThemePopup.translatesAutoresizingMaskIntoConstraints = false
        previewThemePopup.target = self
        previewThemePopup.action = #selector(previewThemeChanged(_:))
        for theme in PreviewTheme.allCases {
            previewThemePopup.addItem(withTitle: theme.displayName)
            previewThemePopup.lastItem?.representedObject = theme.rawValue
        }

        let customCSSHeading = NSTextField(labelWithString: "Custom preview CSS:")
        customCSSHeading.translatesAutoresizingMaskIntoConstraints = false
        customCSSHeading.font = NSFont.systemFont(ofSize: 13)

        customCSSButton.translatesAutoresizingMaskIntoConstraints = false
        customCSSButton.target = self
        customCSSButton.action = #selector(chooseCustomCSS(_:))
        customCSSButton.bezelStyle = .rounded

        customCSSLabel.translatesAutoresizingMaskIntoConstraints = false
        customCSSLabel.font = NSFont.systemFont(ofSize: 11)
        customCSSLabel.textColor = .secondaryLabelColor
        customCSSLabel.lineBreakMode = .byTruncatingMiddle
        customCSSLabel.maximumNumberOfLines = 1

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
        contentView.addSubview(skipSpellCheckInCodeCheckbox)
        contentView.addSubview(tocCheckbox)
        contentView.addSubview(fontLabel)
        contentView.addSubview(fontPopup)
        contentView.addSubview(paperSizeLabel)
        contentView.addSubview(paperSizePopup)
        contentView.addSubview(pdfFontScaleLabel)
        contentView.addSubview(pdfFontScaleSlider)
        contentView.addSubview(pdfFontScaleValueLabel)
        contentView.addSubview(previewThemeLabel)
        contentView.addSubview(previewThemePopup)
        contentView.addSubview(customCSSHeading)
        contentView.addSubview(customCSSButton)
        contentView.addSubview(customCSSLabel)
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

            skipSpellCheckInCodeCheckbox.topAnchor.constraint(equalTo: lineNumbersCheckbox.bottomAnchor, constant: 6),
            skipSpellCheckInCodeCheckbox.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),

            tocCheckbox.topAnchor.constraint(equalTo: skipSpellCheckInCodeCheckbox.bottomAnchor, constant: 6),
            tocCheckbox.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),

            fontLabel.topAnchor.constraint(equalTo: tocCheckbox.bottomAnchor, constant: 16),
            fontLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            fontLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            fontPopup.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            fontPopup.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            fontPopup.widthAnchor.constraint(equalToConstant: 200),

            paperSizeLabel.topAnchor.constraint(equalTo: fontLabel.bottomAnchor, constant: 10),
            paperSizeLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            paperSizeLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            paperSizePopup.centerYAnchor.constraint(equalTo: paperSizeLabel.centerYAnchor),
            paperSizePopup.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            paperSizePopup.widthAnchor.constraint(equalToConstant: 220),

            pdfFontScaleLabel.topAnchor.constraint(equalTo: paperSizeLabel.bottomAnchor, constant: 14),
            pdfFontScaleLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            pdfFontScaleLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            pdfFontScaleSlider.centerYAnchor.constraint(equalTo: pdfFontScaleLabel.centerYAnchor),
            pdfFontScaleSlider.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            pdfFontScaleSlider.widthAnchor.constraint(equalToConstant: 170),

            pdfFontScaleValueLabel.centerYAnchor.constraint(equalTo: pdfFontScaleLabel.centerYAnchor),
            pdfFontScaleValueLabel.leadingAnchor.constraint(equalTo: pdfFontScaleSlider.trailingAnchor, constant: 8),
            pdfFontScaleValueLabel.widthAnchor.constraint(equalToConstant: 48),

            previewThemeLabel.topAnchor.constraint(equalTo: pdfFontScaleLabel.bottomAnchor, constant: 14),
            previewThemeLabel.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            previewThemeLabel.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            previewThemePopup.centerYAnchor.constraint(equalTo: previewThemeLabel.centerYAnchor),
            previewThemePopup.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            previewThemePopup.widthAnchor.constraint(equalToConstant: 220),

            customCSSHeading.topAnchor.constraint(equalTo: previewThemeLabel.bottomAnchor, constant: 12),
            customCSSHeading.leadingAnchor.constraint(equalTo: byteLabel.leadingAnchor),
            customCSSHeading.widthAnchor.constraint(equalTo: byteLabel.widthAnchor),

            customCSSButton.centerYAnchor.constraint(equalTo: customCSSHeading.centerYAnchor),
            customCSSButton.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),

            customCSSLabel.topAnchor.constraint(equalTo: customCSSButton.bottomAnchor, constant: 4),
            customCSSLabel.leadingAnchor.constraint(equalTo: byteField.leadingAnchor),
            customCSSLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            resetButton.topAnchor.constraint(equalTo: customCSSLabel.bottomAnchor, constant: 16),
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
        skipSpellCheckInCodeCheckbox.state = EditorViewController.skipSpellCheckInCodeEnabled ? .on : .off
        tocCheckbox.state = ExportService.includeTOC ? .on : .off
        // Select the persisted font family if it's still in the menu,
        // otherwise fall back to "System Monospace".
        let current = EditorViewController.selectedFontFamily
        let matchIndex = fontPopup.itemArray.firstIndex {
            ($0.representedObject as? String) == current
        }
        fontPopup.selectItem(at: matchIndex ?? 0)

        let paperRaw = ExportService.pdfPaperSize.rawValue
        let paperMatch = paperSizePopup.itemArray.firstIndex {
            ($0.representedObject as? String) == paperRaw
        }
        paperSizePopup.selectItem(at: paperMatch ?? 0)

        let scale = ExportService.pdfFontScalePercent
        pdfFontScaleSlider.integerValue = scale
        pdfFontScaleValueLabel.stringValue = "\(scale) %"

        let currentTheme = PreviewAppearance.theme.rawValue
        let themeMatch = previewThemePopup.itemArray.firstIndex {
            ($0.representedObject as? String) == currentTheme
        }
        previewThemePopup.selectItem(at: themeMatch ?? 0)

        if let url = PreviewAppearance.customCSSURL {
            customCSSLabel.stringValue = url.lastPathComponent
            customCSSButton.title = "Clear"
        } else {
            customCSSLabel.stringValue = "(none — uses the theme as-is)"
            customCSSButton.title = "Choose…"
        }
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        EditorViewController.selectedFontFamily = sender.selectedItem?.representedObject as? String
    }

    @objc private func paperSizeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let size = ExportService.PDFPaperSize(rawValue: raw) else { return }
        ExportService.pdfPaperSize = size
    }

    @objc private func pdfFontScaleChanged(_ sender: NSSlider) {
        let value = sender.integerValue
        ExportService.pdfFontScalePercent = value
        pdfFontScaleValueLabel.stringValue = "\(value) %"
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

    @objc private func skipSpellCheckInCodeToggled(_ sender: NSButton) {
        EditorViewController.skipSpellCheckInCodeEnabled = (sender.state == .on)
    }

    @objc private func tocToggled(_ sender: NSButton) {
        ExportService.includeTOC = (sender.state == .on)
    }

    @objc private func previewThemeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let theme = PreviewTheme(rawValue: raw) else { return }
        PreviewAppearance.theme = theme
    }

    @objc private func chooseCustomCSS(_ sender: NSButton) {
        if PreviewAppearance.customCSSURL != nil {
            // Clear-on-second-press behavior — the button label flips
            // to "Clear" in `loadFromDefaults` when a CSS is set.
            PreviewAppearance.setCustomCSSURL(nil)
            loadFromDefaults()
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "css")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a CSS file to overlay on the active preview theme."
        if panel.runModal() == .OK, let url = panel.url {
            PreviewAppearance.setCustomCSSURL(url)
            loadFromDefaults()
        }
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        LargeDocumentMode.Thresholds.default.persist()
        EditorViewController.lineNumbersEnabled = true
        EditorViewController.skipSpellCheckInCodeEnabled = false
        EditorViewController.selectedFontFamily = nil
        ExportService.includeTOC = false
        ExportService.pdfPaperSize = .usLetter
        ExportService.pdfFontScalePercent = ExportService.pdfFontScalePercentDefault
        PreviewAppearance.theme = .github
        PreviewAppearance.setCustomCSSURL(nil)
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
