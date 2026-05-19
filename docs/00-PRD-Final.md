# Writ MVP Product Requirements Document

## 1. Vision

Writ is a fast, native macOS Markdown editor for people who write technical documents in plain text but need rich rendered meaning: code, math, diagrams, SVG, tables, and media.

Core promise: **plain text in, publication-quality technical preview out.**

Writ follows a WYWIWYM principle: *What You Write Is What You Mean*. The source remains portable Markdown. The preview makes the meaning visible without turning the editor into a proprietary rich-text system.

## 2. Target Users

- Developers and engineers writing READMEs, ADRs, API docs, specs, and architecture notes.
- Technical writers producing docs with code, diagrams, and structured Markdown.
- Researchers, students, and academics writing Markdown with LaTeX-style math.
- macOS power users who want native speed, low memory use, keyboard-driven editing, and local files.

## 3. MVP Goals

- Deliver a polished macOS-native Markdown editor that feels faster than Electron-based alternatives.
- Support GitHub-Flavored Markdown plus technical extensions: math, Mermaid, SVG, code highlighting.
- Provide reliable live preview with smooth scrolling, fast updates, and predictable rendering.
- Preserve plain text as the canonical source format.
- Work fully offline with local files and no account requirement.

## 4. MVP Non-Goals

- WYSIWYG or Typora-style inline rich editing.
- Cloud sync, collaboration, accounts, or proprietary document storage.
- Plugin system.
- AI writing/generation features.
- Mobile, iPadOS, Windows, or Linux versions.
- Full publishing platform.
- Heavy custom theme engine.

## 5. Core MVP Features

### 5.1 Native Editor

- macOS document-based app for `.md`, `.markdown`, and `.txt`.
- Plain text editor using AppKit/TextKit, not SwiftUI `TextEditor` as the primary editing surface.
- Syntax highlighting for Markdown structure:
  - headings
  - emphasis
  - links
  - images
  - lists
  - blockquotes
  - tables
  - fenced code blocks
  - math delimiters
  - Mermaid / PlantUML code fences
- Standard macOS editing behaviors:
  - undo / redo
  - find and replace
  - spellcheck where appropriate
  - text selection, drag, copy, paste
  - native tabs
  - autosave / Versions support
- Optional line numbers.
- Word count, line/column, and render status in a compact status bar.
- Keyboard-first workflow with menu commands for inserting code block, math block, Mermaid block, and preview refresh.

### 5.2 Preview

- Split view modes:
  - Source only
  - Preview only
  - Source + Preview
- Preview rendered in `WKWebView`.
- Debounced live preview, with manual refresh available for large documents.
- Approximate scroll sync between source and preview.
- Dark/light mode aware default CSS.
- Render errors shown inline in preview, not as disruptive alerts.

### 5.3 Markdown And Rendering Support

