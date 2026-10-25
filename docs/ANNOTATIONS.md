Best approach: **sidecar annotations with optional inline Markdown markers**.

## Recommended model

Keep the `.md` file as the source of truth.

Store annotations separately:

```text
my-essay.md
my-essay.md.annotations.json
```

Or, for document sets:

```text
MyBook.mdset/
  chapters/
    01-intro.md
    02-market.md
  annotations/
    01-intro.annotations.json
    02-market.annotations.json
  assets/
  manifest.json
```

The Markdown remains clean, portable, editable anywhere.

## Annotation structure

Each annotation should anchor to text using more than one method:

```json
{
  "version": 1,
  "document": "chapters/01-intro.md",
  "annotations": [
    {
      "id": "a1",
      "type": "highlight",
      "color": "yellow",
      "quote": "Markdown has no native annotation model",
      "startOffset": 842,
      "endOffset": 881,
      "contextBefore": "This opens up a can of worms, since ",
      "contextAfter": ". It could be done in HTML",
      "note": "Important product constraint.",
      "createdAt": "2026-06-09T10:30:00Z"
    }
  ]
}
```

Do **not** rely only on offsets. Offsets break when text changes. Use:

1. character offsets for speed;
2. quoted selected text;
3. surrounding context;
4. fuzzy re-anchoring when the file changes.

This is roughly how robust annotation systems work.

## Optional inline mode

For users who want Git-native annotations, offer an explicit mode using Markdown-compatible HTML comments:

```markdown
Markdown has no native annotation model
<!-- app:annotation {"id":"a1","type":"highlight","color":"yellow"} -->
```

Or wrapping:

```markdown
<span data-app-highlight="a1">Markdown has no native annotation model</span>
```

But I would **not** make this the default. It pollutes the Markdown and can interfere with other renderers.

## Product decision

I’d offer three levels:

### 1. Clean Markdown mode — default

Annotations live in sidecars. Best UX, clean files, good for writers.

### 2. Portable project mode

A folder/package bundle:

```text
Project.mdset/
```

Great for books, research notes, long-form authoring.

### 3. Embedded annotation mode

Optional, explicit, for people who want annotations to survive Git diffs and plain file movement.

## Export behavior

When exporting:

HTML: render highlights as spans.

```html
<span class="highlight-yellow">...</span>
```

PDF: render visual highlights and optionally margin notes.

Markdown export: either strip annotations or optionally include them as comments.

## My view

The best architecture is:

**Markdown stays Markdown. Annotations are application metadata. Project bundles make the metadata manageable. Embedded annotations are an escape hatch, not the core model.**

That gives you the right balance: elegant app experience, sane version control, recoverability, and no betrayal of Markdown’s simplicity.

---

## Scope decision (2026-06-09)

First version ships **sidecar only, single-doc, Preview-pane only** for both viewing and authoring. Specifically:

- **No embedded mode.** HTML comments and `<span>` wraps pollute the markdown and shift offsets — not worth the ergonomic cost. May reconsider later as an export option, not as a storage mode.
- **No `.mdset/` project bundles in this pass.** That's a separate product decision (a project format) that shouldn't ride on annotation scope. The 1.0.0 plan has #11 "Named open-sets" which is a lighter version of the same idea; revisit `.mdset/` after that lands.
- **No Source-view authoring or display.** Annotations live in Preview only. Source view stays clean markdown. (Composing a JSON-anchored note inside a plain-text source pane is impractical UX anyway.)

What this means concretely: annotation is a **reading-and-reviewing feature**, not a drafting feature. You highlight and comment on text that's already been written and is being read in Preview.

## Implementation notes

### Anchoring (the load-bearing decision)

Anchor in **markdown source character space** (UTF-16 offsets, same as everything else in Writ), not HTML element identity. HTML changes on every re-render; source character ranges don't. Multi-method anchor as the existing doc proposes — `(startOffset, endOffset, quote, contextBefore, contextAfter)`.

### Preview selection → source range mechanism

The hard part: a user's `window.getSelection()` lands in the rendered HTML, but the sidecar needs a markdown source range.

Path:

