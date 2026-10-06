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

While a block is live:

| Input | Behaviour |
|---|---|
| any printable text | replaces every row's fragment; a zero-width block inserts at N carets |
| `Tab` | a block insert like any other character — column indent is useful |
| `Return`, or any insert containing `\n` | **drops the block** to a single caret, then inserts normally |
| `Backspace` / `Fwd Delete` | one grapheme per row, never crossing a line boundary (§3) |
| `⌘X` | copies the rectangle, then deletes it through the *delete* path — only that path filters no-op edits, so routing Cut through a plain replacement would register an empty undo group on a block that overhangs every row. On a zero-width block Cut does nothing, matching stock Cut on an empty selection |
| dead keys / marked text | drops the block, then composes normally |
| anything else | drops the block, then does its stock thing |

Fanning `Return` out across the rows would insert N newlines and dissolve
the very rows the rectangle is defined over, so it drops instead. Dead-key
composition goes through `setMarkedText`, which only ever marks the first of
several ranges, so it drops too.

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

**Deletes never cross a line boundary.** Backspace and forward-delete take
one grapheme per row. A caret at column 0 contributes no edit at all rather
than joining the line above: the ordinary single-caret behaviour there is a
join, but a rectangle is *defined over* its rows, and joining would dissolve
them. A row that contributes nothing is absent from the edit list rather
than present as a no-op, so a gesture that affects no row registers no undo
group for the user to press ⌘Z through.

**Clamp, do not pad.** A line shorter than the block's left edge gets a
zero-length fragment at its end. Typing into an overhanging rectangle
appends at the short line's end rather than inserting spaces to reach the
column. Padding is a plausible future flag; silent whitespace is not a good
default.

**UTF-16 throughout.** Every offset, column and length is a UTF-16 code-unit
count, matching `NSTextView` selection semantics. Mixing `Character` indices
with UTF-16 offsets has already cost this project one crash.

## 4. What AppKit will and will not do

Measured on a real TextKit 1 `NSTextView` (macOS 27.0, build 26A428) rather
than assumed. The spike source and raw output are not kept in the repo; the
conclusions are:

**Multiple *empty* selection ranges are impossible.** `selectedRanges =
[{0,0}, {10,0}, {13,0}]` comes back as a single range. It is not a bug —
`NSTextView.h` says so, above `-setSelectedRanges:affinity:stillSelecting:`:

> The return value of selectedRanges obeys the same restrictions, and in
> addition its elements are sorted, non-overlapping, non-contiguous, and
> (except for the case of a single range) have non-zero-length.

**Mixed sets silently drop their empty members.** `[{0,5}, {10,0}, {13,5}]`
returns two ranges. That is exactly the ragged-line case: a block overhanging
a short line produces a zero-length fragment for that row, and AppKit throws
it away.

Consequence: **the block state cannot live in `selectedRanges`.** Writ owns
it, and `selectedRanges` is used only as a rendering channel for the rows
that *are* non-empty — those AppKit preserves verbatim and highlights for
free, which is worth having. Zero-length rows get a caret Writ draws itself.

**Multiple non-empty ranges are preserved**, sorted, and `selectedRange()`
returns the first — so the status bar keeps working unchanged.

**Typing does not fan out.** `insertText(_:replacementRange:)` with three
ranges selected edits only the first and collapses the selection. Every
block edit must therefore be applied by Writ.

**But the multi-range edit API does fan out, and it accepts empty ranges.**
`shouldChangeText(inRanges:replacementStrings:)` returns true for all-empty
and mixed range sets — the sets that cannot be *selected* — and a single
`undo()` restores the whole document. So N-caret editing is fully supported
even though N-caret *selection* is not. This is the hinge the design turns
on: own the state, edit through the multi-range API, one undo group per
gesture.

**Copy is already `\n`-joined**, and AppKit puts a
`com.apple.cocoa.pasteboard.multiple-text-selection` flavour alongside the
text — a plist of *line counts per fragment* (verified: `[2, 1]` for a
two-line and a one-line fragment, not their character lengths). Writ still
builds the copy string from the model, because AppKit's version omits the
dropped empty rows and so loses the rectangle's shape.

