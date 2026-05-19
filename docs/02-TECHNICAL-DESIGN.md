# Writ Technical Design

## 1. Purpose

This document describes the proposed architecture for Writ, a native macOS Markdown editor optimized for fast plain-text editing and high-quality technical preview.

The central design constraint is that the editor must stay responsive even when parsing, syntax highlighting, math rendering, diagram rendering, and export work are in progress.

## 2. Architecture Overview

Writ is a native macOS document-based application with an AppKit editor, a WebKit preview, and an asynchronous rendering pipeline.

Recommended high-level stack:

- App shell: SwiftUI where appropriate, integrated with AppKit document/window APIs.
- Editor: AppKit `NSTextView`, backed by TextKit 2 where practical.
- Preview: persistent `WKWebView`.
- Markdown parser: `cmark-gfm` unless implementation constraints favor another parser.
- Math renderer: MathJax by default for GitHub-compatible syntax.
- Diagram renderer: bundled Mermaid.js inside the preview environment.
- Code highlighting: preview-side JavaScript highlighter initially, with pre-highlighted HTML as a fallback if measurement requires it.
- Export: generated HTML plus WebKit/macOS PDF generation.

SwiftUI can be used for:

- App layout shell.
- Preferences.
- Settings panes.
- Command surfaces.
- Simple panels.
- Status bar containers.

SwiftUI should not be used as the primary text editing surface.

## 3. Major Components

### App Shell

Responsibilities:

- App lifecycle.
- Window management.
- Document integration.
- Commands and menus.
- Preferences.
- View composition.

Implementation notes:

- Use SwiftUI for composition where it remains simple.
- Bridge to AppKit for document windows, text editing, and advanced responder-chain behavior.
- Preserve native macOS behaviors instead of reimplementing them in custom UI.

### Document Model

Responsibilities:

- Own the file URL.
- Own the canonical Markdown source text.
- Track dirty state.
- Coordinate save/autosave.
- Observe external file changes.
- Provide snapshots to parser/render workers.

The source text remains the only canonical document format. Preview HTML, rendered diagrams, caches, and export artifacts are derived state.

### Editor Surface

Responsibilities:

- Display and edit plain text.
- Preserve native text behavior.
- Track selection, insertion point, line/column, and visible range.
- Provide edit events to syntax highlighting and preview scheduling.
- Support optional line numbers.

Recommended implementation:

- `NSScrollView`
- `NSTextView`
- TextKit 2 where practical
- Custom coordinator/delegate layer for edit events

Editor constraints:

- Do not rebuild the full attributed string on every keystroke.
- Do not block the main thread for parsing or preview rendering.
- Keep syntax highlighting incremental, viewport-aware, or disabled in large document mode.
- Apply highlight updates carefully to avoid selection jumps and undo stack pollution.

### Syntax Highlighter

Responsibilities:

- Highlight Markdown structure in the source editor.
- Identify fenced code, math, Mermaid, and PlantUML delimiters.
- Avoid expensive whole-document work during normal typing.

Recommended design:

- Maintain a lightweight tokenization model.
- Track dirty ranges from text edits.
- Expand dirty ranges to safe Markdown block boundaries.
- Re-highlight only affected ranges where possible.
- Use viewport-aware highlighting for very large files.
- Fall back to reduced highlighting in large document mode.

Initial highlighted constructs:

- headings
- emphasis
- links
- images
- lists
- blockquotes
- tables
- fenced code blocks
- math delimiters
- Mermaid fences
- PlantUML fences as syntax only

### Preview Renderer

Responsibilities:

- Convert Markdown snapshots into preview HTML.
- Insert stable block IDs.
- Extract and mark technical blocks.
- Attach render diagnostics to the relevant preview block.
- Coordinate preview updates in `WKWebView`.

Pipeline:

1. Receive immutable source snapshot.
2. Parse Markdown off the main thread.
3. Produce an intermediate representation or HTML with source/block mapping.
4. Identify technical blocks:
   - code
   - math
   - Mermaid
   - PlantUML
   - SVG
5. Generate preview HTML.
6. Reuse cached render outputs where hashes match.
7. Send preview update to the existing `WKWebView`.
8. Ignore stale render results if a newer snapshot exists.

The preview renderer must support cancellation or coalescing. If a user types five times during one render, Writ should display the newest coherent result, not every intermediate result.

### Preview Web View

Responsibilities:

- Host rendered Markdown.
- Load bundled CSS and JavaScript.
- Render MathJax/KaTeX and Mermaid.
- Report render completion/errors.
- Support scroll sync.
- Support export preparation.

Implementation notes:

