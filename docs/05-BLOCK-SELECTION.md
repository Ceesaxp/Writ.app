# Block (rectangular) selection

Status: in progress — branch `feat/block-selection`.

BBEdit/Zed-style column selection: select a vertical rectangle across several
lines and edit every line at once. The motivating jobs are the small bulk
edits that otherwise cost one trip per line — turning N lines into a list,
adding `|` borders to a table, stripping a column of leading junk.

## 1. Scope

In:

- Rectangular selection by **⌥-drag** with the mouse.
- Rectangular selection by keyboard: **⌥⇧↑/↓** starts and grows the block
  vertically; once a block is live, **⌥⇧←/→** grows it horizontally.
- **Typing** into a block replaces every row's fragment with what you type —
  including the zero-width case, which inserts at N carets at once.
- **Delete / forward-delete**, **Cut**, **Copy** (newline-joined), **Paste**.
- **Esc** drops the block back to an ordinary caret.

Out (deliberately):

- Soft-wrap awareness. See §3.
- Space padding past end-of-line. See §3.
- Discontiguous free-form multi-cursor (⌥-click to add a caret anywhere).
  The block model is a strict rectangle; free multi-cursor is a different
  feature with a different state shape.

## 2. Key bindings

`⌥⇧←/→` is `moveWordLeft/RightAndModifySelection:` in
`StandardKeyBinding.dict` — word-extend, a binding worth keeping. So the
gesture is **hybrid**:

| Keys | No block active | Block active |
|---|---|---|
| `⌥⇧↑` / `⌥⇧↓` | start a block, grow it up/down | grow up/down |
| `⌥⇧←` / `⌥⇧→` | word-extend (stock AppKit, untouched) | grow left/right |
| `Esc` | stock `cancelOperation:` | drop the block |

`⌥⇧↑/↓` natively means `moveParagraphBackward/ForwardAndModifySelection:`,
which a line-oriented editor barely uses — that is the binding we spend.
Any unmodified caret move, or any click without ⌥, also drops the block.

## 3. Model: logical lines, character columns

Two simplifications, both chosen on purpose and both visible to the user.

**Logical lines, not display rows.** A "line" is a hard `\n` run. Under soft
wrap (`widthTracksTextView = true`, which Writ uses) a long wrapped line
counts as one row of the rectangle, so a block through it lands on its first
visual row only. BBEdit disables rectangular selection under soft wrap
entirely; tracking display rows instead would mean re-deriving the whole
block on every re-layout. Logical lines are right for the jobs this feature
exists for — lists and tables live on short lines — and roughly an order of
magnitude less machinery.

**Character columns, not x-coordinates.** A column is a UTF-16 code-unit
offset within its line. Writ's editor font is monospace by construction
(`candidateFontFamilies` is monospace-only), so column ≡ x-position for
ordinary text. Tabs and wide glyphs (CJK, emoji) break that equivalence: the
selection stays *character*-consistent and will look geometrically ragged on
such lines. That is the honest trade for a model that is testable without a
layout manager.

**Clamp, do not pad.** A line shorter than the block's left edge gets a
zero-length fragment at its end. Typing into an overhanging rectangle
appends at the short line's end rather than inserting spaces to reach the
column. Padding is a plausible future flag; silent whitespace is not a good
default.

**UTF-16 throughout.** Every offset, column and length is a UTF-16 code-unit
count, matching `NSTextView` selection semantics. Mixing `Character` indices
with UTF-16 offsets has already cost this project one crash.

## 4. Layers

`App/Sources/Editor/BlockSelection.swift` — pure value types, Foundation
only, no AppKit. `LineIndex` (UTF-16 line-start table), `BlockPosition`,
`BlockSelection`, `BlockEdit`. All the arithmetic lives here, which is why
it can be unit-tested in the hostless `WritTests` bundle:

- `fragmentRanges(in:)` — one `NSRange` per row, ascending, never spanning a
  newline, zero-length where the row is short or the block is zero-width.
- `copyString(from:index:)` — `\n`-joined fragments.
- `replacementEdits(with:in:)` — replace every fragment; sorted **descending**
  by location so applying them in order keeps later offsets valid.
- `pasteEdits(clipboard:in:)` — distribution rules in §5.

`App/Sources/Editor/WritTextView.swift` — the AppKit plumbing: ⌥-drag
tracking, the overridden move selectors, and the edit interception. Thin by
design; it owns the block state and delegates every decision to the model.

## 5. Paste distribution

Clipboard split on `\n`, discarding exactly one trailing newline. M clipboard
lines into N block rows:

| Case | Behaviour |
|---|---|
| M == 1 | that line goes into **every** row (the table-pipe case) |
| M == N | positional — row *i* gets line *i* |
| M > 1, M != N | **not** a block paste: one contiguous replacement of the whole block span with the clipboard verbatim |

The third rule is lossless and predictable. Distributing a mismatched
clipboard means silently dropping or duplicating the user's lines.

## 6. Known limitations

- A block through a soft-wrapped line covers its first visual row only (§3).
- Tabs and wide glyphs make the rectangle geometrically ragged (§3).
- No space padding past end-of-line (§3).
- The status bar's line:column readout follows the block's first row, since
  `textViewDidChangeSelection` reads `selectedRange()`.
