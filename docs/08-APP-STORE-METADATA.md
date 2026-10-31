# App Store Connect metadata

Copy for the Writ App Store listing. Companion to [07-APP-STORE.md](07-APP-STORE.md),
which covers the build and submission mechanics; this file is only the words.

Keep this file as the source of truth and edit it here rather than in App Store
Connect, so the next release can diff it. Every field below was measured against
Apple's limit, and the counts are in [§8](#8-field-lengths).

## 1. Fields you paste as-is

### App Name (limit 30)

```
Writ
```

### Subtitle (limit 30)

```
Markdown for technical writing
```

Exactly at the limit. A shorter alternate, if you want headroom:

```
Markdown for technical docs
```

### Promotional Text (limit 170)

The only field that can be changed **without submitting a new build**, so it is
written to stay true across versions — no version numbers, no "new in".

```
Plain text in, publication-quality preview out. Math, diagrams and highlighted code render offline, in a native editor that leaves your Markdown exactly as you wrote it.
```

### Keywords (limit 100)

Comma-separated, **no spaces** — spaces count against the limit.

```
latex,math,diagrams,documentation,docs,readme,preview,offline,editor,plaintext,notes,export,pdf,gfm
```

Deliberately omits `writ`, `markdown`, `technical` and `writing`: App Store
search already indexes the app name and subtitle, so repeating those words here
would waste the budget. Also omits `mermaid`, `katex` and `plantuml` — they are
third-party project names, and the space buys more in generic terms. They appear
in the description instead, where they are accurate context rather than search
bait.

### Description (limit 4000)

```
Writ is a fast, native macOS Markdown editor for technical writing.

Plain text in, publication-quality technical preview out. Markdown stays the canonical format: Writ never rewrites your file to suit itself, and there is no hidden rich-text layer and no proprietary document format.

The principle is WYWIWYM — What You Write Is What You Mean. You write Markdown, and Writ shows you what it means, including math, diagrams and code, without ever pretending to be the document itself.

BUILT FOR TECHNICAL DOCUMENTS

• GitHub-Flavored Markdown: tables with column alignment, task lists, strikethrough, autolinked URLs
• GitHub-style alert callouts — Note, Tip, Important, Warning and Caution
• Inline $…$ and display $$…$$ math, rendered with KaTeX, with MathJax bundled as an alternate
• Mermaid fenced blocks render as SVG diagrams: flowcharts, sequence, class, state and more
• Syntax-highlighted code in the preview, light and dark aware
• YAML and TOML front matter, with per-document switches for math and emoji rendering
• Local image and SVG references resolve relative to the document you are editing

A NATIVE EDITOR

Writ is built on AppKit and NSTextView, so the Mac behaviours you already know are simply there: real multi-level undo, the system find bar with incremental search, continuous spellcheck, autosave and Versions, window tabs and full screen. Autocorrect and smart substitutions stay out of your code.

• Block, or rectangular, selection: Option-drag to select a column and edit every line at once, with a single undo for the whole gesture
• Optional line numbers drawn in a native gutter
• Auto-paired brackets, quotes and fence markers
• An Insert menu for code, math and diagram blocks

THREE WAYS TO WORK

Source only, preview only, or both side by side. In split view the editor and the preview follow one another as you scroll, block by block, in both directions. Preview updates are debounced and the parsing runs off the main thread, so typing never waits for a render.

FINDING YOUR WAY AROUND

• An outline pane built from your headings — click a heading to jump to it
• Open a folder to get a sidebar of the Markdown files inside it, with filter-as-you-type
• A status bar showing word count, line and column, and render state

EXPORT WHAT YOU SAW

Export to HTML with the rendered math and diagrams intact and the stylesheet inlined, so one file travels anywhere. Export to PDF at US Letter or A4.

BUILT FOR LARGE FILES

Performance is treated as a product requirement, not an afterthought. Parsing and preview scheduling run off the main thread, a one-megabyte Markdown file opens to an editable window in under a second on Apple Silicon, and much larger documents stay responsive while you type.

LOCAL-FIRST, AND QUIET ABOUT IT

No account. No sync service. No telemetry. KaTeX, MathJax, Mermaid and syntax highlighting are all bundled with the app, so everyday rendering happens with no network connection at all.

Exactly one optional feature can make a network request. If you configure a PlantUML renderer URL in Settings, and a document opts in with plantuml: true in its front matter, then that document's PlantUML blocks are sent to the server you chose. Both conditions are required, neither is set by default, and no PlantUML server is bundled. Nothing else in Writ contacts the network.
```

### What's New in This Version

**Leave empty.** This is a first submission, so App Store Connect does not ask
for it. Add one at 0.8.0.

## 2. URLs

| Field | Value |
|---|---|
| Support URL | `https://github.com/Ceesaxp/Writ.app/issues` |
| Marketing URL | `https://ceesaxp.github.io/writ/` |
| Privacy Policy URL | `https://ceesaxp.github.io/writ/privacy.html` |

