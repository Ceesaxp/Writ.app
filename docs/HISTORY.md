# Document history

Snapshot-based version history for the document the writer is editing.
Pairs with `ANNOTATIONS.md` — both features write into the same
`.writ-sidecar/` directory.

## What we're solving

The everyday "I just deleted something I want back" / "what did I write
an hour ago" / "give me yesterday's version" moments. **Not** full
git-style branching, merging, push-to-remote, or multi-author
collaboration — those needs are already served by external tools (git,
Tower, Working Copy) and shouldn't drag the editor's UX into developer
territory.

## Scope decision

- **Sidecar primary, git-aware secondary.** Writ's own snapshot store
  is the default model — works on any folder, no setup, no git mental
  model. If a `.git/` directory is detected anywhere up the doc's
  parent chain, Writ surfaces commits that touched the doc as
  additional snapshots, alongside its own. We never run `git init`
  ourselves.
- **Single-doc focus.** Each doc carries its own history. Multi-doc
  project history is a separate decision (lives or dies with whatever
  multi-doc story replaces today's single-doc model — see #11
  "Named open-sets").
- **Linear history.** No branches, no named drafts inside the history.
  A timeline of restorable points. Simple to reason about; matches the
  way writers think about revisions.

## Shared sidecar layout

Both `HISTORY.md` and `ANNOTATIONS.md` write into the same per-doc
sidecar folder. Hidden by default (leading dot) so it doesn't clutter
Finder, but visible enough that the user can poke around if curious.

```
my-essay.md
.my-essay.md.writ-sidecar/
  manifest.json          { "version": 1 }
  annotations.json       (per ANNOTATIONS.md)
  history/
    index.json           snapshot index (timestamps, kinds, sizes)
    20260616T143012Z.snap  full text dump
    20260616T144501Z.snap
    ...
```

Rationale for **per-doc, dot-prefixed, suffixed with `.writ-sidecar`**:

- **Per-doc** (not one shared folder for the directory) — rename and
  delete cleanly follow the doc; no orphaned metadata for a doc that
  was moved elsewhere.
- **Dot-prefixed** — hidden in Finder by default, doesn't litter the
  user's directory listing. Visible to anyone who toggles hidden files
  or uses the shell. Not pretending to be invisible.
- **Suffixed `.writ-sidecar`** — clearly attributable to Writ if the
  user goes looking, and namespaces against other tools' sidecars.

Move/rename handling: Writ's existing `NSFilePresenter` work catches
rename events on the doc. The sidecar folder must be renamed in lockstep.

## Snapshot mechanism

### When to snapshot

The default heuristic favors writers who hit ⌘S often:

- **Every explicit save** (⌘S, Save As) → record a snapshot, kind `explicit`.
- **Autosave-in-place** → record a snapshot, kind `auto`, but **only
  if** the content actually differs from the most recent snapshot
  (avoid duplicates from no-op autosaves).
- **Quiet-period merge** — back-to-back snapshots within a short
  window (e.g. 30 s) collapse into the latest one, so we don't
  generate hundreds of near-identical files when the user mashes ⌘S
  during a refactor session.

### What's in a snapshot

A `<timestamp>.snap` file is the **raw UTF-8 markdown source** of the
doc at that instant. No metadata embedded in the file itself — keep it
diffable with external tools.

Metadata lives in `history/index.json`:

```json
{
  "version": 1,
  "snapshots": [
    {
      "id": "20260616T143012Z",
      "createdAt": "2026-06-16T14:30:12Z",
      "kind": "explicit",
      "byteSize": 28412,
      "note": null
    }
  ]
}
```

`note` is optional — a user-supplied label for an "explicit checkpoint"
gesture (e.g., "Before reorganizing chapter 3"). MVP can omit it.

### Storage

Plain text files, no compression in MVP. A 30 KB doc snapshotted 100
times is 3 MB — trivial. If real-world use shows snapshot directories
ballooning, add gzip later (`.snap.gz`).

### Retention

Configurable, default **keep last 100 snapshots OR last 30 days,
whichever yields more**. Old `auto` snapshots prune first; `explicit`
snapshots are sticky and prune only if the user manually deletes them.
This protects "I ⌘S-after-each-paragraph" workflow without unbounded
disk growth.

## Git-aware mode

If `git` finds the doc's directory inside a working tree, Writ:

1. **Surfaces git history alongside its own.** The history panel shows
   commits that touched this doc (`git log --follow -- <doc>`) with
   sha, message, author, timestamp, restore action. Each git commit is
   treated as a read-only snapshot — restore copies the doc's blob at
   that commit back into the working file.
2. **Optionally auto-commits on save** (opt-in toggle in Preferences,
   off by default). When on, each save → `git add <doc> && git commit
   -m "<template>"`. Default template: `"Writ autosave: <doc-name> at
   <iso-time>"`. We never push.
