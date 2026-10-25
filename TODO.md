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
  - **Unblocked** during the block-selection work: the conflict was the *test host*, not the test bundle. `App/Tests/WritTextViewHarness.swift` drives the production `WritTextView` on a real TextKit 1 stack in an off-screen window, with no run loop and no test host — `insertText`, `deleteBackward`, `copy` and undo all respond synchronously. Any future NSTextView-level regression can now be covered directly.

---

## M2 — P1 technical Markdown — **largely done** (commit `b7dee04`+)

All headline P1 features shipped: GFM-compatible math, KaTeX + MathJax, Mermaid, JS render cache, technical-aware HTML export, status bar, insert-block menu, table alignment, etc.

Outstanding M2 items:
- [x] **Referenced local `.svg` / `.png` / `.jpg`** (commit `e9af7ea`) — `WritDocSchemeHandler` resolves `writ-doc:///<path>` against the document's directory, sandbox-safe.
- [x] **Two-way scroll sync** (commit `4012bab`) — writ.js posts `previewScrolled` on debounced scroll; the editor scrolls to match. Ping-pong is prevented by mutual suppression flags.
- [x] **Preview sanitization** (commit `4012bab`) — `HTMLSanitizer` strips dangerous tags + event handlers + `javascript:` URLs from raw `HTMLBlock` / `InlineHTML` source.
- [x] **Auto-pair brackets / quotes / fence markers** (commit `4012bab`) — `EditorViewController.handleAutoPair` inserts the closing pair and positions the cursor between; wraps existing selections; smart skip past closing chars; apostrophe-after-letter preserved for contractions.
- [ ] Tests for insert-block helpers and the scroll-sync delegate hook.
      **The stated blocker is gone**: `App/Tests/WritTextViewHarness.swift`
      (0.6.0) drives the production `WritTextView` headlessly, so these are
      now ordinary tests rather than deferred ones. Same applies to
      auto-pair (EDIT-05) and the Markdown formatting commands (EDIT-07),
      which `docs/05-FEATURE-VALIDATION.md` still classes Manual-only.

---

## M3 — P2 workflow + robustness — **mostly done** (commits `04ce009` … `74190c7`)

Done:
- [x] **External file change detection** — `WritDocument.presentedItemDidChange` shows an NSAlert sheet, unsaved-edits aware, `revert(toContentsOf:)` keeps editor + preview in sync.
- [x] **Optional line numbers** — custom `LineNumberGutter` NSView walks `NSLayoutManager.enumerateLineFragments`, top-aligns numbers on wrapped lines. Default on; View > Show Line Numbers (⌥⌘L). *(Corrected 2026-10-25: this entry described the TextKit 2 `NSTextLayoutManager.enumerateTextLayoutFragments` API; the gutter was rewritten for TK1 with the editor and the note was never updated.)*
- [x] **AST-driven incremental syntax highlighter** — `SyntaxSpanExtractor` builds spans from `swift-markdown`'s tree + line-level scans for math / list / task / table separators; honours block boundaries.
- [x] **Block-aware scroll sync** — `HTMLEmitter` emits `data-writ-line`; preview JS `scrollToSourceLine(line, fallback)` aligns the matching block.
- [x] **Improved HTML export bundling** — inlines theme + KaTeX + highlight.js CSS so exported math, code, and typography render without external assets.
- [x] **Simple folder open + quick open** — File > Open Folder… (⇧⌘O) opens a `FolderWindowController` listing markdown files; top search field filters and Return opens the top hit.
- [x] **Render diagnostics in preview** — sticky ribbon at top of preview counts mermaid/math/missing-image errors; click-to-jump scrolls to first issue.
- [x] **Configurable large-document thresholds** — PreferencesWindowController (⌘,) edits byte/line thresholds, debounce intervals, line-numbers toggle; persisted in `UserDefaults`.

