# Writ — Implementation TODO

Tracking against `docs/01-MVP-PLAN.md`. Strict milestone order: M0 → M1 → M2 → M3.

---

## M0 — **DONE 2026-05-19** (commit `0c2100b`)

All exit criteria met. Decisions and baseline numbers in `docs/03-M0-DECISIONS.md`.

---

## M1 — P0 core editor + preview — **largely done** (commit `cedc369`)

P0 gate items:

- [x] Document-based macOS app with `.md` / `.markdown` / `.txt` types
- [x] AppKit/TextKit 2 editor (NSTextView + NSScrollView)
- [x] Open/save round-trip preserves UTF-8; BOM detection + CP1252/Latin-1 fallback
- [x] Native editing behaviors (undo, redo, find/replace, native tabs, autosave/Versions, spellcheck)
- [x] Persistent `WKWebView` preview, single shell load, JS-driven updates
- [x] Source / Split / Preview split modes + `⌥⌘1/2/3` shortcuts + toolbar segment
- [x] Debounced preview pipeline with stale-result rejection
- [x] Manual refresh menu command (`⌘R`)
- [x] Basic GFM rendering (headings, paragraphs, emphasis, links, images, lists, blockquotes, tables, task lists, strikethrough, fenced code)
- [x] Code highlighting in preview (highlight.js, github + github-dark themes)
- [x] Dark/light aware default CSS (CSS prefers-color-scheme + bundled theme.css)
- [x] HTML export menu wired; PDF export uses `WKPDFConfiguration`
- [x] Large document mode threshold logic; debounce defaults
- [x] Off-main parsing via `PreviewScheduler` actor
- [x] 28 → 40 SPM tests passing; zero Swift 6 concurrency warnings
- [x] Inline render errors via `RenderStatus` and status bar

Remaining (non-blocking polish):
- [ ] Programmatic `⌘R` regression test (currently manual)
- [ ] PDF export programmatic smoke test (currently manual)
- [ ] Strict P0 perf gate measurement at exact 1 MB / 5 MB warm-launch boundaries (best-effort number: 1 MB → 1049 ms, 10 KB → 912 ms)
- [ ] Undo/redo through `applyEditorText` round-trip regression test

---

## M2 — P1 technical Markdown — **in progress** (commit `b7dee04`)

Done:
- [x] GitHub-compatible math authoring: inline `$...$`, block `$$...$$`, fenced ```math (preprocessor + placeholder pipeline)
- [x] KaTeX integration with MathJax bundled as runtime alternate (`Writ.setMathRenderer`)
- [x] Mermaid fenced block rendering (Mermaid.js 11.4.1)
- [x] **Content-hash cache** for math and Mermaid blocks (JS-side LRU, 256 entries, clears on renderer switch)
- [x] **Render cancellation/coalescing** (PreviewScheduler with revision tracking)
- [x] **Stable preview block IDs** (`data-writ-id` on every emitted block)
- [x] **Approximate source-to-preview scroll sync** (one-way proportional)
- [x] Status bar: word count + line / column + render status
- [x] Insert-block commands: Code (`⌥⌘K`), Math (`⌥⌘M`), Mermaid (`⌥⌘D`)
- [x] PlantUML fence recognized; rendered as source with non-blocking notice

Remaining:
- [ ] Referenced `.svg` image support via standard `![](image.svg)` syntax (needs WKWebView read-access scope expansion to document directory)
- [ ] Preview HTML sanitization pass (defense in depth — content already comes from a trusted parser, but bare inline HTML in source bypasses parser sanitization)
- [ ] Two-way scroll sync with feedback-suppression
- [ ] Export preserving rendered math/mermaid (capture rendered SVG from live preview into export HTML)
- [ ] Tests for insert-block helpers
- [ ] Tests for scroll-sync delegate hook

---

## M3 — P2 workflow + robustness

(Untouched. Plan items per MVP plan §3 M3.)

- [ ] Incremental / range-aware editor syntax highlighting (currently regex-pass with 80 ms debounce, 500 KB cap)
- [ ] Optional line numbers
- [ ] Better scroll sync (block-aware rather than proportional)
- [ ] External file change detection
- [ ] Improved find/replace behavior for large documents
- [ ] Improved HTML export bundling (relative images, asset directory)
- [ ] Simple folder open + quick open
- [ ] Render diagnostics (malformed math, mermaid parse errors, missing local images)
- [ ] Configurable large-document thresholds (preferences pane)

---

## M4 — P3 deferred

(Per MVP plan §3 M4.)

- [ ] Optional local PlantUML rendering
- [ ] Sanitized inline SVG injection
- [ ] DOM patching preview updates (only if measurement proves full reload becomes inadequate)
- [ ] Theme system
- [ ] Deeper folder/workspace features