3. **Never runs `git init`.** Git-aware mode is detection-only. If the
   user wants a git repo, they make one themselves.

Conflict handling is out of scope — if a save fails because the index
is dirty or the file changed under us, surface the error and let the
user resolve via their git tool of choice. Writ doesn't try to be a
merge tool.

## UI

### History pane

- A new pane (or a tab inside the existing Outline pane — see open
  questions) listing snapshots newest-first.
- Each row: timestamp (relative — "2 min ago"), kind glyph (auto vs
  explicit vs git commit), byte delta from previous snapshot, optional
  note.
- Click a row → opens the diff view.
- Right-click → Restore, Add note, Delete (only for own-sidecar
  snapshots; git commits are read-only).

### Diff view

The hard part. Token-level word diff looks terrible on prose. Plan:

1. **Split both versions into paragraphs** (separated by blank lines).
2. **Paragraph-level Myers diff** keyed by a similarity hash of the
   paragraph's normalized text — so "minor edit inside a paragraph"
   shows as "this paragraph changed" rather than "deleted whole
   paragraph + added similar paragraph".
3. **Inside changed paragraphs**, word-level diff with strikethrough
   for removed and underline for added.
4. **Layout**: inline-with-strikethrough by default (reads more
   naturally for prose), with a side-by-side toggle for users who
   prefer the conventional code-diff look.

### Restore

"Restore" replaces the current source with the snapshot's content
**after taking a fresh snapshot of the pre-restore state** — so a
mistaken restore is itself a single ⌘Z away (well, "restore the
previous snapshot" away).

### Quick-revert affordance

Single keyboard shortcut to "restore the snapshot immediately before
the most recent one" — for the muscle-memory undo-past-Cmd-Z case.

## Persistence model

- Snapshot write happens **after** the doc save completes successfully
  (we don't want a snapshot of a save that failed).
- Snapshot writes are atomic (temp file + rename), same as the
  annotations sidecar.
- Index updates are also atomic.
- If the sidecar directory doesn't exist, create it. If it exists but
  is malformed (e.g., `index.json` parse fails), recreate `index.json`
  by scanning `history/*.snap` and rebuilding entries from filenames.
  Never silently lose snapshots.

## Open questions (for review later)

1. **Where does the History pane live?** New third pane alongside
   Outline + Annotations? Tab inside the Outline pane (Outline /
   Annotations / History)? Sheet/popover from a toolbar button?
2. **Snapshot trigger granularity.** Every save (default) feels right,
   but a "every N minutes while editing" timer would catch crashes
   between saves. Worth adding? If so, do those count toward retention
   the same as save-triggered snapshots?
3. **Note authoring.** Does the writer add notes only after the fact
   (right-click → Add note) or also via a "Save with note…" shortcut
   that prompts at save-time? The latter creates explicit checkpoints
   on demand.
4. **Annotations + history interaction.** When the writer restores
   snapshot from before some annotations were added, what happens to
   those annotations? Three reasonable choices: (a) annotations are
   independent of history — they persist across restores untouched
   (could orphan if their anchored text is gone); (b) restore snapshots
   include their annotations — restoring rewinds both; (c) annotations
   carry their own history within the sidecar and the user picks.
5. **Diff view orientation default.** Inline (prose-friendly) vs
   side-by-side (conventional). My instinct is inline by default, but
   this might invert if users expect git-style.
6. **Retention policy controls.** Surface in Preferences? Hardcoded?
   Per-doc override?
7. **Untitled / draft docs.** A doc with no file URL has nowhere to
   put a sidecar. Hold snapshots in memory until first save? Disable
   the feature for unsaved docs? Auto-save to a scratch location?
8. **Git-aware diff source.** When showing a git commit's diff, do we
   render git's raw diff or do we run our own paragraph-aware prose
   diff against the commit blob? The latter is more consistent with
   sidecar diffs but slower; the former is faster but uglier.
9. **Renamed-doc git history.** `git log --follow` handles renames
   inside git's view. Across a Writ-side rename of a non-git doc, the
   sidecar folder must move too — should the history panel
   transparently merge the pre-rename and post-rename history, or
   show them as two separate stretches?
10. **Sidecar visibility.** Hidden by default (`.writ-sidecar`
    suffix) — should there be a Preference to make it visible? Some
    users might prefer the breadcrumb in Finder.

## Out of scope for this pass

- Git branches, merges, pushes, conflict resolution UI.
- Multi-author / collaboration / real-time.
- Cross-doc history (history for a folder/project as a unit).
- Snapshot encryption.
- Replaying snapshots as an animation (the "Word version history
  playback" gimmick).
- Exporting snapshot history to a separate format (later, possibly
  via "Export to git repo" action).