- CommonMark + GitHub-Flavored Markdown as the baseline.
- Tables, task lists, strikethrough, autolinks, footnotes where parser support allows.
- Fenced code blocks with syntax highlighting for common languages.
- Math support compatible with GitHub-style authoring:
  - inline `$...$`
  - inline ``$`...`$``
  - block `$$...$$`
  - fenced \`\`\`math blocks
- Math renderer:
  - MVP default: MathJax if GitHub fidelity and macro coverage are prioritized.
  - Alternative: KaTeX if startup and render speed are prioritized.
  - Decision should be made explicitly before implementation.
- Mermaid support through fenced \`\`\`mermaid blocks.
- SVG support:
  - referenced `.svg` images
  - sanitized inline SVG in preview
- PlantUML:
  - MVP should support fenced \`\`\`plantuml blocks as source syntax.
  - Rendering should be optional/local-only in MVP, using a configured local PlantUML executable/JAR if available.
  - If unavailable, show source block with a clear non-blocking render message.
  - No remote PlantUML server in MVP.

### 5.4 File And Workspace

- Open/save local Markdown files directly.
- Recent documents.
- Native open/save panels.
- External file change detection.
- Export:
  - HTML with bundled CSS and rendered assets where feasible.
  - PDF via WebKit/macOS print pipeline.
- Folder/project support is useful but should be MVP-light:
  - Open folder
  - simple file list / quick open
  - no backlinks, graph view, database, or project metadata.

## 6. Technical Architecture

Writ should not be a SwiftUI-only app. SwiftUI can host preferences, settings panes, command surfaces, and simple layout, but the editor needs lower-level control.

Recommended stack:

- App shell: SwiftUI + AppKit document/window integration.
- Editor: AppKit `NSTextView` backed by TextKit 2 where practical.
- Syntax highlighting: incremental tokenizer/highlighter, not full-document rehighlight on every keystroke.
- Markdown parser: `swift-markdown` / `cmark-gfm` or direct `cmark-gfm` integration for GFM fidelity.
- Preview: persistent `WKWebView` with bundled JS/CSS assets.
- Code highlighting: bundled JS highlighter in preview, or pre-highlighted HTML if performance requires it.
- Math: MathJax or KaTeX, selected through a performance/fidelity spike.
- Mermaid: bundled Mermaid.js.
- PlantUML: optional local renderer with content-hash cache.
- SVG: sanitize before injecting into preview HTML.

## 7. Rendering Pipeline

1. User edits Markdown in `NSTextView`.
2. Dirty ranges are tracked for highlighting.
3. A debounce timer schedules preview generation.
4. Markdown parsing runs off the main thread.
5. Technical blocks are extracted:
   - math
   - Mermaid
   - PlantUML
   - SVG
   - code fences
6. HTML is produced with stable block IDs for scroll sync.
7. Preview updates the existing `WKWebView` document instead of recreating the full web view.
8. Expensive renders are cached by content hash.
9. Errors are attached to the relevant preview block.

## 8. Performance Requirements

MVP must treat performance as a product feature.

Targets:

- Launch to editable window: under 1 second on Apple Silicon for warm launch.
- Open 1 MB Markdown file: under 1 second to editable state.
- Open 5 MB Markdown file: remains editable without blocking the main thread.
- Typing latency: no visible lag during normal editing.
- Scrolling: smooth native scrolling in the editor for large files.
- Preview update for a 10 KB document: under 500 ms after debounce.
- Preview update for large documents: may degrade to partial/manual refresh, but must not freeze editing.
- Mermaid/PlantUML/math rendering must be cached by source hash.
- Syntax highlighting must be incremental or viewport/range-aware.
- No full-document attributed string rebuild on every keystroke for large files.

Architecture implications:

- Use AppKit/TextKit, not pure SwiftUI text editing.
- Keep parsing and preview generation off the main thread.
- Reuse `WKWebView`.
- Avoid `loadHTMLString` for every small edit if DOM patching proves materially faster.
- Add a “large document mode” that increases debounce, disables auto-preview, or renders only on save/manual refresh.

## 9. Privacy And Offline Requirements

- No account required.
- No telemetry in MVP.
- No remote rendering services by default.
- PlantUML remote servers are out of scope for MVP.
- All bundled rendering libraries should work offline.

## 10. MVP Success Criteria

- User can open a Markdown file containing GFM, math, code, Mermaid, SVG, and PlantUML source.
- Math renders according to GitHub-compatible syntax.
- Mermaid renders correctly in preview.
- SVG references render safely.
- PlantUML source is recognized; local rendering works when configured.
- Editor remains responsive on large files.
- Preview updates are fast and non-disruptive.
- Exported HTML/PDF preserve rendered math, diagrams, code styling, and document typography.
- App feels recognizably native on macOS.

## 11. Key Risks

- SwiftUI text editing is unlikely to meet performance and customization goals.
  - Mitigation: use AppKit/TextKit for the editor.
- Math parsing can conflict with currency and normal dollar signs.
  - Mitigation: follow GitHub-compatible delimiter rules and support fenced \`\`\`math.
- Mermaid and MathJax/KaTeX can be expensive on large documents.
  - Mitigation: cache block renders and debounce intelligently.
- PlantUML adds installation and security complexity.
  - Mitigation: local-only, opt-in, cached, non-blocking.
- Full preview reloads may become slow.
  - Mitigation: prototype DOM patching after MVP baseline if needed.

## 12. Open Decisions

1. Should MVP optimize for GitHub math fidelity with MathJax, or rendering speed with KaTeX?
2. Is folder/project mode truly MVP, or should v1 start as a single-document editor with recent files?
3. Should PlantUML rendering ship in MVP, or should MVP only recognize PlantUML blocks and defer rendering?
4. Should Writ aim for exact GitHub visual compatibility, or a GitHub-compatible syntax with Writ’s own typography?