1. **Renderer tags blocks with source ranges.** We already emit `data-writ-block="N"` for scroll sync. Extend that to carry the block's source UTF-16 offset + length. We have the `LineTable` in `WritParser` now; the cmark column → UTF-16 conversion is cheap.
2. **JS captures the selection** via `window.getSelection()`, walks the anchor/focus nodes up to find the nearest `data-writ-block` ancestor, computes the relative offset within the block's plain text (DOM text-content walk).
3. **JS posts back to Swift** via the existing `window.Writ` bridge with `{ blockId, relativeStart, length, quote, contextBefore, contextAfter }`.
4. **Swift resolves to absolute source range** using the block's source offset + the relative offset. Writes the sidecar entry.
5. **Subsequent renders** inject `<span class="writ-annotation" data-id="...">` wraps based on the sidecar ranges, applied during the render pass in `WritRender` (not as a post-hoc DOM walk).

### Re-anchoring after edits

On doc load (and possibly on every save):

1. Try the stored character range first — if the substring at `[startOffset, endOffset]` still matches `quote`, accept.
2. If shifted but `quote + contextBefore + contextAfter` still appears as a substring of the source, re-anchor to that new position.
3. If the quote can't be found uniquely (multiple matches, or no match), mark the annotation **orphaned** — see open question 5 for UX.

### Persistence

Annotations live inside the **shared `.writ-sidecar/` folder** that's
also used by the snapshot/history feature. See `HISTORY.md` for the
full layout and rationale — short version, for a doc `my-essay.md`:

```
my-essay.md
.my-essay.md.writ-sidecar/
  manifest.json          { "version": 1 }
  annotations.json       <-- this feature
  history/               <-- snapshots feature
    ...
```

- File at `.<docname>.writ-sidecar/annotations.json` next to the doc.
- Written atomically (temp file + rename) under `NSFileCoordinator` so
  external presenters see consistent state.
- Debounce writes (~500 ms after last edit) so rapid annotation
  creation doesn't thrash the disk.
- Loaded eagerly when the document opens; reconciled with the current
  source via the re-anchor pass.
- If the sidecar folder doesn't exist yet, create it on first
  annotation write. If only the `annotations.json` is missing (folder
  exists because of history), treat as "no annotations".

## Open questions (for review later)

1. **Annotation types beyond highlight.** Just highlight? Or also: comment-only (a marker at a point without highlighted text), underline, strikethrough? Each adds complexity to render + UX but each addresses a different use case (highlight = "this is important", comment = "I want to say something here", underline = "this is a key term", strikethrough = "this is wrong / outdated").
2. **Note display.** When an annotation has note text attached, where does it show? Inline tooltip on hover in Preview? Margin gutter next to the paragraph? Sidebar list only? Combination?
3. **Sidebar.** New dedicated annotations pane alongside Outline (third pane), or reuse the Outline pane with tabs (Outline / Annotations)? Or popover from a toolbar button?
4. **Color palette.** Fixed small palette (3–5 colors)? Named with semantic intent (*question* / *important* / *unclear* / *agreed* / *follow-up*)? Just neutral colors? User-customizable?
5. **Orphan UX.** When a user edits the annotated text away and fuzzy re-anchor fails: silent orphan panel that the user must visit, prompt at next save ("3 annotations lost their anchor — review now / later / discard"), or auto-delete after some grace period?
6. **Annotation authoring entry points.** Floating popover near the selection? Toolbar button when text is selected? Keyboard shortcut? Right-click context menu? All of the above?
7. **Editing existing annotations.** Click on a highlight → opens the note editor inline? Or jumps to the sidebar entry? Or both?
8. **Source-view indicator.** Even though annotations don't render in Source view, should the gutter show *something* — a colored dot next to annotated lines — so the writer knows where reviewer-marked passages live? Or zero source-view signal at all?
9. **Conflict with the existing block-level `data-writ-block` scroll sync.** The same data attribute now carries two semantic loads (scroll alignment + annotation anchoring). Worth splitting into `data-writ-block` + `data-writ-source-offset` to keep concerns separate, or fine to overload?
10. **What if a doc has no file URL yet (Untitled / draft)?** Sidecar needs a path. Either disable annotation entirely for unsaved docs, or write the sidecar lazily once the doc is saved (and hold annotations in memory until then).

## Out of scope for this pass

- PDF margin notes (the proposal mentions this — substantial WKWebView-print work; defer).
- HTML export with embedded highlight spans (could land alongside MVP cheaply — flag for the spec).
- Search across annotations (probably 1.0.0+ once we have project bundles or open-sets).
- Multiple authors / per-author colors / collaboration.
- Convert sidecar → embedded comment-mode export.

