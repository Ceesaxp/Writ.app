**Writ – MVP Product Requirements Document (PRD)**

### 1. Product Vision
**Writ** is a fast, native macOS Markdown editor that prioritizes **plain-text purity with rich, live meaning**. It follows the principle **WYWIWYM** (*What You Write Is What You Mean*): you stay in clean, portable Markdown while instantly seeing beautiful, semantic rendering of math, diagrams, code, and media.

Writ aims to become the most versatile yet distraction-free Markdown tool for developers, researchers, technical writers, and power users on macOS.

### 2. MVP Objectives
- Deliver a polished, native-feeling core editor that feels faster and more reliable than web-based alternatives (Typora, Obsidian, etc.).
- Establish the “plain text → rich output” magic as the core differentiator.
- Achieve high performance and reliability on Apple Silicon.
- Gather early user feedback on the rendering engine and extensibility.

### 3. Target Audience (MVP)
- Technical writers and documentation engineers
- Developers (especially those writing READMEs, API docs, blogs)
- Researchers / academics who need heavy math support
- Power users who love Markdown but want better visuals

### 4. Core MVP Features

#### Editor Experience
- Native macOS text editing (using TextKit or equivalent) with excellent performance on large files
- Full Markdown support (CommonMark + GitHub Flavored Markdown)
- Live preview pane (side-by-side or dual-pane mode)
- Seamless split view: Source | Preview | Source + Preview
- Distraction-free mode (full screen, minimal UI)
- macOS-native behaviors: tabs, versions, full-screen, dark/light mode auto, Touch Bar support (if applicable), Command Palette

#### Rich Rendering (The WYWIWYM Core)
- **Math**: Full support for GitHub-style math blocks (`$$ ... $$` and inline `$ ... $`) using KaTeX or MathJax
- **Code blocks**: Syntax highlighting for 50+ languages, with copy button
- **Diagrams**:
  - Mermaid.js (flowcharts, sequence, class, ER, gantt, etc.)
  - PlantUML support (via local rendering if possible)
- **Images & Embeds**: Standard Markdown images + basic SVG inline rendering
- Clean, modern default theme with excellent typography (Inter + system fonts + LaTeX-friendly math font)

#### File & Project Management
- Native `.md` file editing (no custom format)
- Folder-based project/workspace support (like working on a whole docs folder)
- Quick Open / fuzzy file search
- Recent files & projects

#### Polish & Quality
- Extremely fast rendering and live updates
- Robust undo/redo
- Find & Replace (with regex support)
- Basic table editing support
- Export to HTML + PDF (clean, styled output)
- macOS menu bar + dock icon integration

### 5. Non-Functional Requirements
- **Performance**: Open and edit 5MB+ Markdown files smoothly
- **Native feel**: Must feel like a first-party Apple app (Swift/SwiftUI + AppKit where needed)
- **Reliability**: Excellent crash resistance and autosave
- **Offline-first**: 100% local, no account required
- **Privacy**: Zero telemetry in MVP (optional anonymous usage stats toggle)
- **Accessibility**: Good VoiceOver and keyboard navigation support

### 6. Out of Scope for MVP (v1.0)
- Sync / collaboration features
- AI assistance (completion, generation)
- Custom themes / heavy theming engine
- Advanced publishing (e.g. direct GitHub, website export)
- Mobile / iPad version
- Plugin system
- Wiki-style backlinks / graph view
- Heavy customization of rendering (beyond basic settings)
- Windows/Linux versions

### 7. Technical Considerations (High-level)
- Language: Swift + SwiftUI (with AppKit for advanced text needs)
- Rendering: WebView (WKWebView) for rich preview or native Swift rendering where feasible
- Math: KaTeX
- Diagrams: Mermaid + possible local PlantUML/SVGs
- File watching for external changes

### 8. Success Metrics for MVP Launch
- Positive user feedback on rendering quality (math + Mermaid especially)
- Editor feels faster/more native than leading competitors
- < 5 critical bugs reported in first month
- Organic growth via Reddit, Hacker News, Mac forums

