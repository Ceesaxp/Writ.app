# Writ — Implementation TODO

Tracking against `docs/01-MVP-PLAN.md`. Strict milestone order: M0 → M1 → M2 → M3.

---

## M0 — Spikes, scaffolding, baseline performance — **DONE 2026-05-19**

All exit criteria met. Decisions and baseline numbers captured in `docs/03-M0-DECISIONS.md`.

- [x] Project scaffold (xcodegen + 3 SPM packages, app target, asset catalog, entitlements)
- [x] Benchmark fixtures generator + 6 fixtures (10 KB / 1 MB / 5 MB / code-heavy / math-heavy / mermaid-heavy)
- [x] Editor prototype: AppKit/TextKit 2 backed `NSTextView` in `NSScrollView`
- [x] Preview prototype: persistent `WKWebView` with bundled shell + KaTeX + MathJax + Mermaid + highlight.js
- [x] Parser spike: `apple/swift-markdown` (cmark-gfm wrapper), baseline numbers recorded
- [x] Math renderer choice: **KaTeX** default, MathJax bundled as alternate
- [x] Preview update path: `evaluateJavaScript("Writ.update(...)")` on persistent WebView (no DOM patching for MVP)
- [x] Code signing wired to team Q34D9AYJ95; Debug ad-hoc, Release Developer ID
- [x] End-to-end render verified on 10 KB, math-heavy, mermaid-heavy fixtures

---

## M1 — P0 core editor + preview (in progress)

Gate: `docs/01-MVP-PLAN.md` §3 M1 P0 gate.

### M1.1 — Document model finishing touches
- [ ] Open/save round-trip preserves UTF-8 exactly (no BOM unless input had one)
- [ ] Encoding fallback for legacy files (Latin-1 / Windows-1252)
- [ ] Autosave + Versions confirmed
- [ ] External file change detection — *moved to M3 per MVP plan §3 M3*

### M1.2 — Editor responsiveness
- [ ] Verify typing latency on 1 MB / 5 MB fixtures with debounced preview running
- [ ] Verify scroll FPS on 5 MB fixture
- [ ] Find / Replace via `NSTextFinder` confirmed
- [ ] Undo / redo through document → editor and document.applyEditorText round-trip
- [ ] Spellcheck behavior verified
- [ ] Native tabs verified

### M1.3 — Preview pipeline P0
- [ ] Manual refresh menu command (`⌘R`) wired and tested
- [ ] Debounce defaults (250 ms normal, 1500 ms large) verified on each fixture
- [ ] Large document mode auto-activation tested
- [ ] Inline render error display (no modal alerts on parse failure)
- [ ] No full-document attributed-string rebuild on keystroke (assertion test in `EditorViewController`)

### M1.4 — Split modes + toolbar polish
- [ ] Source / Split / Preview persists per-window across relaunches
- [ ] `⌥⌘1/2/3` shortcuts wired (already in `AppMenu`)
- [ ] Toolbar segmented control reflects current state on mode change from menu

### M1.5 — Export
- [ ] `Export HTML…` writes self-contained HTML with bundled CSS
- [ ] `Export PDF…` uses `WKPDFConfiguration` from preview, awaits final render
- [ ] `Print…` uses native print pipeline

### M1.6 — P0 perf gate measurements
- [ ] Warm launch < 1 s to editable window on Apple Silicon
- [ ] 1 MB file open < 1 s to editable
- [ ] 5 MB file open: editable, main thread not blocked
- [ ] 10 KB preview after debounce: < 500 ms
- [ ] WebView reused for document lifetime (assert no `loadFileURL` after first)

### M1.7 — Tests / housekeeping
- [ ] `WritDocument` open/save unit tests
- [ ] `PreviewScheduler` stale-result rejection regression test
- [ ] Status bar updates verified across rendering / current / failed transitions
- [ ] CI-friendly perf assertion (optional) using `BenchmarkRunner`

---

## M2 — P1 technical Markdown (gated by M1 P0 gate)

(To be expanded once M1 is complete.)

## M3 — P2 workflow + robustness (gated by M2 P1 gate)

(To be expanded once M2 is complete.)