Remaining:
- [~] **Find/replace stress on 5 MB+ documents** (commit `a2b9b2f`) — the
      *checklist section* was written (`samples/preview-smoke/CHECKLIST.md`,
      manual walk against `Benchmarks/Fixtures/5mb.md`). **Not actually
      closed**, on two counts, both found in the 2026-10-25 plan review:
      no record exists of the walk ever being run, and the MVP plan's M3
      item is "*Improved* find/replace behavior for large documents" —
      find/replace is still stock `NSTextFinder` with no large-document
      work. Decide whether stock is adequate (then run the walk and record
      it) or whether the plan item still stands.
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
- [x] Theme system — **shipped in 0.5.0**, ahead of its M4 slot: four
      preview themes (`github`, `serif`, `mono`, `sans`) plus the custom-CSS
      escape hatch. *(Corrected 2026-10-25; this line still read "deferred".)*
      Related open item: issue #3, fonts bundling — the themes name Iowan Old
      Style, Inter and SF Pro and degrade silently on a machine without them.
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

      *Historical note (2026-10-25): this fix is **gone from the code** and
      the diagnosis no longer applies. It was specific to TextKit 2's
      viewport layout; the editor has since moved to TextKit 1, which lays
      out eagerly, and `layoutViewport()` appears nowhere in the sources.
      Kept for the record of why the migration was worth doing.*

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

      *Status note (2026-10-25): parts 1 and 2/3 below **survive** on
      TextKit 1 — `fixedLineHeightParagraphStyle` and the highlighter's
      `editedRange` scope expansion are both still in the code and still
      load-bearing. The TextKit 2 fragment-measurement diagnosis that
      motivated them is historical.*

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

      Follow-up **done**: FSEvents-driven hot reload on file change ships
      as `App/Sources/Preview/CustomCSSWatcher.swift`; the user no longer
      has to re-pick the file. *(Corrected 2026-10-25; this read as an open
      follow-up.)*

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

## Unreleased — editor bug fixes (diagnosed + fixed 2026-07-15)

- [x] **Plain-text paste** — `WritTextView` pasted rich text (browser/chat
      lists bring hanging-indent `NSParagraphStyle`s that the highlighter
      deliberately never repairs → phantom hanging indents + per-paragraph
      line-height drift). Fixed: `paste(_:)` overridden → `pasteAsPlainText`;
      `typingAttributes`/`defaultParagraphStyle` seeded at setup;
      `reloadSource()` routes through `setSource` (the `.string =` setter
      styled the whole doc from caret typing attributes); highlighter now
      reasserts the locked paragraph style over its scope as self-heal
      (covers rich-text drag-and-drop too).
- [x] **Scroll-sync echo fix** — replaced timer-based suppression (leaky
      overlapping 250 ms windows in `writ.js`, 0.25 s `asyncAfter` in
      `EditorViewController`) with an expected-position handshake on both
      sides: a scroll landing where the pane was programmatically sent is
      swallowed regardless of timing; any other position clears the
      expectation and resumes broadcasting. Editor side clamps the target
      origin up front because `setBoundsOrigin` notifies synchronously.
- [x] **Continuous sync gated to Split mode** — no editor↔preview scroll
      traffic in Source-only / Preview-only. `setLayout` now does a
      one-shot alignment when a hidden pane is revealed: source→* pushes
      `editor.currentScrollPosition()`; preview→* pulls
      `window.Writ.currentTopLine()` (new) via
      `PreviewViewController.currentTopSourceLine(completion:)`.
      Split → single pane needs no alignment (surviving pane keeps its
      position). Remaining known coarseness: preview→editor alignment
      lands on block starts; fractional-position interpolation is a
      possible follow-up polish.

## 0.6.0 — block (rectangular) selection

BBEdit/Zed-style column selection. ⌥-drag, or ⌥⇧↑/↓ to start a block and
⌥⇧←/→ to widen a live one; `Esc` drops it. Typing replaces every row's
fragment, and a zero-width block inserts at N carets at once — which is
the point of the feature: turning N lines into a list, adding `|` borders
to a table, stripping a column of leading junk. Design, the measured
AppKit behaviour it rests on, and the manual checklist are in
`docs/06-BLOCK-SELECTION.md`.

113 tests (57 new), manual checklist §8 passed in full, app builds without
warnings.

- [x] **Pure model** — `BlockSelection`, `LineIndex`, `BlockEdit`:
      fragments, copy string, and replacement / paste / backspace /
      forward-delete edit plans. AppKit-free so it tests hostlessly.
- [x] **The block cannot live in `selectedRanges`** — AppKit collapses
      multiple empty ranges to one and silently drops the empty members of
      a mixed set (`NSTextView.h` documents it; a spike confirmed it). The
      view owns the state and uses `selectedRanges` only to render the
      non-empty rows, drawing its own carets for the rest. The multi-range
      *edit* API does accept empty ranges, which is the only reason
      N-caret editing is possible at all.
