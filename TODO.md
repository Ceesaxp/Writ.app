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

---

## v0.4.9 — editor stability — **DONE 2026-06-08**

A focused follow-up to v0.4.8. The relayout-glitch fix in 0.4.8
addressed the blank band but exposed a different long-doc regression:
pressing Enter in a >screenful document caused the visible top line to
"snap" 10–17 lines. We chased it through multiple hypothesis cycles
(documented at length in the session log) and landed on three
compounding fixes.

- [x] **Stop the "snap on Enter" in long documents.** Root cause
      identified after extensive instrumentation: TextKit 2's
      `NSTextLayoutFragment`s are lazily measured, and the async
      syntax highlighter's `setAttributes(baseAttributes, range:
      fullRange)` + `addAttribute(.font, ...)` re-applied every 80ms
      invalidated font metrics across the *entire* document. TextKit
      silently re-measured fragments above the viewport, so the same
      `clipView.bounds.origin.y` ended up pointing at a different
      source line.

      The fix combines three things:
        1. `EditorViewController.fixedLineHeightParagraphStyle(for:)`
           sets `NSParagraphStyle.minimumLineHeight ==
           maximumLineHeight` derived from the base font's natural
           line height. Locks visual line rhythm so even when `.font`
           changes the affected fragments stay the same height.
        2. `MarkdownSyntaxHighlighter.applyHighlight` now accepts
           an optional `editedRange:` and re-applies attributes
           *only* within a scope expanded around the edit. The
           scope expansion reads the current storage's attribute
           runs (via `enumerateAttributes`) to absorb any stale
           highlighter styling that needs resetting — robust to
           the coordinate shifts of arbitrary edits because
           `NSTextStorage` auto-translates attribute ranges as text
           moves. Fragments *outside* the scope are never touched,
           so TextKit has nothing to re-measure.
        3. The storage delegate accumulates the union of edited
           ranges since the previous highlight pass (multiple
           keystrokes during the 80ms debounce coalesce into one
           scope). The highlighter call is wrapped with
           `undoManager.disableUndoRegistration()` so the
           presentation-only attribute changes don't pollute the
           user's undo stack.

- [x] **Fix auto-pair undo (`*`, `**`, `_`, etc.).** When the user
      typed `*` on a selection, the auto-pair logic in
      `EditorViewController.handleAutoPair` called
      `textView.shouldChangeText` *inside* the delegate's outer
      `shouldChangeText` callback — nesting that corrupted
      NSTextView's undo bookkeeping so Cmd-Z stopped at intermediate
      states (one stray `*` left over, or worse).

      Moved the auto-pair logic into `WritTextView.insertText(_:
      replacementRange:)` instead. That's a clean entry point above
      the delegate dispatch: `super.insertText(combined,
      replacementRange:)` triggers one `shouldChangeText` cycle and
      one undo group per keystroke. All auto-pair cases (wrap
      selection, insert pair at cursor, smart-skip closer, apostrophe
      inside a word) work correctly under repeated Cmd-Z.

---

## v0.4.10 — front-matter quality of life — **DONE 2026-06-08**

First of three staged drops toward the 0.5.0 milestone. Closes the
two front-matter issues filed alongside the v0.4.8 testing.

- [x] **Close #25 — insert front-matter shortcut.** New `Insert →
      Front Matter` menu item (⌥⌘Y) inserts a YAML template at the
      top of the document with `title`, `author`, and `date_created`
      fields (date pre-filled with today). The caret lands right
      after `title: ` so the user can start typing immediately.
      No-op if the document already has a front-matter block —
      uses `FrontMatterExtractor.extract` so the detection matches
      the renderer's view byte-for-byte. Implemented as
      `EditorViewController.insertFrontMatter()` wired through
      `DocumentWindowController.insertFrontMatterMenu(_:)`.

- [x] **Close #26 — no auto-pair inside front matter.** When the
      cursor sits inside the front-matter block, the markdown-only
      auto-pairs (`*`, `_`, `` ` ``, `$`) no longer balance —
      they're literal characters in YAML/TOML. Brackets and quotes
      (`(`, `[`, `{`, `"`, `'`) still pair because they're real
      YAML/TOML syntax for arrays, inline objects, and quoted
      values. Gated in `WritTextView.insertText` via the new
      `selectionIsInFrontMatter(selection:)` helper, which reuses
      `FrontMatterExtractor` for boundary detection.

---

## v0.4.11 — render-side post-processors — **DONE 2026-06-08**

Second of three staged drops toward 0.5.0. Two render-side
transformations of inline text nodes, both implemented in the new
`InlineTextTransform` helper in WritParser. They run only on `Text`
AST nodes inside the HTML emitter, so they don't touch source.

- [x] **Close #16 — emoji shortcodes (`:tada:` → 🎉).** Curated
      static dictionary of ~200 GitHub-style emoji shortcodes lives in
      `EmojiShortcodes.swift`. Scanner finds `:name:` tokens in `Text`
      content, looks up in the table, replaces matched ones with the
      glyph; unknown tokens pass through verbatim (no warning). `+1`
      / `-1` aliases included. Skipped for `Text` inside
      `InlineCode` / `CodeBlock` because those go through different
      emitter cases.

