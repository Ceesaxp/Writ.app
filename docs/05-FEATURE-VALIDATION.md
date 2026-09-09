# Writ Feature Validation Plan

This document is the test and validation map for Writ's declared MVP and current post-MVP capabilities. It is based on the product documentation in `README.md`, `TODO.md`, `docs/00-PRD-Final.md`, `docs/01-MVP-PLAN.md`, `docs/02-TECHNICAL-DESIGN.md`, `docs/03-M0-DECISIONS.md`, `docs/04-M1-PERF-GATE.md`, plus the current application and package source.

Use this as the release checklist before shipping a build. It intentionally distinguishes shipped behavior from deferred scope so QA does not validate features that are not implemented.

## Validation Commands

Run these first for package-level coverage:

```sh
swift test --package-path Packages/WritCore
swift test --package-path Packages/WritParser
swift test --package-path Packages/WritRender
```

Run benchmark fixtures when performance claims are being validated:

```sh
swift run --package-path Benchmarks writ-fixtures
swift run --package-path Benchmarks writ-bench
```

Build the app before manual validation:

```sh
xcodebuild -project Writ.xcodeproj -scheme Writ -configuration Debug build
```

Manual preview coverage should start with:

```sh
open -a Writ samples/preview-smoke/preview-smoke.md
```

Then execute `samples/preview-smoke/CHECKLIST.md`.

## Validation Status Legend

| Status | Meaning |
| --- | --- |
| Automated | Covered by Swift package tests or deterministic benchmark tooling. |
| Manual | Requires app UI, WebKit rendering, macOS document behavior, or visual inspection. |
| Hybrid | Has automated lower-level coverage and manual app-level confirmation. |
| Deferred | Declared as post-MVP or not implemented; validate only as a non-crashing placeholder. |

## Feature Traceability Matrix