- [x] **Grapheme safety** — fragment edges snap outward to whole composed
      character sequences and carets snap to the grapheme start, both
      clamped to their own line. A rectangle applies one column number to
      every row, so a valid boundary on one line can be the midpoint of a
      surrogate pair on the next; without the snap `replaceCharacters`
      writes invalid UTF-16 into the document. The line clamp is
      load-bearing too — Foundation joins a `\n` to a combining mark that
      *follows* it, so an unclamped snap at column 0 reaches onto the line
      above.
- [x] **Hit-testing via `characterIndexForInsertion(at:)`** — the
      lower-level `characterIndex(for:in:fractionOf…)` returns a line's own
      end with `fraction == 1.0`, so the conventional
      `fraction >= 0.5 ? index + 1 : index` rounding lands on the *next*
      line's column 0 and dragging right drifts a line down.
- [x] **Two drop choke points** rather than enumerating every path that
      can invalidate the block, with `doCommand(by:)` defaulting to drop.
      The storage choke point filters on `.editedCharacters`: the syntax
      highlighter re-styles the document as a separate attribute-only pass
      ~80 ms after every edit, so dropping on attribute edits would make
      the rectangle silently vanish a moment after each keystroke —
      invisible to a test, certain in the app.
- [x] **Headless NSTextView harness** — `App/Tests/WritTextViewHarness.swift`.
      The M1 item above recorded app-level NSTextView tests as blocked by a
      Swift 6 / executable-host conflict; the blocker was the test *host*,
      not the bundle. The harness runs the production view on the
      production TextKit 1 stack in an off-screen window with no run loop.
      Note for anyone extending it: `NSTextView.mouseDown` runs a modal
      event-tracking loop and hangs a test process, and a synthetic
      mouse-up does not rescue it — drive the keyboard through
      `doCommand(by:)` instead.

Known limitations, all recorded in `docs/06-BLOCK-SELECTION.md` §7: a block
through a soft-wrapped line covers its first visual row only (logical
lines, as BBEdit does — it disables rectangular selection under wrap
entirely); tabs and wide glyphs make the rectangle geometrically ragged;
no space padding past end-of-line; undo restores the text but not the
rectangle; the head row's caret may blink where the others are solid,
since AppKit draws its own indicator above `draw(_:)`.

- [ ] ⌥-double-click collapses to a plain caret instead of selecting a
      word (known rough edge)

## 0.5.6 — PDF export crash fixes

- [x] **PDF export killed the app from a background thread** (reported
      2026-10-01, crashed on macOS 27) — `EXC_BREAKPOINT` with top frame
      `WebKit::crashDueToApplicationCallingMainThreadOnlyWebKitAPIFromBackgroundThread`.
      AppKit runs WKWebView's `NSPrintOperation` on a thread it spawns
      itself (`-[NSConcretePrintOperation _continueModalOperationToTheEnd:]`
      under `__NSThread__start__`), so the `runModal` `didRun:` selector
      arrives off-main. `PrintCompletionHandler` forwarded it through in
      place, putting the whole teardown chain on that thread:
      `printDidComplete`, the `onExportFinished` closure, the three JS
      teardown calls and the `createPDF` fallback — all main-thread-only
      WebKit API, which WebKit answers by killing the process.
      Fix: hop to main once, unconditionally, in
      `PrintCompletionHandler.complete(success:)`. One boundary covers
      every downstream call. Latent since 0.4.8; the default PDF font
      scale of 85% put `removePDFExportFontScale` on the teardown path,
      so it fired on *every* export at default settings.
      The compiler could not catch it: a non-`Sendable` closure stored as
      a plain function value loses the main-actor isolation it was formed
      with, so Swift 6 mode sees nothing. Covered by
      `App/Tests/PrintCompletionHandlerTests.swift` in the new hostless
      `WritTests` bundle — the project's first app-level tests.

