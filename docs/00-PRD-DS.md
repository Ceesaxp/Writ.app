# Product Design Document: Writ (MVP)

## 1. Overview

**Writ** is a native macOS Markdown editor for writers who work with code, math, diagrams, and plain text. The MVP focuses on editing, live preview, and export of standard Markdown with GitHub-style math, Mermaid, PlantUML, and SVG support. The app prioritizes performance, offline use, and native platform integration over feature bloat.

**Core promise:** *“Writes like a text editor, renders like a documentation platform.”*

## 2. User Personas (MVP Focus)

- **Technical writer** – needs code blocks, math, and diagrams inline.
- **Developer/Engineer** – writes docs with embedded Mermaid/PlantUML.
- **Student/Researcher** – writes LaTeX math without leaving a lightweight editor.

## 3. High-Level Goals

- **Native macOS** (Swift + AppKit) – fast, low memory, system look & feel.
- **Plain-text first** – no rich-text mode, but syntax‑highlighted Markdown.
- **Live preview** (split-view or side-by-side) – updates on save or debounced edit.
- **GitHub-flavored math** – `$inline$` and `$$block$$` via LaTeX (KaTeX or MathJax).
- **Diagram support** – Mermaid, PlantUML (as local or optional remote), inline SVG.
- **Code block support** – syntax highlighting for common languages.
- **Export** – HTML (single file) and PDF (via macOS print dialog).

## 4. Non-Goals (MVP)

- WYSIWYG / rich-text editing (no toolbar for bold/italic).
- Cloud sync, collaborative editing, or mobile version.
- Custom themes or plugin system.
- Document management / library (single-file editor).
- Direct PlantUML server integration (local rendering only, can be extended).

## 5. Feature Specification (MVP)

### 5.1 Editor Core
- **Plain text editing** with native text view (NSTextView) or SwiftUI TextView.
- **Markdown syntax highlighting** (headings, lists, bold, italic, links, images, code fences, math delimiters).
- **Auto-pairing** of `**`, `*`, `$`, `$$`, backticks.
- **Indent/outdent support** for lists and code blocks.
- **Line numbers** (optional toggle).

### 5.2 Live Preview
- **Split view** (horizontal or vertical) – editor left / preview right (configurable).
- **Preview engine** – embedded WebKit view with sanitized HTML + CSS.
- **Rendering on** – manual trigger (Cmd+R) *or* debounced (500ms idle after edit).
- **Math rendering** – KaTeX (faster, lighter) or MathJax (more complete). MVP: KaTeX.
- **Diagram rendering**:
  - Mermaid – rendered via Mermaid.js in WebKit.
  - PlantUML – local rendering via `plantuml.jar` (user-installed) or fallback to text.
  - SVG – rendered directly as inline SVG.
- **Scroll sync** (basic) – approximate scroll linking between editor and preview.
- **Code block styling** – light/dark mode aware (follows system appearance).