| ID | Capability | Status | Primary implementation | Existing coverage |
| --- | --- | --- | --- | --- |
| DOC-01 | Native document app for `.md`, `.markdown`, `.txt` | Hybrid | `App/Sources/Documents/WritDocument.swift`, `App/Info.plist` | Manual open/save; text decoding tests |
| DOC-02 | BOM-aware UTF-8 read, CP1252/Latin-1 fallback, UTF-8 write | Automated | `Packages/WritCore/Sources/WritCore/TextDecoder.swift`, `WritDocument.swift` | `TextDecoderTests` |
| DOC-03 | Autosave, drafts, undo/redo integration | Hybrid | `WritDocument.swift`, `EditorViewController.swift` | `UndoRedoPatternTests`; manual document workflow |
| DOC-04 | External file-change detection with unsaved-edits warning | Manual | `WritDocument.presentedItemDidChange` | Manual |
| EDIT-01 | AppKit/TextKit editor, plain-text canonical source | Manual | `EditorViewController.swift`, `WritTextView.swift` | Manual large-document and editing checks |
| EDIT-02 | AST-driven Markdown syntax highlighting | Hybrid | `MarkdownSyntaxHighlighter.swift`, `SyntaxSpans.swift` | `ParserTests.spans*`; manual visual check |
| EDIT-03 | Full-width fenced-code background tint | Manual | `WritTextView.swift`, `MarkdownSyntaxHighlighter.swift` | Manual code-block visual check |
| EDIT-04 | Optional line numbers, persisted setting | Manual | `LineNumberGutter.swift`, `EditorViewController.swift`, `PreferencesWindowController.swift` | Manual toggle and persistence |
| EDIT-05 | Auto-pair brackets, quotes, markers, dollars | Manual | `EditorViewController.handleAutoPair` | Manual |
| EDIT-06 | Insert code/math/Mermaid blocks | Hybrid | `BlockTemplate.swift`, `EditorViewController.swift`, `DocumentWindowController.swift` | `BlockTemplateTests`; manual menu shortcuts |
| EDIT-07 | Markdown formatting commands | Manual | `EditorFormatting.swift`, `AppMenu.swift` | Manual |
| EDIT-08 | Find and replace, including 5 MB stress | Manual | AppKit `NSTextFinder` config in `EditorViewController.swift` | `samples/preview-smoke/CHECKLIST.md` |
| VIEW-01 | Source-only, preview-only, split modes | Manual | `DocumentWindowController.swift`, `AppMenu.swift` | Manual layout switching |
| VIEW-02 | Outline/heading navigation pane | Hybrid | `OutlineSidebarController.swift`, `Outline.swift`, `HeadingSlug.swift` | Parser outline tests indirectly; manual sidebar |
| VIEW-03 | Status bar with counts, selection, render state, export state | Manual | `StatusBarViewController.swift`, `DocumentWindowController.swift`, `PreviewBridge.swift` | Manual |
| PREV-01 | Persistent `WKWebView` shell, JS bridge updates | Manual | `PreviewViewController.swift`, `PreviewBridge.swift`, `Resources/preview/writ.js` | Manual app workflow |
| PREV-02 | Debounced preview, force refresh, stale-result rejection | Automated | `PreviewScheduler.swift` | `RenderTests.debounce`, `manualRefresh*` |
| PREV-03 | Block-aware two-way scroll sync | Manual | `DocumentWindowController.swift`, `EditorViewController.swift`, `writ.js` | Manual |
| MD-01 | CommonMark/GFM headings, emphasis, lists, blockquotes, rules, links | Hybrid | `SwiftMarkdownParser`, `HTMLEmitter.swift` | `ParserTests`; smoke checklist |
| MD-02 | GFM task lists | Automated | `HTMLEmitter.emitListItem` | `ParserTests.taskList` |
| MD-03 | GFM tables with alignment | Automated | `HTMLEmitter.emitTable` | `ParserTests.tables`, `tableAlignment` |
| MD-04 | GFM strikethrough and autolinks | Hybrid | `swift-markdown` AST, `HTMLEmitter.swift` | `ParserTests.strikethrough`; smoke checklist |
| MD-05 | GFM alert blocks | Automated | `GFMAlert.swift`, `HTMLEmitter.emitAlert` | `ParserTests.gfmAlert*` |
| MD-06 | YAML/TOML front matter extraction and rendering | Automated | `FrontMatter.swift`, `HTMLEmitter.emitFrontMatter` | `ParserTests.frontMatter*` |
| TECH-01 | Inline `\$...\$` math and block `\$$...\$$` math | Hybrid | `MathPreprocessor.swift`, `writ.js` | `ParserTests.blockMath`, `inlineMath`, smoke checklist |
| TECH-02 | Fenced ```math blocks | Hybrid | `HTMLEmitter.swift`, `writ.js` | `ParserTests.mathFence`; smoke checklist |
| TECH-03 | KaTeX default renderer, MathJax runtime alternate | Manual | `Resources/preview/index.html`, `writ.js`, `PreviewViewController.setMathRenderer` | Manual renderer switch via JS/benchmark |
| TECH-04 | Mermaid fenced rendering offline | Manual | `HTMLEmitter.swift`, bundled Mermaid, `writ.js` | Smoke checklist |
| TECH-05 | PlantUML fenced block recognition with notice | Hybrid | `HTMLEmitter.swift` | `ParserTests.plantumlFence`; smoke checklist |
| TECH-06 | Preview code highlighting and language chip | Manual | `HTMLEmitter.swift`, `writ.js`, `theme.css` | Smoke checklist |
| MEDIA-01 | Relative local images/SVG through `writ-doc://` | Manual | `WritDocSchemeHandler.swift`, `writ.js` | Smoke checklist |
| MEDIA-02 | Missing image placeholder and diagnostics ribbon | Manual | `writ.js`, `theme.css` | Smoke checklist |
| SEC-01 | Raw HTML sanitization strips dangerous tags/attributes/URLs | Automated | `HTMLSanitizer.swift` | `ParserTests.sanitizer*` |
| SEC-02 | Sanitized inline SVG primitives allowed; unsafe SVG vectors stripped | Automated | `HTMLSanitizer.swift` | `ParserTests.sanitizerSVG*` |
| SEC-03 | External navigation scheme guard | Manual | `PreviewNavigationHelper` | Smoke checklist |
| EXP-01 | HTML export captures live rendered DOM with bundled CSS | Hybrid | `ExportService.swift`, `HTMLExporter.swift` | `ExporterTests`; manual exported file inspection |
| EXP-02 | PDF export through WebKit print pipeline with fallback | Manual | `PreviewViewController.exportPDF`, `ExportService.swift` | Manual |
| EXP-03 | Optional export TOC for HTML/PDF | Hybrid | `TOCBuilder.swift`, `ExportService.swift`, `PreviewViewController.swift` | `ExporterTests.toc*`; manual setting/export |
| FOLDER-01 | Open Folder window with Markdown tree/list | Manual | `FolderWindowController.swift`, `FolderNode.swift` | Manual |
| FOLDER-02 | Quick-open filtering and Return opens top hit | Manual | `FolderWindowController.swift` | Manual |
| FOLDER-03 | Folder file-system watching with debounce | Manual | `FolderWatcher.swift`, `FolderWindowController.swift` | Manual |
| PREF-01 | Large-doc thresholds and debounce preferences | Manual | `PreferencesWindowController.swift`, `LargeDocumentMode.swift` | Manual persistence; core threshold tests |
| PREF-02 | Editor font picker | Manual | `PreferencesWindowController.swift`, `EditorViewController.swift` | Manual |
| PERF-01 | 10 KB preview update under 500 ms after debounce | Hybrid | `PreviewScheduler`, parser/render packages | `docs/04-M1-PERF-GATE.md`; benchmark |
| PERF-02 | 1 MB open/edit and 5 MB responsive editing | Manual | editor, scheduler, large-doc mode | benchmark plus smoke large-doc stress |
| OFFLINE-01 | No accounts, telemetry, or remote rendering by default | Manual/source audit | app source and bundled resources | Manual/source audit |