**Blocker on the Marketing URL.** That page currently leads with
*Download v0.6.0 (.dmg)*. Apple rejects listings whose linked pages push
distribution outside the App Store, so the mini-site CTA has to switch to the
Store before this URL goes in the listing. That is the change already decided
("free, lead with Store") — it just has not been made yet. Either make it, or
leave Marketing URL blank for the first submission; it is optional.

## 3. Category and rating

| Field | Value |
|---|---|
| Primary category | Productivity |
| Secondary category | Developer Tools |
| Age rating | 4+ (no objectionable content, no user-generated content, no web browsing) |

`LSApplicationCategoryType` in `project.yml` is already
`public.app-category.productivity`, which must agree with the primary category.

## 4. Copyright

App Store Connect wants the year and holder **without** a `©` glyph — it adds one.

```
2026 Andrei Popov
```

## 5. App Review Notes

Goes in *App Review Information → Notes*. Worth more care than the promotional
text: a reviewer who cannot find a feature in ninety seconds flags the build.

```
No account, login or demo credentials are needed. Writ is a document-based editor: launch it and start typing, or open any .md, .markdown or .txt file.

NETWORK USE DURING REVIEW: none will occur. Writ bundles KaTeX, MathJax, Mermaid and highlight.js, so all rendering is local. One optional feature can reach the network — PlantUML diagram rendering — and it requires BOTH a server URL that the user enters in Settings (no default is shipped, and no PlantUML server is bundled) AND a per-document opt-in via "plantuml: true" in the document's YAML front matter. Neither is set out of the box, so a default review session makes no network requests.

HOW TO EXERCISE THE MAIN FEATURES (about a minute):
1. Open a new document and paste any Markdown that includes a fenced code block, a table, and a ```mermaid block.
2. Press Option-Command-3 for split view: source on the left, live preview on the right. Scrolling either pane moves the other.
3. Press Option-Command-0 to show the outline pane, built from the document's headings; click a heading to jump.
4. For math, type $$e^{i\pi} + 1 = 0$$ on its own line; it renders with KaTeX in the preview.
5. For block selection, Option-drag a rectangle across several lines, then type to edit all of them at once.
6. File > Export brings up HTML and PDF export.

The app is sandboxed. Folder access (File > Open Folder…) uses a user-selected read-only entitlement, and access persists across launches via security-scoped bookmarks.
```

## 6. Screenshots and preview

Already produced, in `build/` (git-ignored — back them up before cleaning):

| Asset | Path |
|---|---|
| 5 screenshots, 2880x1800, alpha stripped | `build/screenshots/0{1..5}-*.png` |
| App preview video, 1920x1080 H.264 | `build/app-preview/writ-app-preview.mov` |

App Store Connect rejects PNGs with an alpha channel; these were flattened.
Accepted macOS screenshot sizes are 1280x800, 1440x900, 2560x1600 and 2880x1800.

## 7. What is deliberately NOT in the description

Each of these is a rejection risk or an unverifiable claim, and the reasoning is
recorded so a future edit does not reintroduce them.

- **No "MVP", "beta", "preview", "deferred", "coming soon", "in progress".**
  Apple rejects listings that present an app as incomplete or as a trial. The
  README and the mini-site use this language freely; the listing cannot.
- **No roadmap.** "Export with live math landing soon" and similar promise
  features that do not exist yet in a build under review.
- **No HTML-sanitiser or security claims.** A reviewer cannot verify them, and a
  store listing is a poor place to make a security assertion.
- **No footnotes.** Checked: the parser does not implement them. Tables,
  task lists, strikethrough, autolinks and GFM alerts are all implemented and
  are claimed.
- **No competitor comparisons and no "Electron".** The mini-site's framing is
  good marketing on your own domain and a liability in a store listing.
- **No price, and no "free".** App Store Connect handles pricing.
- **No "macOS 14+".** The Store derives compatibility from the binary.
- **No Homebrew or DMG mention.** Pointing at off-Store distribution is a
  rejection risk.
- **Scroll sync is described as "in split view"** because it is gated to
  `layoutMode == .split`. The unqualified claim would be wrong.

## 8. Field lengths

Measured, not estimated:

| Field | Limit | Used | Margin | |
|---|---:|---:|---:|---|
| App Name | 30 | 4 | 26 | OK |
| Subtitle | 30 | 30 | 0 | OK |
| Subtitle (alternate) | 30 | 27 | 3 | OK |
| Promotional Text | 170 | 169 | 1 | OK |
| Keywords | 100 | 99 | 1 | OK |
| Description | 4000 | 3338 | 662 | OK |
| App Review Notes | 4000 | 1477 | 2523 | OK |

Apple counts UTF-16 code units; every character used here is a single unit, so
these counts are what App Store Connect will show. Note how little headroom
Subtitle, Promotional Text and Keywords have — re-measure after any edit.