- Keep one `WKWebView` alive for the document lifetime.
- Load bundled offline assets.
- Use a local base URL that permits safe loading of local document-relative resources.
- Avoid remote network dependency.
- Prefer replacing preview document content initially.
- Evaluate DOM patching later if measured reload cost is too high.

### Technical Block Cache

Responsibilities:

- Avoid re-rendering expensive deterministic blocks.
- Cache rendered math, Mermaid, and later PlantUML output.
- Key entries by source hash plus renderer version/options.

Cache key should include:

- block type
- source content hash
- renderer name
- renderer version
- rendering options
- theme mode if output differs by theme

Cache entries should include:

- rendered HTML/SVG
- diagnostics
- render duration
- creation time

The first implementation can be in-memory per document. A persistent disk cache can be added later if measurements justify it.

## 4. Rendering Pipeline

### Edit To Preview Flow

1. User edits text in `NSTextView`.
2. Editor reports changed range and current document revision.
3. Syntax highlighter schedules range-aware work.
4. Preview scheduler debounces the edit.
5. Scheduler captures an immutable source snapshot.
6. Parser/render worker runs off the main thread.
7. Renderer emits HTML, block metadata, and diagnostics.
8. Main thread applies the newest valid preview update to `WKWebView`.
9. Preview reports technical block render status back to the app.
10. Status bar updates render state.

### Revision Handling

Every source snapshot should carry a monotonically increasing document revision.

Rules:

- A render job may only update preview if its revision matches the latest accepted revision.
- Older jobs should be cancelled when possible.
- Older jobs that cannot be cancelled must be ignored on completion.
- Status UI should distinguish rendering, current, stale, and failed states.

### Debounce Strategy

Suggested defaults:

- Normal document: 200-400 ms after last edit.
- Large document: 1000-2000 ms after last edit, or manual refresh only.
- Expensive technical block changes: allow preview shell update first, then technical blocks finish asynchronously if needed.

Large document mode should be based on document size and measured complexity, not just bytes.

Inputs:

- file size
- line count
- fenced block count
- math block count
- Mermaid block count
- previous render duration

## 5. Markdown And Technical Features

### GitHub-Flavored Markdown

Use CommonMark plus GFM features:

- tables
- task lists
- strikethrough
- autolinks
- fenced code blocks
- footnotes where parser support allows

`cmark-gfm` is the recommended baseline parser because GFM fidelity is important to the product promise.

### Code Highlighting

Initial option:

- Render Markdown to HTML.
- Let bundled preview JavaScript highlight code blocks.

Fallback option:

- Pre-highlight code blocks during HTML generation if preview-side highlighting is too slow or difficult to control.

Requirements:

- Must work offline.
- Must not block editing.
- Must preserve code text faithfully during export.

### Math

Recommended default:

- MathJax, because GitHub uses MathJax and Writ wants GitHub-compatible authoring.

Supported syntax:

- inline `$...$`
- inline ``$`...`$``
- block `$$...$$`
- fenced ```math blocks

Design notes:

- Follow GitHub-compatible delimiter behavior.
- Add tests for escaped dollar signs and currency values.
- Cache rendered math by source hash.
- Show errors inline in preview.

### Mermaid

Supported syntax:

- fenced ```mermaid blocks

Design notes:

- Bundle Mermaid.js.
- Render offline in `WKWebView`.
- Cache successful and failed render results by source hash.
- Show parse/render errors inline.
- Avoid blocking the editor while diagrams render.

### SVG

P1 support:

- Referenced `.svg` files through standard Markdown image syntax.

P3 support:

- Sanitized inline SVG injection.

Security notes:

- Treat inline SVG as active content unless sanitized.
- Strip scripts, external loads, event handlers, and unsafe links.
- Prefer referenced local SVG in early releases.

### PlantUML

P0/P1:

- Recognize fenced ```plantuml blocks as source syntax if useful.
- Render as source block or show a non-blocking "renderer not configured" message.

P3:

- Optional local rendering through configured executable/JAR.
- No remote PlantUML server by default.
- Apply timeout, cancellation, and caching.
- Never block editing.

## 6. File And Workspace Design

### Single Document

P0 should focus on single-document editing:

- open
- save
- save as
- autosave
- Versions
- recent files

### Folder Mode

Folder mode is P2.

Scope:

- open folder
- list Markdown/text files
- quick open
- open selected files

Out of scope:

- backlinks
- graph view
- database/index
- proprietary project metadata
- sync

## 7. Export Design

### HTML Export

P0:

- Export one HTML file with default bundled CSS.
- Preserve rendered Markdown and code highlighting as much as feasible.

P1:

- Preserve math and Mermaid output.
- Include local references where feasible.
- Surface missing assets clearly.

Later:

- Asset bundling options.
- Self-contained HTML option.
- GitHub-like style option.

### PDF Export

P0:

- Use WebKit/macOS print pipeline from rendered preview.

P1:

- Ensure math, Mermaid, code highlighting, images, and typography survive export.

Quality requirements:

- Good default page margins.
- Dark mode should not accidentally produce dark PDFs unless explicitly requested.
- Render completion should be awaited before export.

## 8. Threading And Concurrency

Main thread:

- AppKit UI.
- Text editing.
- View updates.
- Applying final preview update.

Background work:

- Markdown parsing.
- HTML generation.
- block extraction.
- syntax token computation where possible.
- export preparation where possible.

Web view:

- Math and Mermaid rendering may occur inside `WKWebView`.
- Results and errors should be reported back to native code through a controlled message bridge.

Concurrency rules:

- Use immutable source snapshots.
- Use document revision IDs.
- Coalesce preview jobs.
- Ignore stale results.
- Keep UI updates small and main-thread only.

## 9. Security And Privacy

Privacy requirements:

- No account.
- No telemetry in MVP.
- No remote rendering by default.
- All rendering libraries bundled for offline use.

Preview security:

- Sanitize HTML generated from Markdown where applicable.
- Restrict external resource loading.
- Treat inline SVG as unsafe until sanitized.
- Disable or avoid arbitrary script execution from document content.
- Use bundled scripts only.

PlantUML security:

- Local-only.
- Opt-in.
- Explicit configured executable/JAR.
- Timeout.
- No shell interpolation with document content.
- Cache by content hash.

## 10. Performance Design

### Targets

- Warm launch to editable window: under 1 second on Apple Silicon.
- Open 1 MB Markdown file to editable state: under 1 second.
- Open 5 MB Markdown file: editable without blocking the main thread.
- Normal typing: no visible lag.
- Editor scrolling: smooth native scrolling in large files.
- 10 KB preview update: under 500 ms after debounce.
- Large document preview: may degrade to manual refresh, but editing must remain responsive.

### Required Techniques

- AppKit/TextKit editor.
- Off-main-thread parsing and preview generation.
- Persistent `WKWebView`.
- Debounced preview.
- Render cancellation/coalescing.
- Technical block cache.
- Large document mode.
- Incremental/range-aware highlighting.
- Avoid full attributed string rebuilds on every edit.

### Instrumentation

Add lightweight measurement points for:

- app launch
- file load
- time to editable state
- parse duration
- HTML generation duration
- preview update duration
- MathJax render duration
- Mermaid render duration
- export duration
- memory usage snapshots

Performance fixtures should be committed to the repository or generated deterministically by tests.

## 11. Testing Strategy

### Unit Tests

- Markdown feature parsing.
- Math delimiter behavior.
- Technical block extraction.
- Hash/cache key generation.
- Revision/stale render handling.
- Large document mode threshold logic.

### Integration Tests

- Open/save Markdown documents.
- Preview generation for representative documents.
- Math rendering.
- Mermaid rendering.
- SVG references.
- Export HTML.
- Export PDF.

### Performance Tests

Use fixture documents:

- 10 KB normal Markdown.
- 1 MB mixed Markdown.
- 5 MB large Markdown.
- many code fences.
- many math blocks.
- many Mermaid blocks.

Track:

- time to editable state
- preview render time
- scroll smoothness proxy if automatable
- memory usage

### Manual QA

- native editing behavior
- find/replace
- undo/redo
- autosave/Versions
- dark/light mode
- scroll sync
- export visual quality
- offline launch and rendering

## 12. Open Technical Decisions

These decisions should be resolved during M0:

1. `cmark-gfm` direct integration vs another parser.
2. MathJax vs KaTeX.
3. Preview-side code highlighting vs pre-highlighted HTML.
4. Full preview HTML replacement vs partial DOM update for P0.
5. TextKit 2 coverage and fallback strategy.
6. In-memory-only cache vs persistent cache.

Recommended defaults:

- Choose fidelity first for Markdown and math.
- Choose responsiveness first for editor behavior.
- Defer optimizations that increase complexity until measurements justify them.

## 13. Non-Goals For MVP Architecture

- WYSIWYG editing.
- Proprietary document model.
- Plugin API.
- Remote rendering services.
- Cloud sync.
- Collaboration.
- AI generation.
- Cross-platform abstraction.
- Heavy theme engine.

## 14. Summary

Writ should be architected around a strict separation between canonical source editing and derived preview rendering. The editor must be native, fast, and isolated from expensive rendering work. The preview can use WebKit and bundled JavaScript for rich technical output, but all parsing, rendering, caching, and export work must be scheduled so the user can keep typing and scrolling without interruption.