## Core Document Workflow

### DOC-01: File Type Handling

Steps:

1. Create one document each with `.md`, `.markdown`, and `.txt`.
2. Open each through File > Open.
3. Edit content, save, close, reopen.

Expected:

- Files open in Writ as plain text.
- Saved content matches source bytes semantically.
- The editor remains the canonical source; preview/export artifacts are not written back into the document.

### DOC-02: Text Decoding And Encoding

Automated:

- Run `swift test --package-path Packages/WritCore`.
- Confirm `TextDecoderTests` pass for plain UTF-8, UTF-8 BOM, Windows-1252 fallback, and UTF-8 output without unwanted BOM.

Manual supplement:

1. Open a CP1252 file containing smart quotes or accented characters.
2. Save as Markdown.
3. Reopen and confirm characters survive.

### DOC-03: Autosave, Drafts, Undo, Redo

Automated:

- Confirm `UndoRedoPatternTests` pass: single edit, multi-step undo/redo, branch invalidating redo, identical text no-op.

Manual:

1. Type multiple edits in a document.
2. Use Edit > Undo and Edit > Redo.
3. Save, close, reopen.

Expected:

- Undo/redo restores exact source states.
- The preview follows the restored source.
- Standard macOS dirty-state and save behavior is preserved.

### DOC-04: External File Changes

Steps:

1. Open a saved Markdown file in Writ.
2. Modify it externally using another editor.
3. Return to Writ.
4. Repeat once with no unsaved Writ edits and once with unsaved Writ edits.

Expected:

- Writ shows a reload prompt.
- Unsaved Writ edits trigger a warning that reload loses local edits.
- Choosing reload updates editor and preview.
- Choosing keep/ignore preserves current editor state.

## Editor Validation

### EDIT-01: Native Editing Surface And Large Text

Steps:

1. Open normal and large fixtures.
2. Type, select, copy/paste, scroll, page up/down, and resize the window.
3. Confirm horizontal scrolling does not appear for normal prose.

Expected:

- Typing and scrolling are responsive.
- Text wraps to the editor width.
- Selection, insertion point, spell checking, and system accent color behave like AppKit text editing.

### EDIT-02: Syntax Highlighting

Use a document containing headings, emphasis, links, images, task lists, table separators, math, code fences, HTML, and front matter.

Expected:

- Each syntax class receives a distinct style.
- Highlighting does not move selection or pollute undo history.
- Documents over the highlighter byte threshold remain editable even if rich highlighting is reduced.

