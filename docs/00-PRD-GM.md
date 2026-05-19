# Product Design Document: Writ (MVP)

Building "yet another" Markdown editor is practically a rite of passage, but honestly, there is absolutely still room in the market for a truly native, performant macOS app. In a sea of memory-hungry Electron wrappers, a lightweight, native editor that elegantly handles advanced technical formatting is a highly compelling proposition. "Writ" is a great, punchy name with solid historical roots.

## 1. Executive Summary & Vision

**Writ** is a lightning-fast, macOS-native plain text editor designed for technical writers, developers, and academics. It bridges the gap between distraction-free writing and advanced document rendering. By maintaining a strict plain-text foundation while supporting advanced syntax (GitHub-Flavored Markdown, LaTeX math, Mermaid/PlantUML diagrams, and SVGs), Writ allows users to author complex technical documents without ever leaving the keyboard or wrestling with visual formatting.

## 2. Target Audience

* **Developers & Engineers:** Need to write READMEs, architecture decision records (ADRs), and technical documentation with embedded code and diagrams.
* **Academics & Researchers:** Require robust, standard-compliant math formatting (LaTeX) without the overhead of a full LaTeX editor.
* **Power Users:** Appreciate macOS native design guidelines, keyboard navigation, high performance, and low battery consumption.

## 3. Core Value Propositions

* **Uncompromisingly Native:** Built for macOS. Fast launch times, native window management, smooth scrolling, and minimal RAM usage.
* **Technical Versatility:** First-class support for advanced formatting (Math, Diagrams, SVGs) right out of the box.
* **Future-Proof:** Documents are strictly plain text (`.md`). No proprietary database, no vendor lock-in.

---

## 4. Feature Prioritization

To ensure the MVP actually ships, we must be ruthless about scope.

| Feature Category | MVP (Must-Have) | V2 (Nice-to-Have / Later) |
| --- | --- | --- |
| **Architecture** | Native macOS document-based app (files & folders) | iCloud Sync integration natively built-in |
| **UI Layout** | Dual-pane (Editor left, Preview right) or toggleable | Inline WYSIWYG rendering (like Typora) |
| **Core Markdown** | GitHub-Flavored Markdown (GFM) parsing | Custom CSS theming for exports |
| **Math Support** | GitHub-style inline `$` and block `$$` LaTeX | Custom macro definitions |
| **Diagrams** | Mermaid.js rendering in preview | PlantUML, local CLI diagram generation |
| **Media** | Drag-and-drop local images, SVG rendering | Image resizing via Markdown syntax |

---

## 5. MVP Feature Breakdown

### 5.1. The Editor (Input)

* **Syntax Highlighting:** Real-time highlighting for Markdown syntax, including distinct visual treatments for bold, italics, links, and code blocks.
* **Code Block Formatting:** Auto-indentation and basic syntax highlighting inside triple-backtick code blocks.
* **Native Typography:** Utilization of macOS Font styling (San Francisco, SF Mono) with customizable font sizes.
* **Editor UX:** Line numbers (toggleable), word count, and standard macOS text shortcuts.

### 5.2. The Renderer (Output/Preview)

* **Markdown Parsing:** Standard GFM compliance.
* **Math Rendering:** Integration with a library like MathJax or KaTeX to parse and elegantly render equations enclosed in `$` (inline) and `$$` (block) within the preview pane.
* **Diagrams:** Bundling Mermaid.js to automatically render code blocks marked as `mermaid ` into visual diagrams.
* **SVG Embedding:** Allow users to reference standard `.svg` files or write raw SVG code blocks that render visually in the preview.

### 5.3. File Management & macOS Integration

* **Standard File I/O:** Standard macOS open/save dialogs. Operates directly on the user's local file system.
* **Tabs:** Native macOS window tabbing.
* **Export:** Basic export to HTML and PDF.

---

## 6. Technical Stack Considerations (High-Level)

* **App Framework:** SwiftUI combined with AppKit (for more complex window and text management).
* **Text Engine:** TextKit 2 for highly performant, native text rendering and custom syntax highlighting in the editor pane.
* **Preview Engine:** `WKWebView`. For the MVP, parsing the Markdown to HTML and injecting it into a native WebKit view alongside KaTeX/Mermaid bundles is the most pragmatic way to achieve complex rendering quickly.
* **Markdown Parser:** `swift-markdown` (Apple's wrapper around `cmark-gfm`) ensures speed and strict GitHub-Flavored Markdown compliance.

## 7. Non-Goals for MVP

* **Cross-platform support:** iOS/iPadOS or Windows/Linux versions. Focus entirely on nailing the macOS experience first.
* **Proprietary Cloud Sync:** Rely on the user saving files in their own iCloud Drive/Dropbox folders.
* **Collaboration:** No real-time multiplayer editing.
