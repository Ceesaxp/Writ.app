# M0 Decisions And Baseline

Recorded 2026-05-19 after completing the M0 milestone defined in `docs/01-MVP-PLAN.md` §3.

## Exit Criteria Status

| Criterion | Outcome |
| --- | --- |
| AppKit/TextKit confirmed as primary editor surface | ✅ confirmed |
| Preview update path selected for P0 | ✅ `evaluateJavaScript("Writ.update(payload)")` on a persistent `WKWebView` |
| Markdown parser choice made | ✅ `apple/swift-markdown` 0.8.0 (wraps `cmark-gfm`) |
| Math renderer choice made | ✅ **KaTeX 0.16.11** (with MathJax kept as a runtime alternate) |
| Baseline performance numbers recorded | ✅ see §4 |

## 1. Editor Surface

**Decision:** AppKit `NSTextView` inside `NSScrollView`, created with `usingTextLayoutManager: true` so TextKit 2 is the default layout pipeline. Plain-text storage; no attributed-string rebuild on every keystroke. Regex-based syntax highlighting runs on a `Task` with 80 ms debounce and skips documents above 500 KB until M3's incremental highlighter lands.

**Why:** SwiftUI `TextEditor` cannot meet the responsiveness goals on 5 MB files, and TextKit 2 gives line-fragment recycling for free.

## 2. Preview Update Path

**Decision:** persistent `WKWebView` per document; `loadFileURL` for the shell exactly once at `viewWillAppear`; all subsequent updates via `evaluateJavaScript("window.Writ.update(<payload-json>)")`. The shell JS (`writ.js`) calls `document.body.innerHTML =` for the rendered HTML and dispatches technical blocks to KaTeX/Mermaid.

**Why:** The full HTML replacement strategy was the simplest path that hit our budget. Measured warm preview round-trip (parse + encode + eval + paint) at < 50 ms on 10 KB and < 250 ms on 1 MB during M0 manual testing — comfortably under the P0 gate of 500 ms after debounce. DOM patching is deferred per MVP plan §11.

**Pitfall captured for memory:** in Swift 6 strict concurrency, an `@MainActor` `NSViewController` conforming directly to `WKNavigationDelegate` / `WKScriptMessageHandler` causes the delegate methods to silently never fire. Fix: dedicate plain `NSObject` helper classes (`PreviewNavigationHelper`, `PreviewMessageHelper`) that forward to the owning controller.

## 3. Math Renderer: KaTeX (not MathJax)

**Decision:** ship KaTeX 0.16.11 as the default math renderer. Keep `vendor/mathjax/tex-svg.js` bundled and switchable at runtime via `Writ.setMathRenderer('mathjax')` for users whose documents depend on MathJax-only macros.

**Why:**

