# Writ — Implementation TODO

Tracking against `docs/01-MVP-PLAN.md`. Strict milestone order: M0 → M1 → M2 → M3.

---

## M0 — **DONE 2026-05-19** (commit `0c2100b`)

All exit criteria met. Decisions and baseline numbers in `docs/03-M0-DECISIONS.md`.

---

## M1 — P0 core editor + preview — **largely done** (commit `cedc369`)

All P0 gate items met. See git log for details.

Outstanding M1 polish items (non-blocking, circle back as the session permits):
- [x] **Programmatic `⌘R` manual-refresh regression test** (commit `216edab`) — two PreviewScheduler tests: forceRefresh bumps revision for unchanged source; forceRefresh cancels pending debounced edits.
- [x] **PDF export programmatic smoke test** (commit `216edab`) — three HTMLExporter tests: TOC prepended inside content main; every TOC anchor resolves to an HTML id (cross-package slug parity); empty TOC string omits the nav block. Live WKWebView printOperation path remains manual via the smoke checklist.
- [x] **Strict P0 perf gate measurements** (commit `f62d678`) — docs/04-M1-PERF-GATE.md. 1MB parse p50 192ms, 5MB 953ms, 10KB 2.2ms; all gate criteria PASS with margin.
- [x] **Undo/redo through `applyEditorText` round-trip** (commit `1076b3c`) — pattern test in WritCoreTests using NSUndoManager + FakeDocument stand-in. App-level test bundle blocked by Xcode 17 + Swift 6 + executable-host swiftmodule conflict; pattern coverage serves as regression lock.

---

## M2 — P1 technical Markdown — **largely done** (commit `b7dee04`+)

All headline P1 features shipped: GFM-compatible math, KaTeX + MathJax, Mermaid, JS render cache, technical-aware HTML export, status bar, insert-block menu, table alignment, etc.

Outstanding M2 items:
- [x] **Referenced local `.svg` / `.png` / `.jpg`** (commit `e9af7ea`) — `WritDocSchemeHandler` resolves `writ-doc:///<path>` against the document's directory, sandbox-safe.
- [x] **Two-way scroll sync** (commit `4012bab`) — writ.js posts `previewScrolled` on debounced scroll; the editor scrolls to match. Ping-pong is prevented by mutual suppression flags.
- [x] **Preview sanitization** (commit `4012bab`) — `HTMLSanitizer` strips dangerous tags + event handlers + `javascript:` URLs from raw `HTMLBlock` / `InlineHTML` source.
- [x] **Auto-pair brackets / quotes / fence markers** (commit `4012bab`) — `EditorViewController.handleAutoPair` inserts the closing pair and positions the cursor between; wraps existing selections; smart skip past closing chars; apostrophe-after-letter preserved for contractions.
- [ ] Tests for insert-block helpers and the scroll-sync delegate hook (both depend on an NSTextView harness; deferred).

---

## M3 — P2 workflow + robustness — **mostly done** (commits `04ce009` … `74190c7`)

Done:
- [x] **External file change detection** — `WritDocument.presentedItemDidChange` shows an NSAlert sheet, unsaved-edits aware, `revert(toContentsOf:)` keeps editor + preview in sync.
- [x] **Optional line numbers** — custom `LineNumberGutter` NSView walks `NSTextLayoutManager.enumerateTextLayoutFragments`, top-aligns numbers on wrapped lines. Default on; View > Show Line Numbers (⌥⌘L).
- [x] **AST-driven incremental syntax highlighter** — `SyntaxSpanExtractor` builds spans from `swift-markdown`'s tree + line-level scans for math / list / task / table separators; honours block boundaries.
- [x] **Block-aware scroll sync** — `HTMLEmitter` emits `data-writ-line`; preview JS `scrollToSourceLine(line, fallback)` aligns the matching block.
- [x] **Improved HTML export bundling** — inlines theme + KaTeX + highlight.js CSS so exported math, code, and typography render without external assets.
- [x] **Simple folder open + quick open** — File > Open Folder… (⇧⌘O) opens a `FolderWindowController` listing markdown files; top search field filters and Return opens the top hit.
- [x] **Render diagnostics in preview** — sticky ribbon at top of preview counts mermaid/math/missing-image errors; click-to-jump scrolls to first issue.
- [x] **Configurable large-document thresholds** — PreferencesWindowController (⌘,) edits byte/line thresholds, debounce intervals, line-numbers toggle; persisted in `UserDefaults`.

Remaining:
- [x] **Find/replace stress on 5 MB+ documents** (commit `a2b9b2f`) — codified as a section in `samples/preview-smoke/CHECKLIST.md`. Manual walk against `Benchmarks/Fixtures/5mb.md`.
- [x] **Folder window file-system watching** (commit `5595a41`) — `FolderWatcher` uses FSEventStreamRef recursively under the open folder; bursts coalesce through a 250ms debounce.

---

## M4 — P3 deferred

Per MVP plan §3 M4. Priorities re-confirmed 2026-05-20:

- [x] **Sanitized inline SVG injection** (commit `122b65a`) — extended
      HTMLSanitizer with SVG-specific tag block list (foreignObject,
      animate, animateTransform, animateMotion, set, use, image,
      feImage) and attribute hardening (xlink:href joins href/src
      for javascript:/vbscript: stripping; data: stripped from
      href/xlink:href but allowed in img src). Four new tests cover
      dangerous SVG nesting, safe SVG primitives, xlink:href, and
      data-URL discrimination.