Automated anchors:

- `ParserTests.spans`
- `ParserTests.spansLineLevel`
- `ParserTests.frontMatterSyntaxSpan`

### EDIT-03: Fenced Code Background

Steps:

1. Add a multi-line fenced code block.
2. Scroll through it.
3. Resize the editor.

Expected:

- Every code-block visual line has a full-width background tint.
- Tint tracks wrapped code lines and does not bleed into neighboring paragraphs.

### EDIT-04: Line Numbers

Steps:

1. Toggle View > Show Line Numbers (`Option-Command-L`).
2. Open Settings and toggle the line-number preference.
3. Reopen the app.

Expected:

- Gutter appears/disappears without layout corruption.
- Wrapped lines do not produce extra line numbers.
- Preference persists.

### EDIT-05: Auto-Pairing

Cases:

| Input | Expected |
| --- | --- |
| `(`, `[`, `{`, `"`, `*`, `_`, `` ` ``, `$` at collapsed cursor | Closing pair inserted and cursor placed between. |
| Type opener around selected text | Selection is wrapped and remains selected inside delimiters. |
| Type `'` after a letter | Apostrophe inserts normally for contractions. |
| Type opener before identical closer | Does not duplicate closer. |

### EDIT-06: Insert Block Templates

Automated:

- `BlockTemplateTests` validate code/math/Mermaid template shape and insertion positions.

Manual:

1. Use Insert > Code Block (`Option-Command-K`).
2. Use Insert > Math Block (`Option-Command-M`).
3. Use Insert > Mermaid Diagram (`Option-Command-D`).

Expected:

- The right fenced block is inserted.
- Cursor selection lands in the placeholder region.
- Preview updates and renders when source is completed.

### EDIT-07: Markdown Formatting Commands

Steps:

1. Select text and use Format > Bold, Italic, Strikethrough, Inline Code, Link, Heading 1-6, Code Block, Ordered List, Unordered List, Block Quote.
2. Repeat on an empty selection where applicable.

Expected:

- Commands modify Markdown source, not rich text.
- Undo restores the previous source.
- Preview reflects the formatted Markdown.

### EDIT-08: Find And Replace

Run the "Large-document stress" section in `samples/preview-smoke/CHECKLIST.md`.

Expected:

- Find bar opens with `Command-F`.
- Find next/previous respond.
- Replace UI opens with `Option-Command-F`.
- 5 MB fixture remains responsive during search and replacement.

## View And Navigation

### VIEW-01: Layout Modes

Steps:

1. Use View > Source Only (`Option-Command-1`).
2. Use View > Preview Only (`Option-Command-2`).
3. Use View > Source & Preview (`Option-Command-3`).
4. Use the toolbar segmented control.

Expected:

- Source and preview panes collapse/restore correctly.
- Split mode gives both editor and preview usable width.
- The outline pane state is independent of source/preview mode.

### VIEW-02: Outline Sidebar

Steps:

1. Open a document with nested headings.
2. Toggle View > Show Outline (`Option-Command-0`).
3. Click headings at different depths.
4. Edit headings while outline is visible.

Expected:

- Sidebar lists headings in document order with levels.
- Selecting a heading scrolls editor and preview to the source line.
- The menu title changes between Show Outline and Hide Outline.
- Outline refreshes when source changes.

### VIEW-03: Status Bar

Steps:

1. Type content and move the cursor.
2. Trigger preview rendering.
3. Export HTML/PDF.

Expected:

- Byte, line, word, line/column, render, and export status update without modal interruption.
- Failed render state is visible if parser/render errors occur.

## Preview Pipeline

### PREV-01: Persistent Preview Shell

Steps:

1. Open a document in split mode.
2. Edit several times.
3. Reload the WebView through `Command-R` or context reload if available.

Expected:

- Preview shell loads once per document.
- Later updates go through `window.Writ.update(...)`.
- After WebView reload or WebContent crash, the latest payload is replayed.

### PREV-02: Debounce, Manual Refresh, Stale Rejection

Automated:

- `RenderTests.debounce`
- `RenderTests.manualRefreshBumpsRevision`
- `RenderTests.manualRefreshOverridesDebounce`