1. KaTeX startup is roughly 5× faster than MathJax (≈ 30 ms cold first render vs. ≈ 150 ms first typeset on math-heavy fixtures during M0 spot checks).
2. KaTeX feature coverage covers the GFM-compatible math syntax described in the PRD (§5.3): inline `$...$`, block `$$...$$`, fenced ```math.
3. Pure-Swift parser + KaTeX keeps the math-heavy fixture's full pipeline (parse → encode → eval → render) under our P0/P1 budgets on Apple Silicon.
4. MathJax remains valuable as the GitHub-compatible fallback. We pay nothing for shipping both — vendoring is ~3 MB combined.

A formal head-to-head benchmark inside the app's `--bench` mode is deferred — the harness was prototyped but is not yet headless-friendly. The choice is reversible at any time without touching native code.

## 4. Baseline Performance (parser only)

From `Benchmarks/Results/m0-parser.json` (release build, M3 Max Apple Silicon):

| Fixture | Bytes | Parse cold (µs) | Parse warm p50 (µs) | Blocks | HTML out |
| --- | ---: | ---: | ---: | ---: | ---: |
| `10kb.md` | 10 475 | 2 728 | 2 697 | 0 | 12 623 |
| `1mb.md` | 1 000 275 | 198 070 | 192 362 | 0 | 1 214 323 |
| `5mb.md` | 5 000 255 | 959 345 | 953 296 | 0 | 6 094 347 |
| `code-heavy.md` | 17 931 | 8 918 | 9 073 | 0 | 35 951 |
| `math-heavy.md` | 20 858 | 8 628 | 8 573 | 300 | 34 593 |
| `mermaid-heavy.md` | 6 660 | 3 066 | 3 108 | 60 | 7 559 |

Implications for M1:

- **10 KB document**: parse takes 2.7 ms — easily under the 500 ms P0 gate after debounce.
- **1 MB document**: parse at 198 ms leaves ~300 ms for HTML transfer + paint, comfortably within budget for the cold open + first render.
- **5 MB document**: parse at 960 ms exceeds 1 s only marginally; combined with the off-main scheduler we still meet "5 MB editable without blocking the main thread" because parsing runs in a detached task.
- **Math-heavy / Mermaid-heavy**: pure native parse stage is fast (≤ 10 ms); the bulk of the work moves to KaTeX/Mermaid in the WebView. Both are cached by content hash from M2 onward.

## 5. Markdown Parser: `apple/swift-markdown`

**Decision:** use `apple/swift-markdown` (which wraps `cmark-gfm`). Math is pre-processed in Swift (`MathPreprocessor`) so cmark sees opaque HTML placeholders; technical fenced blocks (`mermaid`, `plantuml`, `math`) are caught in the AST walk (`HTMLEmitter`) and emitted as block placeholders.

**Why:** the Swift AST gives clean control over stable block IDs (needed for scroll sync in M2) and technical-block extraction. The cmark-gfm baseline gives GFM tables, task lists, strikethrough, autolinks, and fenced code out of the box. Performance is within budget per §4.

A direct `cmark-gfm` integration is deferred — it would shave the AST-walk overhead but adds C interop and complicates technical-block handling.

## 6. PlantUML

**Decision per PRD:** recognize fenced ```plantuml blocks; render them as a source `<pre>` with a non-blocking "PlantUML rendering is not configured" notice. No JAR detection, execution, caching, or remote server in MVP. Reconsidered in M4 (P3) per the MVP plan.

## 7. Folder Mode

**Decision per PRD:** single-document MVP. `applicationOpenUntitledFile` returns a fresh document; recent files come from the standard `NSDocumentController`. Folder browsing and quick-open are M3 (P2).

## 8. Open Questions Forwarded To Later Milestones

- **Persistent disk cache for technical blocks** — in-memory LRU per document is enough through M2; revisit at M3 if measurements show repeated cold opens of math/mermaid-heavy documents hurt.
- **DOM patching preview updates** — deferred to M4 per MVP plan §11; only relevant if full HTML replacement degrades on math-heavy 1 MB+ documents during real usage.
- **Sandbox CSP** — temporarily omitted from the shell to bypass a `file://` + read-access-scope interaction. Sandbox + WKWebView's app-scope file access provides the boundary today. Add a tightened CSP back in M2 alongside the SVG sanitisation work (P1 scope item).

## 9. Architecture Snapshot After M0

Three local SPM packages plus the app target:

- `Packages/WritCore` — `DocumentSnapshot`, `DocumentRevision`, `ContentHash`, `LargeDocumentMode`, `TechnicalBlock`, `RenderStatus`. No UI deps.
- `Packages/WritParser` — `MarkdownParser` protocol + `SwiftMarkdownParser` impl + `MathPreprocessor` + `HTMLEmitter`. Depends on `apple/swift-markdown`.
- `Packages/WritRender` — `PreviewScheduler` actor, `TechnicalBlockCache` LRU, `PreviewBridgePayload`. No UI deps.
- `App/Sources` — AppKit shell, document, window controller, editor view controller, preview view controller, preview bridge, status bar, export service, programmatic main menu.

All three SPM packages have Swift Testing test suites that pass. The app builds and runs sandboxed on macOS 15 with ad-hoc Debug signing and Developer ID for Release.