- [x] **PDF export trapped when the preview had never been shown**
      (reported 2026-10-05) — "Unexpectedly found nil while implicitly
      unwrapping an Optional value" in the export DOM injections.
      Source-only layout collapses the preview's `NSSplitViewItem`, and
      AppKit never asks a collapsed item for its view, so `loadView()`
      never ran, `webView` (a `WKWebView!`) stayed nil and the shell was
      never loaded. Every PDF export from Source-only layout trapped,
      whatever the export settings — only *which* helper went first
      varied.
      Fix, in three parts:
      1. `evaluateExportJS` — one helper all six injections route
         through, guarding the webview and still calling its completion
         so the export's completion chain cannot hang;
      2. `prepareForExport` — forces the view to load, issues the shell
         load, then waits for the JS bridge and the first render against
         a shared deadline. `WritDocument` re-queues the source first,
         but only when the preview is cold: a late `Writ.update()` would
         replace `#writ-content` and wipe the injected TOC/header;
      3. a temporary print host. A collapsed split item never adds its
         view to the window *at all*, so the webview had no superview and
         no window, and WebKit printed correctly-paginated but entirely
         blank pages (5 373 bytes). An off-screen `NSWindow` does not
         work — the window server reports it occluded, WebKit stops
         treating the page as visible, still blank. What works is parking
         the webview as the rear-most subview of the document window for
         the duration of the print, where the opaque split view hides it.
      Verified end to end: Source-only and Split exports now produce
      byte-identical 5-page A4 PDFs with real text, and a screenshot
      burst across the export shows no visible window change.

- [x] **Hardening from the adversarial review of the above** — the
      Source-only fix introduced a multi-second wait between accepting the
      save panel and printing, which made several latent paths reachable:
      1. the modal host window came from `NSApplication.shared.mainWindow`,
         nil while the app is inactive, and the nil branch called
         `op.run()` — a permanent main-thread deadlock. The document
         window is now threaded down as a non-optional and that branch is
         deleted. With two documents open `mainWindow` could also resolve
         to the *other* document's window;
      2. one shared wait token meant a second export retired the first's
         completion without calling it — no file, no failure report, and a
         chained `onReady` closure left installed forever, closing a
         retain cycle through the document and window controller. Replaced
         by per-wait `OneShotWait` latches (`OneShotWait.swift`, 8 tests);
      3. the render wait's result was discarded and shared the bridge
         wait's leftover budget, so a blank export could be reported as
         "Exported" — a blank 5-page A4 file is ~5 KB, well clear of the
         2 KB blank-output guard. Each phase now has its own budget and
         the export fails when nothing rendered;
      4. exports are serialized. Two at once produced two blank files, one
         `didRun:` callback and then a crash in
         `-[NSConcretePrintOperation _finishModalOperation]`;
      5. the document window is brought forward before printing — WebKit
         will not draw for a window the window server considers hidden,
         and the export wrote a blank file and called it success.
      The print-host parking was re-tested rather than assumed: with it
      stubbed out, 3/3 cold Source-only exports produced 5-page A4 PDFs
      with zero text (5 373 bytes vs 64 319), with the DOM snapshot
      confirming the content was present at print time. It stays.

- [ ] **Known limitation: very large documents can export blank on the
      first, cold export.** A 5 MB document exported from a never-shown
      preview produced 2 609 correctly-paginated pages with no text
      (1 134 184 bytes — past the 2 KB guard); a second export moments
      later was correct. The `rendered` message means "`Writ.update()`
      returned", not "WebKit finished laying out the DOM", and the 0.4 s
      settle delay is not enough at that size. Needs a real
      layout-quiesced signal (double `requestAnimationFrame` +
      `document.fonts.ready`, or a size probe on `#writ-content`) rather
      than a longer guess. Normal-sized documents are unaffected.

## 0.5.5 — window sizing

- [x] **Window ratchets wider on layout switch** (reported 2026-08-21) —
      Source → Preview → Source grew the window by a whole editor pane,
      repeatedly. Root cause: `setLayout(.source)` uncollapsed the editor
      *before* collapsing the preview, so both panes were briefly
      uncollapsed. A collapsed pane remembers the thickness it had when
      collapsed — the full content width in a single-pane mode — so the
      pair demanded ~2× the available width and NSSplitViewController
      satisfied it by widening the window
      (`-[NSSplitViewController _collapse:splitViewItem:animated:]` →
      `-[NSWindow _changeWindowFrameFromConstraintsIfNecessary]`,
      captured with an NSWindow `setFrame` probe). The window never
      shrinks back, so it ratcheted on every switch; nothing to do with
      the document being unsaved, and not the multi-monitor autosave
      rescale theory that was on the branch.
      Fix, in `DocumentWindowController`:
      1. collapse the outgoing pane before uncollapsing the incoming one;
      2. `collapseBehavior = .preferResizingSiblingsWithFixedSplitView` on
         both panes (states the intent; the SDK header warns `.default`
         "may change over time");
      3. pin/restore `window.frame` across the whole mutation, since
         entering Split legitimately needs both panes at once, then
         re-apply the persisted divider fraction.
      Verified: 20 consecutive switches across every Source/Split/Preview
      combination leave the frame byte-identical. The outline sidebar
      still grows the window by its own width, which is intended.