- [ ] Optional local PlantUML rendering — **deferred** post-MVP.
- [ ] DOM patching preview updates — **gated** on measurement;
      only pursue if full-reload becomes inadequate.
- [ ] Theme system — **deferred** until MVP is fully done.
- [ ] Deeper folder/workspace features — **scope undefined**;
      MVP plan kept this open ("if user demand is validated").
      Candidate scopes if/when picked up: tree view vs flat list,
      full-text search across folder, drag-and-drop file moves,
      recent-folders persistence, `.gitignore`-aware filtering,
      multi-window same-folder state. No concrete commitment yet.

---

## Nice improvements — proposed 2026-05-20

Outside the strict M0–M4 plan. Bundle into a post-MVP polish pass.

- [x] **Monospace font picker in Settings** (commit `fa9ae86`) —
      Settings dropdown over a curated list (SF Mono, Menlo, Monaco,
      JetBrains Mono, Iosevka, Fira Code, Courier New). Filtered to
      actually-installed families. Live-applied to all open editors
      via `editorFontDidChange` notification.
- [x] **Language tag chip in Preview code blocks** (commit `f318062`) —
      `tagCodeBlockLanguages` reads `class="language-foo"` and sets
      `data-writ-lang` on the `<pre>`. CSS `::before` rule renders a
      muted pill in the top-right corner.
- [x] **Optional TOC for HTML / PDF export** (commit `194a1bf`) —
      Settings toggle (default off). HTMLEmitter now emits
      `id="h-<slug>"` on headings via the new public `HeadingSlug`
      enum; `WritRender.TOCBuilder` walks OutlineExtractor headings
      into a nested `<ol>`. HTML export prepends the nav block + a
      bundled minimal TOC stylesheet; PDF export injects the same
      block into the live preview DOM via JS, prints, and removes
      it cleanly via a sentinel id.

---

## v0.4.8 — small polish release — **DONE 2026-06-04**

- [x] **Close #22 — render front matter as document header in
      HTML/PDF exports.** `DocumentHeaderBuilder` (new in WritRender)
      emits the `<header class="writ-doc-header">` block. HTML export
      adds it via `HTMLExporter.render(...)` + a `<meta name="keywords">`
      from `tags`. PDF export injects it into the live DOM (alongside
      a `writ-export` body class so CSS hides the dimmed FM dl) via
      `PreviewViewController.insertPDFExportDocHeader`; cleanup on
      `onExportFinished`. `FrontMatter.tags` now parses YAML inline /
      YAML block / TOML quoted-array forms; malformed tags don't
      abort. Tests in WritParser + WritRender lock both ends.

- [x] **Tighten nested-list / blockquote spacing in preview CSS.**
      Added `li > p:only-child { margin: 0 }`, `li > p:first-child`,
      `li > p:last-child` margin collapse, tighter `ul ul`/`ol ol`
      top margin, and `blockquote > :last-child { margin-bottom: 0 }`
      in `Resources/preview/theme.css`. Visual only; no parser
      changes.

- [x] **Settings: PDF font scale slider (default 85%).**
      New `ExportService.pdfFontScalePercent` (UserDefaults-backed,
      clamped to 60–100). `PreferencesWindowController` gains a
      tick-marked NSSlider with a live `XX %` readout. PDF export
      injects `@media print { html { font-size: X% } }` via a style
      element scoped to the print path; `html`-level scope cascades
      both `rem` headings and `em` body sizes proportionally.

- [x] **Editor relayout glitch after edits in scrolled documents.**
      Diagnosed as TextKit 2's viewport layout going stale after a
      `NSTextStorage.didProcessEditing` cycle (especially after the
      80ms async syntax highlighter's `setAttributes`+`addAttribute`
      pass over `fullRange`). `EditorViewController` now observes
      `didProcessEditingNotification` on its text storage and forces
      `textViewportLayoutController.layoutViewport()` + a
      `needsDisplay` on every storage edit. Catches both user
      keystrokes and the highlighter pass.

## v0.5.0 — milestone scope (confirmed 2026-06-04)

GitHub milestone "0.5.0" carries the post-0.4.8 issues. #11
(workspace/project) moved to 1.0.0 — too big to gate 0.5 on.

- [ ] **#22** — folded into 0.4.8 above.
- [ ] **#21** — Autolink bare URLs (GFM-style). Small. Likely a
      single `cmark` flag + an inline-text regex pass for cases
      cmark misses. Verify against `http://example.com.` (trailing
      dot must not be eaten) and Markdown autolinks `<…>` (keep
      working).
- [ ] **#19** — Alternative preview themes (serif / mono / sans,
      light + dark). Larger. Needs a theme bundle layout under
      `Resources/preview/themes/`, a Settings picker, and the JS
      bridge to swap stylesheets without a full reload.
- [ ] **#6** — Allow / bundle custom CSS for Preview. File-picker
      based — user points at a `.css`, we load it after the bundled
      theme. Should hot-reload on file change (FSEvents already in
      the codebase for folder watching).

### Deferred from 0.5.0 to 1.0.0 (2026-06-04)

- **#11** — Workspace / project file combination. Scope undefined
      and likely a feature of its own. Not gating 0.5.