Manual:

1. Type rapidly in a document.
2. Press View > Refresh Preview (`Command-R`) while a debounced update is pending.

Expected:

- Preview coalesces rapid edits.
- Manual refresh bypasses debounce.
- Older render output never replaces newer source.

### PREV-03: Two-Way Scroll Sync

Steps:

1. Open `samples/preview-smoke/preview-smoke.md` in split mode.
2. Scroll editor from top to lower sections.
3. Scroll preview back upward.

Expected:

- Preview tracks editor by nearest source block.
- Editor tracks preview by source line.
- No visible ping-pong or oscillation.

## Markdown And Technical Rendering

### MD-01 To MD-06: Markdown Core

Use `samples/preview-smoke/preview-smoke.md` sections 1-7, 16, and 19.

Expected:

- Headings, paragraphs, breaks, emphasis, lists, nested blockquotes, rules, tables, code fences, task lists, links, front matter, and GFM alerts render correctly.
- Ordered-list start values are preserved.
- Table alignment markers produce left/center/right alignment.
- Raw Markdown source remains unchanged by rendering.

Automated anchors:

- `ParserTests.heading`
- `ParserTests.codeFence`
- `ParserTests.taskList`
- `ParserTests.strikethrough`
- `ParserTests.tables`
- `ParserTests.tableAlignment`
- `ParserTests.gfmAlert*`
- `ParserTests.frontMatter*`

### TECH-01: Inline And Display Math

Automated:

- `ParserTests.blockMath`
- `ParserTests.inlineMath`
- `ParserTests.currencySafe`
- `ParserTests.escapedDollar`
- `ParserTests.inlineSingleLine`
- `ParserTests.blockSpansLines`
- `ParserTests.dollarBlock`

Manual:

1. Validate smoke checklist sections 8 and 9.
2. Confirm escaped currency stays text.
3. Confirm invalid math creates a visible inline error, not an app crash.

Expected:

- Inline math is rendered inline.
- Display math is centered.
- Escaped dollars and normal currency are not consumed as math.
- Errors surface in the preview and diagnostics ribbon when applicable.

### TECH-02: Fenced Math Blocks

Steps:

1. Insert or type a fenced ```math block.
2. Add a multi-line expression.

Expected:

- Parser extracts a technical math block.
- Preview renders it through the active math renderer.
- Export captures rendered output.

### TECH-03: KaTeX And MathJax

Steps:

1. Render a math-heavy document with the default renderer.
2. Switch renderer with `window.Writ.setMathRenderer('mathjax')` from Web Inspector or benchmark mode.
3. Switch back to `katex`.

Expected:

- KaTeX is default.
- MathJax can render supported expressions when selected.
- Renderer cache is cleared on switch.

### TECH-04: Mermaid

Steps:

1. Validate smoke checklist sections 10-12.
2. Add an invalid Mermaid block.

Expected:

- Valid diagrams render as SVG offline.
- Invalid diagrams show inline Mermaid error and diagnostics ribbon.
- Editor remains responsive while diagrams render.

### TECH-05: PlantUML Recognition

Automated:

- `ParserTests.plantumlFence`

Manual:

1. Validate smoke checklist section 13.

Expected:

- Fenced `plantuml` block is recognized.
- A non-blocking "PlantUML rendering is not configured" notice appears.
- Raw PlantUML source remains visible.
- No local PlantUML rendering is attempted in MVP.

### TECH-06: Code Highlighting

Steps:

1. Validate smoke checklist section 7.
2. Export HTML and inspect code blocks.

Expected:

- Language-tagged code blocks are highlighted by bundled highlight.js.
- Plain fences remain monospaced but unhighlighted.
- Language chip appears for recognized language tags.
- Code text is preserved exactly.

## Media, Security, And Navigation

### MEDIA-01: Local Images And SVG References

Steps:

1. Validate smoke checklist section 14.
2. Move the Markdown file and assets together into another folder and reopen.

Expected:

- Relative images resolve through `writ-doc://`.
- PNG/JPG/SVG render without granting broad file access.
- Missing files are replaced by readable placeholders.