- [x] **Close #21 — autolink bare URLs (GFM-style).**
      `AutolinkExtractor.scan` walks text for `https?://…` and
      `www.…` URL patterns; the emitter wraps each match in
      `<a href="…">…</a>`. Trailing `.`, `,`, `;`, `:`, `!`, `?` are
      trimmed from the link's text; unbalanced trailing `)` is
      stripped so "(see https://foo.com)" keeps the closing paren
      outside the link. `www.` hosts get an `http://` prefix in the
      `href`. Suppressed when emitting inside an existing `Link` to
      avoid double-linking (tracked via `insideLink` state on the
      emitter).

---

## v0.4.12 — spell-check restraint — **DONE 2026-06-09**

Third small drop toward 0.5.0. Bridges to the bigger themes + custom
CSS work coming in the actual minor-version bump.

- [x] **Close #1 — restrict spell checker in code.** New Settings
      checkbox: **Skip spell check inside code (inline and fenced)**,
      off by default. When on, the spell checker ignores any text
      inside `` `…` `` and ` ``` …``` `. Implemented as two layers:
      (1) `MarkdownSyntaxHighlighter.allCodeRanges` now exposes all
      code spans (inline + block); the editor's `NSTextViewDelegate.
      textView(_:didCheckTextIn:…)` filter drops spell-check results
      that intersect them. (2) After each highlight pass — and on the
      preference's toggle-ON — `clearSpellingStateInCodeRanges()`
      walks the cached ranges and removes any squiggles that were
      drawn before the highlighter detected the code. Goes through
      `NSText.setSpellingState(_:range:)` and the TextKit 2
      `NSTextLayoutManager.removeRenderingAttribute(.spellingState,
      for:)` API — `.spellingState` is a *rendering* attribute, not a
      storage attribute, so `NSTextStorage.removeAttribute` is the
      wrong door. Toggling the preference OFF triggers
      `textView.checkTextInDocument(nil)` to bring previously-
      suppressed squiggles back.

## v0.5.0 — alternative preview themes + custom CSS — **DONE 2026-06-09**

The headline minor-version bump. Closes the last two issues on the
0.5.0 milestone — preview-pane theming and the user-CSS escape hatch.

- [x] **Close #19 — alternative preview themes.** Refactored the
      preview stylesheet so `theme.css` keeps the structural rules
      (code blocks, alerts, math/mermaid containers, front-matter
      card, doc-header) while a separate overlay in
      `Resources/preview/themes/` defines the typography and palette.
      Four themes ship: `github.css` (default, sentinel-only since
      `theme.css` carries the GitHub look), `serif.css` (Iowan Old
      Style, justified body, centered title block, drop-cap on the
      first paragraph after a doc-header), `mono.css` (SF Mono
      throughout, dashed dividers, man-page heading feel), and
      `sans.css` (Inter/SF Pro, airy spacing, ornamental `* * *`
      thematic break). Each has explicit light + dark via
      `prefers-color-scheme: dark`. New JS bridge function
      `window.Writ.setPreviewTheme(name)` swaps the
      `<link id="writ-theme">` href live; the Swift side observes
      `PreviewAppearance.didChange` and re-applies on the open
      preview pane without a document reload. HTML/PDF exports
      inline the active theme alongside the base CSS so the
      exported file matches the visible preview.

- [x] **Close #6 — custom CSS for preview.** Settings picks an
      arbitrary `.css` file via NSOpenPanel; the URL is persisted
      as a security-scoped bookmark so the choice survives sandbox
      restarts. The file's contents are inlined into the preview as
      a `<style id="writ-custom-style">` element managed by the
      JS bridge (`window.Writ.setCustomCSS(content)`) — inlining
      rather than `<link>`-ing avoids the cross-origin file:// load
      issues sandboxed WKWebViews trip over. Exports inline the same
      contents.

      Open follow-up: FSEvents-driven hot reload on file change
      (currently the user has to re-pick the file to pick up edits
      they made externally). Small; can land as 0.5.1.

### Deferred from 0.5.0 to 1.0.0 (2026-06-04)

- **#11** — Workspace / project file combination. Scope undefined
      and likely a feature of its own. Not gating 0.5.

## Unreleased — editor comfort

- [x] **Configurable source-view line height.** The editor's locked
      paragraph height was pinned to the font's exact natural metrics
      (`ascender + |descender| + leading`), which reads dense on long,
      heavily-formatted docs. Introduced
      `EditorViewController.lineHeightMultiple` (UserDefaults-backed,
      default 1.25, clamped 1.0–1.5) applied as a fixed multiple so
      `minimumLineHeight == maximumLineHeight` stays exact and the
      highlighter's per-fragment font swaps can't shift line positions.
      Preferences gets a stepped slider (1.00–1.50 in 0.05 steps);
      changes post `editorLineHeightDidChange` and every open editor
      re-applies live, same pattern as the editor-font preference. A
      font change now also recomputes the locked height, since it
      derives from the base font's metrics.
