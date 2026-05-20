# Preview Smoke Checklist

Manual walkthrough for `preview-smoke.md`. Open the fixture in Writ:

```sh
open -a Writ samples/preview-smoke/preview-smoke.md
```

Then go top-to-bottom and tick each item. Sections in the fixture are numbered
1–20; this list mirrors that numbering.

> **Layout note:** start in **Split** layout (⌥⌘3) so editor and preview are
> both visible. Toggle to **Preview Only** (⌥⌘2) when checking rendering
> details, back to **Source** (⌥⌘1) to inspect the source.

---

## 1. Headings

- [ ] H1 ("Writ Preview Smoke Test") is largest, distinct weight.
- [ ] H2 through H6 decrease in size monotonically.
- [ ] Body paragraph after the H6 has normal spacing from the heading above.

## 2. Paragraphs, line breaks, emphasis

- [ ] **bold**, *italic*, ***bold italic*** all visually distinct.
- [ ] ~~strikethrough~~ has a strike line.
- [ ] `inline code` is monospaced with a background tint.
- [ ] Hard break (two-space) collapses to a tight line break (not a paragraph gap).
- [ ] Backslash break renders the same as the two-space break.
- [ ] All Unicode samples (`café`, `日本語`, `Привет`, emojis) render correctly.

## 3. Lists