### MEDIA-02: Diagnostics Ribbon

Steps:

1. Add one invalid Mermaid block, one invalid math expression, and one missing image.
2. Click the diagnostics ribbon.

Expected:

- Ribbon counts render issues.
- Clicking it scrolls to the first issue.
- Fixing the source removes the ribbon on the next render.

### SEC-01: HTML Sanitization

Automated:

- `ParserTests.sanitizer`
- `ParserTests.sanitizerSafe`
- `ParserTests.sanitizerSVGNesting`
- `ParserTests.sanitizerSafeSVG`
- `ParserTests.sanitizerXlinkHref`
- `ParserTests.sanitizerDataURLs`

Manual:

1. Validate smoke checklist sections 15 and 17.
2. Include `<script>`, `onerror=`, `javascript:`, `vbscript:`, dangerous SVG animation/use/image/foreignObject tags, and safe SVG primitives.

Expected:

- Dangerous script vectors are stripped or neutralized.
- Safe raw HTML and safe SVG primitives still render.
- No alert dialogs, external app launches, or network calls are triggered by sanitized content.

### SEC-02: Link Navigation Guard

Steps:

1. Click `http`, `https`, and `mailto` links.
2. Click a `file:` link.
3. Click an unknown custom scheme such as `someapp://foo`.

Expected:

- HTTP(S)/mailto hand off to the OS.
- File links require user confirmation.
- Unknown custom schemes are blocked.

## Export Validation

### EXP-01: HTML Export

Automated:

- `ExporterTests.basicRender`
- `ExporterTests.emptyRender`
- `ExporterTests.technicalBlocks`
- `ExporterTests.tocPrepended`
- `ExporterTests.tocAnchorsResolve`
- `ExporterTests.tocOptional`

Manual:

1. Open the smoke fixture.
2. Wait for preview to finish rendering.
3. Use File > Export HTML (`Shift-Command-E`).
4. Open the exported HTML in a browser.

Expected:

- Export includes rendered math and Mermaid, not placeholders.
- Theme, KaTeX, highlight.js, and TOC CSS are inlined.
- Relative/local media that can be represented in the exported context renders or fails visibly.
- Optional TOC appears only when enabled.

### EXP-02: PDF Export

Steps:

1. Open the smoke fixture.
2. Use File > Export PDF (`Shift-Command-P`).
3. Inspect the PDF in Preview.app.
4. Repeat with TOC enabled and disabled.

Expected:

- PDF is paginated on the selected paper size.
- Math, Mermaid, code highlighting, typography, images, and TOC survive export.
- Export status updates and clears.
- If WebKit print output is blank/tiny, fallback PDF generation writes readable content.

### EXP-03: Export TOC

Steps:

1. Enable Include TOC in Settings.
2. Export HTML and PDF.
3. Disable Include TOC and export again.

Expected:

- TOC anchors resolve to emitted heading IDs.
- PDF export injects TOC temporarily and removes it from live preview after printing.
- Disabled setting omits the TOC.

## Folder Workflow

### FOLDER-01: Open Folder

Steps:

1. Use File > Open Folder (`Shift-Command-O`) on a folder with nested Markdown files.
2. Expand/collapse directories.
3. Double-click files.

Expected:

- Folder window lists Markdown-relevant files recursively.
- Directories expand/collapse.
- File open uses standard document handling.

### FOLDER-02: Quick Open Filter

Steps:

1. Type a filename fragment in the folder search field.
2. Press Return.

Expected:

- List filters live.
- Return opens the first matching file.
- Clearing search restores tree/list state.

### FOLDER-03: File-System Watching

Steps:

1. With a folder window open, add, rename, modify, and delete Markdown files from Terminal or Finder.
2. Perform several changes rapidly.

Expected:

- Folder window refreshes after a short debounce.
- Expansion state is preserved where possible.
- App remains responsive.

## Preferences

### PREF-01: Large-Document Thresholds And Debounce

Steps:

1. Open Settings (`Command-,`).
2. Change byte threshold, line threshold, normal debounce, and large debounce.
3. Reopen Settings and relaunch app.
4. Open small and large documents.

Expected:

