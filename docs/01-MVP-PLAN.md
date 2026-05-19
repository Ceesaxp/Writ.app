# Writ MVP Implementation Plan

## 1. Objective

Build Writ as a fast native macOS Markdown editor for technical writing, with plain text as the canonical source and a reliable rendered preview for GitHub-Flavored Markdown, code, math, Mermaid, SVG references, and export.

The MVP should prove the core product loop before expanding the surface area:

1. Open and edit Markdown files with native macOS behavior.
2. Render high-quality technical preview without blocking editing.
3. Preserve local-first, offline, plain-text workflows.
4. Meet explicit performance gates on realistic files.

## 2. Release Philosophy

Writ should ship a narrower MVP with strict quality gates rather than a broad technical-document workbench with uneven behavior.

The first credible release should prioritize:

- Native editing responsiveness.
- Correct enough GitHub-Flavored Markdown rendering.
- Fast preview updates for common documents.
- Code, math, and Mermaid as first-class technical authoring features.
- Predictable export to HTML and PDF.

The following should not block the first MVP:

- PlantUML rendering.
- Full folder/project mode.
- Plugin architecture.
- Deep visual theming.
- DOM patching preview updates unless measurement proves full reload is inadequate.
- Exact GitHub visual styling.

## 3. Milestones

### M0: Technical Spikes

Goal: resolve the highest-risk technical decisions before production implementation.

Scope:

- Create a minimal AppKit/TextKit editor prototype.
- Create a persistent `WKWebView` preview prototype.
- Evaluate Markdown parser options:
  - `cmark-gfm`
  - `swift-markdown`
  - a hybrid if needed
- Evaluate MathJax vs KaTeX:
  - GitHub syntax compatibility
  - startup cost
  - render cost
  - offline bundling complexity
- Evaluate Mermaid bundling and render behavior inside `WKWebView`.
- Measure preview strategies:
  - full HTML replacement
  - targeted body replacement
  - DOM patching as a possible later optimization
- Build benchmark fixtures:
  - 10 KB Markdown file
  - 1 MB Markdown file
  - 5 MB Markdown file
  - document with many code fences
  - document with many math blocks
  - document with many Mermaid blocks

Exit criteria:

- AppKit/TextKit is confirmed as the primary editor surface.
- Preview update path is selected for P0.
- Markdown parser choice is made.
- Math renderer choice is made.
- Baseline performance numbers are recorded.

Recommended decisions unless spikes disprove them:

- Editor: AppKit `NSTextView` with TextKit 2 where practical.
- Preview: persistent `WKWebView`.
- Markdown: `cmark-gfm` for GitHub-Flavored Markdown fidelity.
- Math: MathJax for GitHub-compatible syntax.
- Mermaid: bundled Mermaid.js.

### M1: P0 Core Editor And Preview

Goal: implement the smallest product that proves Writ's native editing and preview loop.

Scope:

- macOS document-based app.
- Open/save `.md`, `.markdown`, and `.txt`.
- AppKit/TextKit-backed plain text editor.
- Native editing behaviors:
  - undo / redo
  - copy / paste
  - text selection
  - drag selection
  - find
  - replace
  - spellcheck where appropriate
  - native tabs
  - autosave / Versions
- Split view modes:
  - Source only
  - Preview only
  - Source + Preview
- Persistent `WKWebView` preview.
- Debounced live preview.
- Manual preview refresh command.
- Basic GitHub-Flavored Markdown rendering:
  - headings
  - paragraphs
  - emphasis
  - links
  - images
  - lists
  - blockquotes
  - tables
  - task lists
  - strikethrough
  - fenced code blocks
- Code fence highlighting in preview.
- Dark/light aware default CSS.
- Inline render errors in preview.
- Basic HTML export.
- Basic PDF export through WebKit/macOS print pipeline.
- Large document mode:
  - automatic threshold-based activation
  - longer debounce
  - manual refresh option
  - no blocking work on the main thread

P0 gate:

- Warm launch opens to editable window in under 1 second on Apple Silicon.
- 1 MB Markdown file opens to editable state in under 1 second.
- 5 MB Markdown file remains editable without blocking the main thread.
- Typing has no visible lag in normal documents.
- Editor scrolling remains smooth in large files.
- Preview update for a 10 KB document completes within 500 ms after debounce.
- No full-document attributed string rebuild occurs on every keystroke.
- `WKWebView` is reused for the document lifetime.
- Preview generation never blocks typing.

### M2: P1 Technical Markdown

Goal: make Writ useful for real technical writing.

Scope:

- GitHub-compatible math authoring:
  - inline `$...$`
  - inline ``$`...`$``
  - block `$$...$$`
  - fenced ```math blocks
- MathJax integration, unless M0 selected KaTeX.
- Mermaid fenced block rendering.
- Content-hash cache for math and Mermaid blocks.
- Render cancellation/coalescing so stale renders cannot overwrite newer preview output.
- Stable preview block IDs for scroll sync.
- Approximate source-to-preview scroll sync.
- Status bar:
  - word count
  - line / column
  - render status
- Menu commands:
  - insert code block
  - insert math block
  - insert Mermaid block
  - refresh preview
- Referenced `.svg` image support.
- Preview HTML sanitization pass for rendered content and local asset references.

P1 gate:

- User can open a technical Markdown file with GFM, code fences, math, Mermaid, referenced SVG, and normal images.
- Math renders with GitHub-compatible syntax.
- Mermaid renders locally and offline.
- Math and Mermaid render failures appear inline without modal alerts.
- Editing remains responsive while math/Mermaid preview work is pending.
- Repeated math/Mermaid blocks are served from cache by content hash.
- Exported HTML and PDF preserve code highlighting, math, Mermaid diagrams, and document typography.

### M3: P2 Workflow And Robustness

Goal: improve real-world authoring ergonomics after the core loop is stable.

Scope:

- Incremental or viewport/range-aware Markdown syntax highlighting in the editor.
- Optional line numbers.
- Better source-to-preview scroll sync.
- External file change detection.
- Improved find/replace behavior for large documents.
- Improved HTML export:
  - bundled CSS
  - local image handling where feasible
  - rendered technical blocks where feasible
- Improved PDF export polish.
- Simple folder open:
  - file list
  - open Markdown/text files
  - quick open
  - no project metadata
- Better render diagnostics:
  - malformed math
  - Mermaid parse errors
  - missing local images
  - unsupported PlantUML renderer
- Configurable large document thresholds.

P2 gate:

- Syntax highlighting remains responsive on large files.
- External changes are detected and surfaced safely.
- Folder mode does not introduce proprietary workspace state.
- Export works predictably for documents using P1 technical features.
- Large-document behavior is understandable and recoverable by the user.

### M4: P3 Advanced Technical Blocks

Goal: add optional advanced rendering after the product foundation is proven.

Scope:

- PlantUML fenced block recognition.
- Optional local PlantUML rendering:
  - configured local executable/JAR
  - no remote server by default
  - local-only execution
  - content-hash cache
  - timeout and cancellation
  - inline render errors
- Sanitized inline SVG support.
- DOM patching preview updates if performance measurements justify it.
- More precise GitHub visual compatibility option.
- Additional built-in themes.
- Deeper folder/workspace features if user demand is validated.

P3 gate:

- PlantUML is opt-in and non-blocking.
- Missing PlantUML configuration degrades to a readable source block and clear inline message.
- SVG injection is sanitized before preview rendering.
- DOM patching improves measured performance without increasing rendering correctness risk.

## 4. Priority Matrix

### P0: Required For MVP

- AppKit/TextKit editor.
- Document-based macOS app.
- Open/save local Markdown/text files.
- Native editing behaviors.
- Persistent `WKWebView` preview.
- Source/preview/split modes.
- Debounced preview.
- Manual refresh.
- GFM baseline rendering.
- Code highlighting in preview.
- Dark/light CSS.
- Basic HTML/PDF export.
- Large document mode.
- Off-main-thread parsing/render generation.
- Performance benchmarks.

### P1: Required For Technical MVP

- GitHub-compatible math.
- Mermaid rendering.
- Math/Mermaid caching.
- Render cancellation/coalescing.
- Approximate scroll sync.
- Status bar.
- Insert block commands.
- Referenced SVG support.
- Preview sanitization.
- Export preserving technical blocks.

### P2: Post-MVP Quality

- Incremental editor syntax highlighting.
- Optional line numbers.
- External file change detection.
- Better scroll sync.
- Simple folder mode.
- Quick open.
- Better export bundling.
- Better render diagnostics.
- User-configurable large document thresholds.

### P3: Advanced/Deferred

- PlantUML local rendering.
- Sanitized inline SVG.
- DOM patching preview updates.
- Theme system.
- Project metadata.
- Plugin system.
- AI features.
- Cloud sync or collaboration.

## 5. Performance Gates

Performance is a product requirement, not an implementation detail.

Required measurements:

- App launch time.
- Time to editable state for 10 KB, 1 MB, and 5 MB files.
- Typing latency during active preview debounce.
- Editor scroll frame pacing on large files.
- Preview generation time by document size.
- Math render time by block count.
- Mermaid render time by block count.
- Export time for representative technical documents.
- Memory usage for 1 MB and 5 MB documents.

Required behavior:

- Editing must remain responsive while parsing and rendering are in progress.
- Preview jobs must be cancellable or coalesced.
- Stale render output must not replace newer output.
- Expensive technical block renders must be cached by source hash.
- Large document mode must activate automatically.
- Full-document syntax rehighlighting must not run on every keystroke for large files.

## 6. Implementation Sequence

Recommended order:

1. Create app shell and document model.
2. Add AppKit editor surface.
3. Add open/save/autosave/native editing.
4. Add persistent `WKWebView` preview.
5. Add Markdown parsing and baseline HTML/CSS.
6. Add preview debounce and render job cancellation.
7. Add performance fixture suite.
8. Add code fence highlighting.
9. Add HTML/PDF export.
10. Add large document mode.
11. Add math rendering.
12. Add Mermaid rendering.
13. Add technical block cache.
14. Add scroll sync and stable block IDs.
15. Add status bar and insert commands.
16. Add SVG reference support and preview sanitization.
17. Add editor syntax highlighting.
18. Add folder mode and quick open.
19. Add optional PlantUML.

## 7. Risks And Mitigations

### Editor Performance

Risk: SwiftUI text editing and naive attributed string updates will not meet performance goals.

Mitigation:

- Use AppKit/TextKit for the primary editor.
- Keep syntax highlighting incremental or viewport-aware.
- Disable expensive highlighting behavior in large document mode.

### Preview Latency

Risk: full preview reloads become slow with math, Mermaid, and large documents.

Mitigation:

- Reuse `WKWebView`.
- Debounce preview updates.
- Cache technical blocks by content hash.
- Coalesce stale render jobs.
- Defer DOM patching until measurement proves it is required.

### Math Compatibility

Risk: dollar-delimited math can conflict with normal prose and currency.

Mitigation:

- Follow GitHub-compatible delimiter rules.
- Prefer fenced ```math for complex blocks.
- Add tests for currency, escaped dollars, and mixed Markdown/math content.

### Mermaid Cost

Risk: Mermaid rendering is slow or unstable for complex diagrams.

Mitigation:

- Render Mermaid blocks after Markdown HTML generation.
- Cache by content hash.
- Show inline errors.
- Avoid blocking editor interaction.

### PlantUML Complexity

Risk: PlantUML introduces Java dependency, local execution, security, and configuration complexity.

Mitigation:

- Defer rendering to P3.
- Recognize syntax earlier if useful.
- Use local-only opt-in execution.
- Apply timeouts and cache results.

## 8. MVP Definition

The MVP is complete when:

- Writ opens, edits, saves, and exports Markdown files natively on macOS.
- The editor is responsive on realistic and large documents.
- Preview renders GFM, code, math, Mermaid, and referenced SVGs offline.
- Render errors are visible and non-disruptive.
- HTML/PDF export preserves the important rendered technical content.
- The application feels faster and more native than Electron-based alternatives for the supported scope.