**Hit-testing: use `textView.characterIndexForInsertion(at:)`.** It clamps a
point far past end-of-line to that line's own end and never bleeds onto the
next line. The lower-level
`characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)` returns
the line's end index with `fraction == 1.0`, so the usual
`fraction >= 0.5 ? index + 1 : index` rounding *does* bleed to the next
line's column 0. Below the last line, `characterIndexForInsertion` correctly
returns the phantom trailing position.

**Undo does not restore the selection shape.** No edit path restores the
multi-range selection on undo; the block collapses. Restoring it would mean
registering that separately, which this version does not do.

## 5. Layers

`App/Sources/Editor/BlockSelection.swift` — pure value types, Foundation
only, no AppKit. `LineIndex` (UTF-16 line-start table), `BlockPosition`,
`BlockSelection`, `BlockEdit`. All the arithmetic lives here, which is why
it can be unit-tested in the hostless `WritTests` bundle:

- `fragmentRanges(in:)` — one `NSRange` per row, ascending, never spanning a
  newline, zero-length where the row is short or the block is zero-width.
  Every row's range is kept off grapheme interiors, because a rectangle
  edge that splits a surrogate pair makes `replaceCharacters` write invalid
  UTF-16 into the document. Non-empty rows snap **outward** to whole
  composed character sequences. A zero-length row keeps length 0 — widening
  a caret would turn "insert here" into "replace this" — but its *location*
  snaps back to the start of the grapheme it sits in. Both clamp to the
  row's own line, because Foundation joins a `\n` to a combining mark that
  follows it, so an unclamped snap at column 0 reaches onto the line above.
- `copyString(in:)` — `\n`-joined fragments.
- `replacementEdits(with:in:)` — replace every fragment; sorted **descending**
  by location so applying them in order keeps later offsets valid.
- `pasteEdits(clipboard:in:)` — distribution rules in §6.

`App/Sources/Editor/WritTextView.swift` — the AppKit plumbing: ⌥-drag
tracking, the overridden move selectors, and the edit interception. Thin by
design; it owns the block state and delegates every decision to the model.

### When the block must be dropped

The block holds line/column coordinates, so any change it did not make
invalidates it. Applying stale coordinates to a changed document would write
edits into the wrong place — so rather than enumerate the paths that can
invalidate it, the view drops the block at two choke points and defaults to
dropping everywhere else:

- **Text changed underneath it** — `NSTextStorage.didProcessEditingNotification`,
  which the view already observes for the front-matter cache. Undo, Find &
  Replace and `setSource` all arrive here. Guarded by a flag so the block's
  *own* edits do not drop it, and **filtered on `.editedCharacters`**: the
  syntax highlighter re-styles the document as a separate attribute-only pass
  ~80 ms after every edit, so dropping on attribute edits would make the
  rectangle silently vanish a moment after each keystroke. Attributes cannot
  invalidate a line/column coordinate, which is the whole reason this choke
  point exists. (`editedMask` is measured as `2` for a character edit and `1`
  for an attribute-only one.)
- **Selection changed from outside** — the `setSelectedRange(s)` overrides.
  A plain click, ⌘F and any programmatic selection pass through here, and so
  does the plain `selectedRanges =` setter. **Both** flags must exempt it, not
  just the display-refresh one: `NSTextStorage.replaceCharacters` makes AppKit
  re-set the selection around the edited range, and that arrives at this
  override indistinguishably from an external change. Exempting only the
  display refresh drops the block on every one of its own edits.

`doCommand(by:)` handles the block selectors explicitly and **drops the block
in its default case**, so an unhandled command can never leave the block and
`selectedRanges` disagreeing.

A `LineIndex` is built once when the block starts and reused for every drag
event and keypress, then discarded with the block. Rebuilding it per
mouse-dragged event would be an O(document) scan on every mouse sample.

## 6. Paste distribution

Clipboard split on `\n`, discarding exactly one trailing newline. M clipboard
lines into N block rows:

| Case | Behaviour |
|---|---|
| M == 1 | that line goes into **every** row (the table-pipe case) |
| M == N | positional — row *i* gets line *i* |
| M > 1, M != N | **not** a block paste: one contiguous replacement of the whole block span with the clipboard verbatim |

The third rule is lossless and predictable. Distributing a mismatched
clipboard means silently dropping or duplicating the user's lines.

## 7. Known limitations

- A block through a soft-wrapped line covers its first visual row only (§3).
- Tabs and wide glyphs make the rectangle geometrically ragged (§3).
- No space padding past end-of-line (§3).
- The status bar's line:column readout follows the block's first row, since
  `textViewDidChangeSelection` reads `selectedRange()`.
- Rows AppKit refuses to highlight (the zero-length ones) get a caret Writ
  draws itself. It does not blink in step with the real insertion point.
- Dead-key / marked-text composition drops the block rather than composing
  into every row.
- After a backspace the new column is derived from the head row's grapheme,
  so on rows whose characters have different UTF-16 widths the carets can
  drift a unit or two apart. Cosmetic, and exact for ASCII.
- Undo restores the text but not the rectangle (§4).
- AppKit draws its own insertion indicator on the head row, above
  `draw(_:)`, so that one caret may blink or look slightly wider than the
  solid 1pt carets Writ draws on the other rows.
- ⌥-double-click collapses to a plain caret instead of selecting a word.

## 8. Manual verification

The ⌥-drag tracking loop and the caret drawing cannot be checked headlessly
— `NSTextView.mouseDown` runs a modal event-tracking loop that hangs a test
process, and posting a synthetic mouse-up first does not rescue it. So they
are verified by hand. Everything else in this document is covered by tests
in `App/Tests/WritTextViewBlockSelectionTests.swift` and
`WritTextViewBlockGestureTests.swift`.

**Quit any running copy of Writ first**, or LaunchServices routes the
fixture to the installed `/Applications/Writ.app` on the shared bundle id
and the build under test comes up empty.

Fixture — save as `block.md`, *with* a trailing newline after `kappa ten`:

```
alpha one
bb
gamma three
delta four
epsilon five
zeta six
eta seven
theta eight
iota nine
kappa ten
```

| # | Step | Expected |
|---|---|---|
| 1 | ⌥-drag from before the `a` of `one` on line 1, down-right to mid-`three` on line 3 | A rectangle; left and right edges vertically aligned across lines 1–3 |
| 2 | The same drag in reverse — line 3 up-left to line 1 | An identical rectangle; direction must not matter |
| 3 | Shrink the window to ~6 visible lines, ⌥-drag from line 1 downward, hold the mouse still below the bottom edge for ~3 s | The document keeps scrolling and the rectangle grows with it. One step then a stall means the periodic-event path is broken |
| 4 | ⌥-click once on line 5, no drag | A plain blinking caret, no highlight, no extra carets |
| 5 | Caret on line 4, then ⌥⇧↓ four times, then type `- ` | A column of carets down lines 4–8 at one x; all five rows gain the prefix; one ⌘Z restores all five |
| 6 | With the rectangle from #1 live, look at line 2 (`bb`) | A caret at its end rather than a highlight — it is shorter than the block's left edge |
| 7 | Caret on line 10 (`kappa ten`), then ⌥⇧↓ once | A caret on the empty phantom line below it. Nothing drawn means the `extraLineFragmentTextContainer` branch is wrong |
| 8 | With a block live: type `X`; ⌘Z; ⌘C and paste elsewhere; ⌘X; ⌘Z; ⌘V; Backspace | `X` replaces every fragment at once. ⌘C gives newline-joined fragments *including an empty line for `bb`*. Backspace eats one character per row and never joins lines. Each gesture is exactly one ⌘Z |
| 9 | With a block live, click once elsewhere in the text | The rectangle disappears, leaving one ordinary caret. A surviving highlight or stray caret is a hole in the `setSelectedRange(s)` choke point (§5), not in `mouseDown` |
| 10 | Click the preview pane to move focus, then ⌥-drag in the editor and type immediately | The editor takes focus and the typing fans out — `mouseDown` skips `super`, so it takes first responder itself |