- Values persist in `UserDefaults`.
- Small documents use normal debounce.
- Large documents use large debounce/reduced highlighter behavior.

Automated anchors:

- `DocumentSnapshotTests.smallNotLarge`
- `DocumentSnapshotTests.byteThreshold`
- `DocumentSnapshotTests.lineThreshold`
- `RenderTests.debounce`

### PREF-02: Editor Font Picker

Steps:

1. Open Settings.
2. Choose each installed font family offered.
3. Observe already-open editor windows.

Expected:

- Picker only offers installed curated monospace families.
- Open editors update live.
- Unavailable persisted fonts fall back to system monospaced font.

### PREF-03: PDF Paper Size

Steps:

1. Select US Letter.
2. Export PDF and inspect page size.
3. Select A4 and repeat.

Expected:

- PDF dimensions match selected paper size.
- Selection persists.

## Performance And Reliability

### PERF-01: Parser And Preview Gates

Inputs:

- 10 KB typical Markdown.
- 1 MB Markdown.
- 5 MB Markdown.
- Math-heavy and Mermaid-heavy fixtures.

Expected:

- 10 KB preview update completes within 500 ms after debounce.
- 1 MB parse/open targets match `docs/04-M1-PERF-GATE.md`.
- 5 MB document remains editable without main-thread blocking.
- Expensive technical rendering uses cache when source is unchanged.

### PERF-02: Large-Document Manual Stress

Run the large-document section in `samples/preview-smoke/CHECKLIST.md`.

Expected:

- Open/edit/scroll/find/replace remain responsive.
- Preview may take longer but must not beachball the editor.
- Syntax highlighting can degrade to preserve responsiveness.

### REL-01: Preview Failure Recovery

Steps:

1. Reload the preview.
2. If possible, trigger WebContent termination from Web Inspector or by loading a stress document.
3. Continue editing.

Expected:

- Preview reloads shell and replays latest payload.
- Editing remains possible.
- Status/logs indicate failure without crashing the app.

## Privacy And Offline Behavior

### OFFLINE-01: Local-First Behavior

Steps:

1. Disconnect network.
2. Open the smoke fixture.
3. Render math, Mermaid, images, export HTML/PDF.
4. Search source for telemetry/network SDKs before release.

Expected:

- App works without an account.
- KaTeX, MathJax, Mermaid, highlight.js, and styles load from bundled resources.
- No telemetry or remote rendering is present by default.
- PlantUML does not contact remote servers.

## Deferred Or Explicitly Limited Scope

These items appear in earlier PRDs or deferred sections but are not release-blocking shipped MVP behavior.

| Capability | Expected validation |
| --- | --- |
| Optional local PlantUML rendering | Deferred. Validate only that fenced blocks show the configured-notice placeholder and do not hang. |
| DOM patching preview updates | Deferred unless measurements prove full replacement inadequate. Validate current full-update path instead. |
| Theme system | Deferred. Validate system light/dark/auto styling only. |
| Deep workspace features: graph, backlinks, project metadata, file moves, full-text workspace search, `.gitignore` filtering, recent folders | Deferred/undefined. Validate only current Open Folder and quick-open behavior. |
| Cloud sync, collaboration, accounts, plugins, AI features, mobile/Windows/Linux support | Non-goals. Confirm no UI claims these capabilities. |
| DOCX/LaTeX/Reveal.js export | Non-goals. Confirm export menu only declares supported HTML/PDF paths. |
| Remote PlantUML services | Out of scope. Confirm no remote rendering is used by default. |

## Release Sign-Off Checklist

- [ ] All package tests pass.
- [ ] Debug app build succeeds.
- [ ] `samples/preview-smoke/CHECKLIST.md` passes.
- [ ] HTML export passes visual inspection.
- [ ] PDF export passes visual inspection with TOC on and off.
- [ ] Large-document stress passes on a 5 MB fixture.
- [ ] Folder open, quick-open, and watcher checks pass.
- [ ] Settings persistence checks pass.
- [ ] Security checks pass: sanitization, unknown scheme blocking, file-link confirmation.
- [ ] Offline rendering check passes with network disconnected.
- [ ] Deferred features are not represented as shipped features in release notes or UI.
