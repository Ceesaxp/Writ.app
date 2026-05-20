# Writ — Implementation TODO

Tracking against `docs/01-MVP-PLAN.md`. Strict milestone order: M0 → M1 → M2 → M3.

---

## M0 — **DONE 2026-05-19** (commit `0c2100b`)

All exit criteria met. Decisions and baseline numbers in `docs/03-M0-DECISIONS.md`.

---

## M1 — P0 core editor + preview — **largely done** (commit `cedc369`)

All P0 gate items met. See git log for details.

Outstanding M1 polish items (non-blocking, circle back as the session permits):
- [ ] Programmatic `⌘R` manual-refresh regression test (currently exercised manually)
- [ ] PDF export programmatic smoke test (currently exercised manually)
- [ ] Strict P0 perf gate measurements at exact 1 MB / 5 MB warm-launch boundaries (best-effort numbers were 1 MB → 1049 ms, 10 KB → 912 ms during M0)
- [ ] Undo/redo through `applyEditorText` round-trip regression test

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
- [ ] Find/replace verification on 5 MB+ documents (NSTextFinder is wired and should already work; not actually stress-tested in this session).
- [ ] Folder window: file-system watching so the list refreshes when files appear/disappear externally (currently snapshots on open).

---

## M4 — P3 deferred

(Per MVP plan §3 M4. Untouched.)

- [ ] Optional local PlantUML rendering
- [ ] Sanitized inline SVG injection
- [ ] DOM patching preview updates (only if measurement proves full reload becomes inadequate)
- [ ] Theme system
- [ ] Deeper folder/workspace features