### 5.3 Supported Syntax (GitHub Flavored Markdown + Extras)
- Headings, lists, tables, task lists, blockquotes.
- Fenced code blocks with language hint (e.g., \`\`\`javascript).
- **Math** – `$...$` inline, `$$...$$` display (GitHub syntax).
- **Mermaid** – ` ```mermaid ` block.
- **PlantUML** – ` ```plantuml ` block.
- **SVG** – embedded as `![](diagram.svg)` or raw `<svg>` (sanitized).
- Strikethrough, autolinks, footnotes, definition lists.

### 5.4 File Operations
- **Open** – `.md`, `.markdown`, `.txt`.
- **Save** – native macOS save panel (plain UTF-8 Markdown).
- **Auto-save** (Versions API).
- **Export** → HTML (bundled CSS + KaTeX/Mermaid) and PDF (via WebKit print).

### 5.5 Native macOS Features
- **Menu bar** – standard Edit menu + View (toggle preview, zoom), Insert (math block, code block, mermaid/plantuml template).
- **Keyboard shortcuts** – Cmd+R (refresh preview), Cmd+Shift+P (toggle split orientation), Cmd+E (export).
- **System accent color support** – selection and cursor.
- **Full-screen support** – distraction-free mode.
- **Touch Bar** (optional basic actions: bold, italic, code, math).

## 6. User Interface (MVP)

```
+-------------------------------------------+
|  Writ — document.md            [▪︎][□][X]  |
+-------------------------------------------+
| [Editor]                  | [Preview]     |
|                          |               |
|  # Heading               |   Heading     |
|  $E = mc^2$              |   E = mc²     |
| ```mermaid               |   [diagram]   |
| graph TD; A-->B;         |               |
| ```                      |               |
|                          |               |
+-------------------------------------------+
|  (Status bar: lines, words, rendering ok) |
+-------------------------------------------+
```

- **No toolbar by default** – keeps screen real estate for text.
- **Minimal sidebar** – none in MVP; future for file browser.
- **Preferences window** – font, tab size, preview debounce time, light/dark.

## 7. Technical Architecture (High-Level)

### 7.1 Stack
- **Language:** Swift (AppKit + SwiftUI for some panels).
- **Editor:** NSTextView (customized) or SwiftUI TextEditor with NSAttributedString highlighting.
- **Preview:** WKWebView with a bundled `index.html` that loads:
  - KaTeX CSS/JS
  - Mermaid.js
  - Highlight.js (for code blocks)
  - Custom CSS (GitHub-like or minimal)
- **Markdown parser:** CommonMark (cmark-gfm) or SwiftyMarkdown + custom extensions for math/diagram detection.
- **Math & diagrams** – parsed as code blocks with special info strings; transformed to HTML elements before sending to WebView.
- **PlantUML** – optional local JAR execution (off by default, user must enable in prefs and provide path).

### 7.2 Rendering Pipeline (Editor → Preview)
1. User edits text.
2. On debounce/save, raw Markdown is passed to a **Markdown → HTML** converter (extended cmark or custom).
3. Math delimiters `$...$`, `$$...$$` are replaced with `<span class="math inline">` or `<div class="math block">`.
4. Code blocks with `mermaid` / `plantuml` are wrapped with `<div class="mermaid">` or processed via PlantUML (if enabled).
5. HTML is injected into WKWebView via `loadHTMLString()`.
6. WebView runs KaTeX/Mermaid for final rendering.

### 7.3 Performance Considerations
- **WebView reuse** – single instance, update only on content change.
- **PlantUML caching** – hash diagram source → cached SVG (avoid re-rendering).
- **Large documents** – virtualized editing? Not MVP, but ensure NSTextView can handle 10k+ lines.
- **Background rendering** – off main thread for markdown parsing.

## 8. Data Flow

```
[User types] -> Editor View (NSTextView)
                    |
                    v
           Debounce Timer (500ms)
                    |
                    v
         [Markdown Parser] -> HTML
                    |
                    v
         [Inject into WKWebView]
                    |
                    v
         KaTeX / Mermaid / PlantUML render
                    |
                    v
              (Preview updates)
```

## 9. MVP Success Criteria

- **Core use case:** Open a `.md` file with math, mermaid, and code blocks → see correct preview.
- **Performance:** Preview updates in <500ms for a 10KB document.
- **Native feel:** No web app lag; smooth scrolling, native file dialogs.
- **Export:** Generated HTML includes all rendered math/diagrams (no broken assets).
- **Stability:** No crashes during editing, splitting views, or closing documents.

## 10. Out of Scope for MVP (But Possible Later)

- WYSIWYG mode / rich-text toolbar.
- Collaborative editing (CRDTs).
- Cloud backup / iCloud Drive sync.
- Custom themes / CSS editor.
- Vim/Emacs keybindings.
- Image drag-and-drop from Finder.
- Notebook / project view (multiple files).
- Export to DOCX, LaTeX, or Reveal.js.

## 11. Risks & Mitigation

| Risk | Mitigation |
|------|-------------|
| WKWebView memory leak with large diagrams | Unload WebView when document closed; reload on reopen. |
| PlantUML local rendering slow / complex | Make it opt-in, require user to provide `.jar`, cache aggressively. |
| Math parsing conflicts with `$` in regular text | Follow GitHub strict rules: `$` with no space after, no backslash before. |
| Performance on very large files (>1MB) | Limit preview auto-render; offer manual refresh only. |
| Mermaid/KaTeX version updates breaking old docs | Bundle specific JS/CSS versions; allow override in advanced prefs. |
