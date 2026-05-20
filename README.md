# Writ

Writ is a fast, native macOS Markdown editor for technical writing.

Its core promise is simple: **plain text in, publication-quality technical preview out.** Markdown remains the canonical source format, while the preview renders the structure and meaning of technical documents: GitHub-Flavored Markdown, code, math, Mermaid diagrams, SVG/image references, tables, and export-ready typography.

Writ follows a WYWIWYM principle: *What You Write Is What You Mean*. It is not a proprietary rich-text editor, a cloud document system, or an Electron app.

## Status

M0 → M3 of the MVP plan are feature-complete. Pre-1.0 release builds are
signed with my Developer ID; see [the mini-site](https://ceesaxp.github.io/writ/)
for the latest DMG.

Implemented:

- Document-based macOS app for `.md`, `.markdown`, and `.txt`, with
  BOM-aware UTF-8 + CP1252 / Latin-1 fallback on read
- AppKit / TextKit 2 editor surface, AST-driven incremental syntax
  highlighting via `swift-markdown`
- Optional line numbers (`⌥⌘L`) rendered by a custom NSView gutter
- Fenced-code lines get a full-width background tint behind the glyphs
- Auto-pair brackets / quotes / fence markers
- Insert menu: code (`⌥⌘K`), math (`⌥⌘M`), Mermaid (`⌥⌘D`)
- Source-only, preview-only, and split modes (`⌥⌘1/2/3`)
- Persistent `WKWebView` preview with debounced updates and stale-result
  rejection; block-aware two-way scroll sync between editor and preview
- GitHub-Flavored Markdown rendering with table alignment markers
- Math through KaTeX by default; MathJax bundled as a runtime alternate
- Mermaid fenced block rendering, offline
- Local image / SVG references via a sandbox-friendly `writ-doc://` URL
  scheme handler
- Preview HTML sanitiser strips `<script>`, event handlers, and
  `javascript:` URLs from raw inline HTML in source
- Render diagnostics ribbon in the preview pane with click-to-jump
- Status bar with word count, line/column, render status
- HTML export captures the live preview DOM (math / Mermaid survive);
  PDF export via `WKWebView.printOperation` produces a paginated US
  Letter PDF
- External file-change detection with unsaved-edits warning
- File > Open Folder… (`⇧⌘O`) opens a sidebar window listing markdown
  files in a directory; filter-as-quick-open
- Outline / heading navigation pane (`⌥⌘0`)
- Preferences pane (`⌘,`): large-doc thresholds, debounce intervals,
  line numbers toggle
- PlantUML fenced block recognition with a non-blocking
  "renderer not configured" notice
- Swift Testing suites for core, parser, and render packages (59 tests);
  GitHub Actions CI builds the app and runs the suites on macOS 15

Deferred to post-MVP:

- Optional local PlantUML rendering
- Sanitized inline SVG injection
- DOM patching preview updates (only if measurement shows full reload
  is inadequate on common workloads)
- Theme system
- Deeper folder/workspace features (graph view, backlinks, project
  metadata)

See [TODO.md](TODO.md) and [docs/01-MVP-PLAN.md](docs/01-MVP-PLAN.md) for milestone tracking.

## Product Scope

Writ is built for:

- Developers and engineers writing READMEs, ADRs, API docs, specs, and architecture notes
- Technical writers producing documentation with code, diagrams, and structured Markdown
- Researchers, students, and academics writing Markdown with LaTeX-style math
- macOS users who want native speed, local files, keyboard-driven editing, and offline operation

MVP non-goals:

- WYSIWYG or Typora-style inline rich editing
- Cloud sync, collaboration, accounts, or proprietary document storage
- Plugin system
- AI writing or generation features
- Mobile, iPadOS, Windows, or Linux versions
- Full publishing platform
- Heavy custom theme engine

## Architecture

Writ is a native macOS app with a small set of local Swift packages:

- `App/` - AppKit document app, editor, preview, menu, export, and window controllers
- `Packages/WritCore` - document snapshots, revisions, hashes, render jobs, large document mode, and technical block models
- `Packages/WritParser` - Markdown parsing, math preprocessing, technical block extraction, and HTML emission
- `Packages/WritRender` - preview scheduling, technical block caching, export helpers, and bridge payloads
- `Resources/preview` - WebKit preview shell, CSS, JavaScript bridge, KaTeX, MathJax, Mermaid, and highlight.js assets
- `Benchmarks/` - parser and fixture benchmark tooling
- `docs/` - product requirements, implementation plan, technical design, and milestone decisions

The editor uses AppKit `NSTextView`/TextKit. The preview uses a persistent `WKWebView` loaded once per document, then updated through a JavaScript bridge. Parsing and preview scheduling run off the main thread so typing remains responsive.

## Rendering Pipeline

1. The user edits Markdown in the native text editor.
2. A debounce schedules preview generation.
3. Markdown parsing runs off the main thread.
4. Technical blocks are extracted, including math, Mermaid, PlantUML, SVG/image references, and code fences.
5. HTML is emitted with stable block IDs for preview coordination.
6. The existing `WKWebView` receives an update payload.
7. Bundled preview JavaScript renders math, diagrams, and code highlighting.
8. Expensive technical renders are cached by content hash where available.
9. Render errors are shown inline or in the status bar instead of modal alerts.

## Requirements

- macOS 14 or newer
- Xcode with Swift 6 support
- XcodeGen, if regenerating `Writ.xcodeproj` from `project.yml`

The app is designed to work offline and does not require an account. MVP builds do not use telemetry or remote rendering services.

## Build

Open the existing project:

```sh
open Writ.xcodeproj
```

Build from the command line:

```sh
xcodebuild -project Writ.xcodeproj -scheme Writ -configuration Debug build
```

Regenerate the Xcode project after changing `project.yml`:

```sh
xcodegen generate
```

## Test

Run package tests:

```sh
swift test --package-path Packages/WritCore
swift test --package-path Packages/WritParser
swift test --package-path Packages/WritRender
```

Run benchmarks:

```sh
swift run --package-path Benchmarks writ-fixtures
swift run --package-path Benchmarks writ-bench
```

## Key Technical Decisions

- Editor: AppKit `NSTextView` with TextKit 2 where practical
- Preview: persistent `WKWebView` updated through `window.Writ.update(...)`
- Markdown parser: `apple/swift-markdown`, backed by `cmark-gfm`
- Math renderer: KaTeX by default, MathJax bundled as an alternate
- Mermaid: bundled local Mermaid.js
- PlantUML: recognized in MVP, but local rendering is deferred
- Folder mode: deferred; the MVP is single-document first

See [docs/03-M0-DECISIONS.md](docs/03-M0-DECISIONS.md) for the recorded M0 decisions and baseline performance numbers.

## Performance Targets

Performance is a product requirement for Writ.

MVP targets include:

- Warm launch to editable window in under 1 second on Apple Silicon
- Open a 1 MB Markdown file to editable state in under 1 second
- Keep a 5 MB Markdown file editable without blocking the main thread
- No visible typing lag during normal editing
- Smooth native editor scrolling for large files
- Preview updates for a 10 KB document within 500 ms after debounce
- No full-document attributed-string rebuild on every keystroke
- Reuse the `WKWebView` for the document lifetime

## Privacy And Offline Behavior

Writ is local-first:

- No account is required
- No telemetry is included in the MVP
- No remote rendering services are used by default
- PlantUML remote servers are out of scope
- Rendering libraries are bundled for offline use

## Documentation

- [Product requirements](docs/00-PRD-Final.md)
- [MVP implementation plan](docs/01-MVP-PLAN.md)
- [Technical design](docs/02-TECHNICAL-DESIGN.md)
- [M0 decisions and baseline](docs/03-M0-DECISIONS.md)
- [Implementation TODO](TODO.md)