- [ ] Unordered list shows bullets; nested items indent.
- [ ] **bold inside an item** stays bold.
- [ ] Ordered list shows 7, 8, 9 (the `start=7` attribute is respected).
- [ ] Task list: checked boxes show ✓ for items 1–2; unchecked for items 3–4.
- [ ] Task list checkboxes are disabled (can't be clicked to toggle).

## 4. Block quotes

- [ ] First-level quote has a visible left border or indent.
- [ ] Second-level quote is visibly more indented than the first.
- [ ] Third-level quote is more indented again.
- [ ] After the nested block the text returns to first-level indent.

## 5. Horizontal rule

- [ ] A single `<hr>` line is visible between "Above the rule." and "Below the rule."

## 6. Tables

- [ ] Both tables render with header row + body rows; no broken markup.
- [ ] **Left** column is left-aligned, **Centered** is centered, **Right** is right-aligned (check by eye against numbers).
- [ ] Inline `**bold**`, `*italic*`, `` `code` `` inside a cell formats correctly.
- [ ] Emoji ✅ / ⚠️ / ❌ render in cells.

## 7. Code blocks

- [ ] Swift block: keywords (`import`, `struct`, `let`, `var`, `func`) colored by highlight.js.
- [ ] Python block: keywords / strings colored.
- [ ] JSON block: keys and string values colored differently.
- [ ] Plain fence (no language): monospaced, NOT colored.
- [ ] None of the code blocks overflow horizontally; horizontal scroll OK if needed.

## 8. Inline math (KaTeX)

- [ ] `$a^2 + b^2 = c^2$` shows superscripts (the `²` is raised, NOT just `2`).
- [ ] `$E = mc^2$` shows `²` raised.
- [ ] Fraction `$\frac{n!}{k!(n-k)!}$` shows a horizontal bar between numerator and denominator.
- [ ] `$\sqrt{...}$` shows a radical with the vinculum over the contents.
- [ ] Greek `σ` appears as a Greek letter (not the word "sigma").
- [ ] **Escaped dollars** `\$5.00 plus \$10.99 = \$15.99` render as **plain text**, NOT as math.

## 9. Block math (display mode)

- [ ] Quadratic formula has full `±` and a properly-sized radical.
- [ ] Sum has `n=1` below and `∞` above the Σ.
- [ ] Integral has `0` below and `∞` above the ∫.
- [ ] The 2×2 matrix renders with parentheses surrounding the rows.
- [ ] The aligned equations line up on the `=` sign.
- [ ] All four block-math regions are centered (display mode), not left-aligned inline.

## 10. Mermaid — flowchart

- [ ] The flowchart renders as an actual diagram (boxes + arrows), NOT as the raw fenced source.
- [ ] The diamond `{Has fileURL?}` has both `yes` and `no` edges going out.
- [ ] No "Mermaid is not loaded" error.

## 11. Mermaid — sequence diagram

- [ ] Four participant lanes are drawn: Editor / WritDocument / PreviewBridge / Preview JS.
- [ ] Arrows are drawn between lanes; final dashed arrow goes from `Preview JS` back to `PreviewBridge`.

## 12. Mermaid — class diagram

- [ ] Three class boxes (WritDocument, PreviewBridge, DocumentWindowController) render.
- [ ] Members listed inside each box.
- [ ] Association lines between boxes are present.

## 13. PlantUML passthrough

- [ ] A boxed block appears with "PlantUML rendering is not configured" notice.
- [ ] Below the notice, the raw `@startuml…@enduml` text is shown as a code block.
- [ ] The app does NOT crash or hang on the PlantUML block.

## 14. Referenced images (`writ-doc://`)

- [ ] `photo.png` displays as a rendered raster (240×120, dark background, three colored circles).
- [ ] `diagram.svg` displays (same composition, vector — sharp at any zoom).
- [ ] `badge.svg` displays the "writ / passing" pill.
- [ ] `does-not-exist.png` is **replaced** by a "missing image: …" inline placeholder.
- [ ] A diagnostics ribbon appears above the content saying **1 render issue** (or "1 issue"). Clicking the ribbon scrolls to the missing image.

## 15. Inline raw SVG

- [ ] A blue square (120×60) with a yellow circle in the middle renders.
- [ ] The SVG is sized, not blown up to full width or clipped.

## 16. Links

- [ ] Angle-bracket autolink `<https://www.gnu.org/>` renders as a clickable link.
- [ ] Bare URL `https://swift.org` is also clickable (GFM autolink).
- [ ] Named link "Apple Developer" shows underline/styling and has a tooltip on hover (title attribute).
- [ ] Reference-style "reference link" resolves to the GitHub URL.
- [ ] Fragment link "jump to math" scrolls the preview to the inline-math heading.
- [ ] Clicking any external link opens it in the default browser, NOT inside the preview pane.
- [ ] Email autolink `writ@example.com` opens the default mail handler.

## 17. HTML sanitisation

- [ ] `<kbd>` tags render with key-cap styling (browser default is enough).
- [ ] The amber-bordered note `<div>` renders with its styling intact.
- [ ] **No alert dialog appears** — the `<script>` was stripped.
- [ ] The "onerror-stripped" `<img>` does NOT trigger an alert; if it shows up as a broken image, that's fine (the test is "no script execution").

## 18. Long-line wrapping

- [ ] The single-long-line paragraph wraps inside the reading column.
- [ ] No horizontal scroll on the page.
- [ ] Toggle Outline (⌥⌘0) on/off — text re-wraps without overflow.

## 19. Edge cases

- [ ] The empty fenced block renders as an empty box, not a broken element.
- [ ] The single-character `### Z` heading renders.

## 20. End sentinel

- [ ] The closing paragraph is visible.
- [ ] The diagnostics ribbon shows **1 issue** in total (just the missing image).

---

## Cross-cutting checks

Run these once after working through 1–20:

- [ ] **Layout switching**: ⌥⌘1 / ⌥⌘2 / ⌥⌘3 cycles Source / Preview / Split with no rendering glitch.
- [ ] **Outline sidebar**: ⌥⌘0 toggles. The View menu reads *Hide Outline* when visible, *Show Outline* when collapsed.
- [ ] **Line numbers**: ⌥⌘L toggles. The View menu reads *Hide Line Numbers* / *Show Line Numbers* matching state.
- [ ] **Refresh preview**: ⌘R re-renders without losing scroll position more than ~1 line.
- [ ] **Scroll sync**: scrolling the editor moves the preview to track. Scrolling the preview moves the editor to track (only inside Split layout).
- [ ] **Export HTML** (⇧⌘E): produces an HTML file that, when opened in a browser, shows the SAME rendered content (math + mermaid included).
- [ ] **Export PDF** (⇧⌘P): produces a multi-page PDF including the math and mermaid renders (not placeholders).
- [ ] **External-scheme guard**: temporarily add `[bad](someapp://foo)` to the source; clicking it should **not** launch any handler (silently blocked per security guard).

---

## Large-document stress (M3 carry-over)

Run after the main walkthrough. Validates editor responsiveness on
5 MB+ documents and the `NSTextFinder` find/replace path.

Open the parser-bench fixture in Writ (it's 5 MB of synthesized
markdown, no math/mermaid):

```sh
open -a Writ Benchmarks/Fixtures/5mb.md
```

- [ ] **Open time**: window appears editable within ~1 s of the
      `open` invocation (subjective; corresponds to the M1 P0 gate).
- [ ] **Initial scroll**: page-down a few times. No stutter, no
      half-rendered frames.
- [ ] **Typing**: place caret near the end of the document, type a
      few characters. No visible lag.
- [ ] **Find (⌘F)**: type a common word (`the` is fine). Match
      count updates without freezing the UI. Find-next (⌘G) jumps
      through results responsively.
- [ ] **Find with case option**: toggle Match Case in the find bar.
      Result set updates immediately.
- [ ] **Replace (⌥⌘F)**: open the Replace interface. Replace one
      occurrence of a common short string with a slightly longer
      one. No hang. Replace-all on a unique short string. App stays
      responsive throughout.
- [ ] **Outline**: open the outline (⌥⌘0). It populates without
      visible delay (5 MB has many headings).
- [ ] **Preview**: switch to Preview Only (⌥⌘2). HTML rendering
      may take a couple of seconds but the UI does not beachball.

If any step fails, file the section number, the operation, the
approximate elapsed time, and any spinner / hang behaviour.

---

## Reporting

If anything fails:

1. Note the section number and the specific bullet.
2. Take a preview screenshot (⌘⇧4, select the preview pane).
3. Open `Console.app` and filter on subsystem `org.ceesaxp.Writ` — paste any errors/warnings logged since opening the fixture.