---

## Open from the 2026-10-25 plan review

Found by reading `docs/01-MVP-PLAN.md` back against the code rather than
against this file. Implementation is essentially complete against the plan;
these are gaps in **evidence**, plus one measured regression.

- [ ] **Parse path is 3–6× slower than the recorded P0 gate.** Measured, and
      isolated against both the host OS and the `swift-markdown` version —
      it is Writ's own code. Same-library comparison vs `f62d678`:
      10 KB 2.9×, 1 MB 3.5× (157 → 555 ms), 5 MB 6.1× (795 ms → 4 872 ms).
      Full matrix and method in `docs/04-M1-PERF-GATE.md`. The shape is
      diagnostic: cost scales with document **size** and is flat against
      block **density** (`code-heavy` and `mermaid-heavy` both 1.09×), and
      cost per byte roughly doubles from 1 MB to 5 MB — so it is
      super-linear per-line or per-character work. `data-writ-line` is ruled
      out by inspection. **Bisected to `fc438ca`** ("feat: emoji shortcodes
      + autolink bare URLs", v0.4.11) — one commit accounts for the whole
      regression; everything after it is flat.
      Cause: `AutolinkExtractor.findNextStart` probes every character
      position for each candidate scheme via a `startsWith` helper that
      bridges the needle to `NSString`, allocates a substring, and calls
      `lowercased()` on both sides — ~3 M calls and ~12 M String
      allocations for a 1 MB document, which in `1mb.md` find **zero**
      URLs. Secondary: `EmojiShortcodes.substitute` rebuilds the whole
      string via `Character` iteration whenever a `:` appears anywhere.
      Fix shape and the measurement matrix are in
      `docs/04-M1-PERF-GATE.md`. **Not yet fixed.**
- [ ] **`math-heavy` is ~12× its M0 number and unexplained** — ~8.5 ms at
      M0, ~80 ms when the gate doc was written, ~105 ms now. It measures
      the same at `cae9d46`, `fc438ca` and `master`, so it is **not** the
      autolink bug above; it predates that bisect range and has never been
      investigated. The gate doc has carried it as "filed for follow-up"
      since 2026-05-20 without it ever reaching this file.
- [ ] **Four of the plan's nine required measurements were never taken** —
      MVP plan §5. Absent: export time for representative technical
      documents; memory usage at 1 MB and at 5 MB. Qualitative only, and
      taken on TextKit 2 so they describe a stack the editor no longer uses:
      typing latency during active debounce, editor scroll frame pacing.
- [ ] **No execution record for the manual verification surface.**
      `docs/05-FEATURE-VALIDATION.md` classes 25 of 46 capabilities
      Manual-only — including EDIT-01 (the editor itself), PREV-01/03,
      EXP-02 and PERF-02. `git log` shows the smoke checklist being *added*,
      and one `fix: four UI/UX issues found in preview smoke walk-through`,
      so a walk happened once early. There is no "last run" field and no
      per-release record, so for any current build the answer to "has this
      been exercised?" is unknown. Consider a dated run log, or convert what
      the harness can now reach (below) and shrink the manual surface.
- [ ] **Convert the newly-automatable Manual rows.** The 0.6.0 headless
      harness removes the stated blocker for EDIT-05 (auto-pair), EDIT-07
      (Markdown formatting commands), and the two M2 tests deferred above.
      All are pure text transforms. One packet.
- [ ] **Issue #3, fonts bundling** — a quality gap in a *shipped* feature,
      not a deferral: the 0.5.0 themes name Iowan Old Style, Inter and
      SF Pro and degrade silently on a machine without them.

Still open elsewhere in this file, unchanged by the review: the large-document
cold-export blank (0.5.6), and ⌥-double-click in block selection (0.6.0).
Correctly deferred per the plan: PlantUML rendering, DOM patching (gated on
measurement — note the numbers above now argue *for* revisiting it),
issue #11 workspace/project, issues #23/#24 preview annotations.
