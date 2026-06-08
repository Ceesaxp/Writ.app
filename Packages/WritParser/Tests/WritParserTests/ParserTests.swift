import Testing
import Foundation
import WritCore
@testable import WritParser

@Suite("MathPreprocessor")
struct MathPreprocessorTests {
    @Test("Inline math is replaced by span placeholder")
    func inlineMath() {
        let (out, blocks) = MathPreprocessor.extract("inline $a+b$ math")
        #expect(blocks.count == 1)
        #expect(!blocks[0].isBlock)
        #expect(blocks[0].block.source == "a+b")
        #expect(out.contains("class=\"writ-math-inline\""))
    }

    @Test("Block math: $$ must be alone on its line")
    func blockRequiresOwnLine() {
        // Mid-line $$ no longer opens a block (GitHub / Pandoc strict).
        let (_, mid) = MathPreprocessor.extract("before $$x^2$$ after")
        #expect(mid.isEmpty, "mid-line $$ should not extract block math")
        // Proper standalone $$ does.
        let (_, own) = MathPreprocessor.extract("$$\nx = y\n$$")
        #expect(own.count == 1)
        #expect(own[0].isBlock)
        #expect(own[0].block.source == "x = y\n")
    }

    @Test("Block math: leading whitespace before $$ is allowed")
    func blockToleratesIndent() {
        let (_, blocks) = MathPreprocessor.extract("  $$\nx\n  $$")
        #expect(blocks.count == 1)
        #expect(blocks[0].isBlock)
    }

    @Test("Whitespace-adjacent inline math is not extracted")
    func currencySafe() {
        let (_, blocks) = MathPreprocessor.extract("It costs $ 5 and $10.")
        #expect(blocks.isEmpty)
    }

    @Test("Currency: $5 and $10 should not become math")
    func currencyTwoAmounts() {
        let (_, blocks) = MathPreprocessor.extract("Profit was $5 and $10 last quarter.")
        #expect(blocks.isEmpty)
    }

    @Test("Currency: $5m and $10m should not become math (digit after close)")
    func currencyMillions() {
        let (_, blocks) = MathPreprocessor.extract("They raised $5m at a $10m valuation.")
        #expect(blocks.isEmpty)
    }

    @Test("Currency: $50 → $75 (arrow between amounts)")
    func currencyArrow() {
        let (_, blocks) = MathPreprocessor.extract("Pricing went $50 → $75 last week.")
        #expect(blocks.isEmpty)
    }

    @Test("Inline math: opener must follow non-alphanumeric")
    func openerAfterLetter() {
        // `foo$bar$` — the `$` is preceded by a letter; should not open math.
        let (_, blocks) = MathPreprocessor.extract("see foo$bar$ here")
        #expect(blocks.isEmpty)
    }

    @Test("Inline math: real math survives strict rules")
    func mathSurvivesStrict() {
        let (_, blocks) = MathPreprocessor.extract("Solve $x + y = z$ for x.")
        #expect(blocks.count == 1)
        #expect(blocks[0].block.source == "x + y = z")
    }

    @Test("Escaped dollar is not math")
    func escapedDollar() {
        let (_, blocks) = MathPreprocessor.extract("a \\$5 bill")
        #expect(blocks.isEmpty)
    }

    @Test("Inline math does not span newlines")
    func inlineSingleLine() {
        let (_, blocks) = MathPreprocessor.extract("open $a+b\nc+d$ close")
        #expect(blocks.isEmpty)
    }
}

@Suite("Math front-matter opt-out")
struct MathOptOutTests {
    @Test("math: false in front matter disables math extraction")
    func mathFalseDisables() throws {
        let src = """
        ---
        math: false
        ---
        Cost is $50 each. Inline $x + y$ here.
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        #expect(!parsed.html.contains("writ-math-inline"))
        #expect(!parsed.html.contains("writ-math-block"))
        // Source dollars survive in the rendered HTML.
        #expect(parsed.html.contains("$50"))
    }

    @Test("Default (no flag) keeps math enabled")
    func mathDefaultEnabled() throws {
        let src = """
        ---
        title: Math doc
        ---
        Inline $x + y$ here.
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        #expect(parsed.html.contains("writ-math-inline"))
    }
}

@Suite("SwiftMarkdownParser")
struct ParserTests {
    let parser = SwiftMarkdownParser()

    @Test("Headings emit data-writ-id")
    func heading() throws {
        let s = DocumentSnapshot(revision: .zero, source: "# Hello")
        let p = try parser.parse(s)
        #expect(p.html.contains("<h1"))
        #expect(p.html.contains("data-writ-id="))
        #expect(p.html.contains("Hello"))
    }

    @Test("Heading anchor id matches unprefixed slug for [text](#slug) cross-refs")
    func headingAnchorUnprefixed() throws {
        let s = DocumentSnapshot(revision: .zero, source: "## Section Two\n\n[jump](#section-two)")
        let p = try parser.parse(s)
        #expect(p.html.contains("id=\"section-two\""))
        #expect(!p.html.contains("id=\"h-section-two\""))
    }

    @Test("Code fence with language becomes preview-highlightable")
    func codeFence() throws {
        let s = DocumentSnapshot(revision: .zero, source: "```swift\nlet x = 1\n```")
        let p = try parser.parse(s)
        #expect(p.html.contains("language-swift"))
        #expect(p.html.contains("let x = 1"))
    }

    @Test("Mermaid fence is collected as technical block")
    func mermaidFence() throws {
        let s = DocumentSnapshot(revision: .zero, source: "```mermaid\ngraph TD\nA-->B\n```")
        let p = try parser.parse(s)
        #expect(p.blocks.contains { $0.kind == .mermaid })
        #expect(p.html.contains("writ-mermaid"))
    }

    @Test("PlantUML fence shows non-configured notice")
    func plantumlFence() throws {
        let s = DocumentSnapshot(revision: .zero, source: "```plantuml\n@startuml\nA->B\n@enduml\n```")
        let p = try parser.parse(s)
        #expect(p.blocks.contains { $0.kind == .plantuml })
        #expect(p.html.contains("not configured"))
    }

    @Test("Math fence is collected")
    func mathFence() throws {
        let s = DocumentSnapshot(revision: .zero, source: "```math\n\\frac{1}{2}\n```")
        let p = try parser.parse(s)
        #expect(p.blocks.contains { $0.kind == .math })
    }

    @Test("Block math is recognized through preprocessor")
    func dollarBlock() throws {
        // Block math now requires `$$` to be alone on its line.
        let s = DocumentSnapshot(revision: .zero, source: "$$\nx^2\n$$")
        let p = try parser.parse(s)
        #expect(p.blocks.contains { $0.kind == .math })
    }

    @Test("Task list emits checkbox markup")
    func taskList() throws {
        let s = DocumentSnapshot(revision: .zero, source: "- [x] done\n- [ ] todo")
        let p = try parser.parse(s)
        #expect(p.html.contains("task-list-item"))
        #expect(p.html.contains("checked"))
    }

    @Test("Strikethrough emits del")
    func strikethrough() throws {
        let s = DocumentSnapshot(revision: .zero, source: "~~gone~~")
        let p = try parser.parse(s)
        #expect(p.html.contains("<del>"))
    }

    @Test("Tables emit thead/tbody")
    func tables() throws {
        let src = """
        | a | b |
        | - | - |
        | 1 | 2 |
        """
        let s = DocumentSnapshot(revision: .zero, source: src)
        let p = try parser.parse(s)
        #expect(p.html.contains("<thead>"))
        #expect(p.html.contains("<tbody>"))
    }

    @Test("Span extractor finds heading, code block, emphasis, strong")
    func spans() {
        let src = """
        # Heading 1

        Some **strong** and *emphasis* and `code`.

        ```swift
        let x = 1
        ```

        $$x^2 + y^2$$
        """
        let extractor = SyntaxSpanExtractor()
        let spans = extractor.extract(from: src)
        let kinds = Set(spans.map(\.kind))
        #expect(kinds.contains(.heading))
        #expect(kinds.contains(.strong))
        #expect(kinds.contains(.emphasis))
        #expect(kinds.contains(.inlineCode))
        #expect(kinds.contains(.codeBlock))
        #expect(kinds.contains(.mathBlock))
    }

    @Test("Span ranges align with UTF-16 when source has multibyte characters")
    func spansMultibyteAlignment() {
        // cmark reports columns in UTF-8 bytes; NSTextStorage uses UTF-16.
        // Cyrillic letters are 2 UTF-8 bytes but 1 UTF-16 unit, so a naive
        // column→UTF-16 mapping shifts later spans to the right by exactly
        // the count of multibyte characters preceding them.
        let src = "**XXX (пре-АБВ)**: [Watchers](https://watchers.io) tail"
        let ns = src as NSString
        let extractor = SyntaxSpanExtractor()
        let spans = extractor.extract(from: src)

        let strong = spans.first { $0.kind == .strong }
        #expect(strong != nil)
        if let r = strong?.range {
            #expect(ns.substring(with: r) == "**XXX (пре-АБВ)**")
        }

        let link = spans.first { $0.kind == .link }
        #expect(link != nil)
        if let r = link?.range {
            #expect(ns.substring(with: r) == "[Watchers](https://watchers.io)")
        }
    }

    @Test("Span ranges align with UTF-16 across emoji (4-byte UTF-8)")
    func spansEmojiAlignment() {
        // A non-BMP emoji is 4 UTF-8 bytes and 2 UTF-16 units, so the
        // bytes-vs-units skew differs from Cyrillic but must still resolve.
        let src = "Hello 🚀 **bold** [link](https://e.x)"
        let ns = src as NSString
        let spans = SyntaxSpanExtractor().extract(from: src)

        if let r = spans.first(where: { $0.kind == .strong })?.range {
            #expect(ns.substring(with: r) == "**bold**")
        } else {
            Issue.record("expected a strong span")
        }
        if let r = spans.first(where: { $0.kind == .link })?.range {
            #expect(ns.substring(with: r) == "[link](https://e.x)")
        } else {
            Issue.record("expected a link span")
        }
    }

    @Test("HTMLSanitizer strips script tags and event handlers")
    func sanitizer() {
        let input = """
        <p>safe</p><script>alert(1)</script>
        <a href="javascript:bad()" onclick="bad()">link</a>
        <img src=\"x\" onerror=\"bad()\">
        """
        let cleaned = HTMLSanitizer.sanitize(input)
        #expect(!cleaned.contains("<script"))
        #expect(!cleaned.contains("onclick"))
        #expect(!cleaned.contains("onerror"))
        #expect(!cleaned.contains("javascript:"))
        #expect(cleaned.contains("safe"))
    }

    @Test("HTMLSanitizer leaves safe HTML alone")
    func sanitizerSafe() {
        let input = "<div class=\"x\"><strong>bold</strong> <em>italic</em></div>"
        let cleaned = HTMLSanitizer.sanitize(input)
        #expect(cleaned == input)
    }

    @Test("GFM alert: NOTE blockquote becomes a typed callout")
    func gfmAlertNote() throws {
        let src = """
        > [!NOTE]
        > Useful information.
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        #expect(parsed.html.contains("writ-alert"))
        #expect(parsed.html.contains("writ-alert-note"))
        #expect(parsed.html.contains(">Note<"))
        #expect(parsed.html.contains("Useful information"))
        // Plain <blockquote> wrapper should NOT also be there.
        #expect(!parsed.html.contains("<blockquote"))
    }

    @Test("GFM alert: all five types parse with their tints")
    func gfmAlertAllTypes() throws {
        let cases: [(String, String)] = [
            ("NOTE", "writ-alert-note"),
            ("TIP", "writ-alert-tip"),
            ("IMPORTANT", "writ-alert-important"),
            ("WARNING", "writ-alert-warning"),
            ("CAUTION", "writ-alert-caution")
        ]
        let parser = SwiftMarkdownParser()
        for (kind, cls) in cases {
            let src = "> [!\(kind)]\n> body"
            let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
            #expect(parsed.html.contains(cls), "alert kind \(kind) should produce \(cls)")
        }
    }

    @Test("GFM alert: unknown type stays a plain blockquote")
    func gfmAlertUnknownTypeFallsBack() throws {
        let src = "> [!FOO]\n> body"
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        #expect(parsed.html.contains("<blockquote"))
        #expect(!parsed.html.contains("writ-alert"))
    }

    // MARK: - Front matter

    @Test("YAML front matter is extracted, stripped from body, and emitted as a card")
    func frontMatterYAML() throws {
        let src = """
        ---
        title: Hello
        date: 2026-05-21
        tags: foo, bar
        ---

        # Body heading

        Paragraph.
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        let fm = try #require(parsed.frontMatter)
        #expect(fm.format == .yaml)
        #expect(fm["title"] == "Hello")
        #expect(fm["date"] == "2026-05-21")
        #expect(fm["tags"] == "foo, bar")
        #expect(parsed.html.contains("writ-front-matter"))
        // Body heading still renders.
        #expect(parsed.html.contains("Body heading"))
        // The `---` delimiters must NOT have been parsed as thematic
        // breaks in the body.
        #expect(!parsed.html.contains("<hr"))
    }

    @Test("TOML front matter is recognised by +++ delimiters")
    func frontMatterTOML() throws {
        let src = """
        +++
        title = "Hello"
        author = "Andrei"
        +++

        Body.
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        let fm = try #require(parsed.frontMatter)
        #expect(fm.format == .toml)
        #expect(fm["title"] == "Hello")
        #expect(fm["author"] == "Andrei")
    }

    @Test("Front-matter tags: YAML inline array")
    func frontMatterTagsYAMLInline() throws {
        let src = """
        ---
        title: Hello
        tags: [alpha, beta, gamma]
        ---

        body
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        let fm = try #require(parsed.frontMatter)
        #expect(fm.tags == ["alpha", "beta", "gamma"])
    }

    @Test("Front-matter tags: YAML block sequence")
    func frontMatterTagsYAMLBlock() throws {
        let src = """
        ---
        title: Hello
        tags:
          - alpha
          - "beta gamma"
          - delta
        author: A
        ---

        body
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        let fm = try #require(parsed.frontMatter)
        #expect(fm.tags == ["alpha", "beta gamma", "delta"])
        // The next non-list line terminates the block — `author` still parses.
        #expect(fm["author"] == "A")
    }

    @Test("Front-matter tags: TOML quoted array")
    func frontMatterTagsTOML() throws {
        let src = """
        +++
        title = "Hello"
        tags = ["alpha", "beta", "gamma"]
        +++

        body
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        let fm = try #require(parsed.frontMatter)
        #expect(fm.tags == ["alpha", "beta", "gamma"])
    }

    @Test("Front-matter tags: malformed input does not abort the parse")
    func frontMatterTagsMalformed() throws {
        let src = """
        ---
        title: Hello
        tags: [unclosed, list
        author: A
        ---

        body
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        let fm = try #require(parsed.frontMatter)
        // The `[unclosed, list` value isn't a recognisable array — kept
        // as the raw value of `tags`; the parser does NOT fall over.
        #expect(fm["title"] == "Hello")
        #expect(fm["author"] == "A")
    }

    @Test("Quoted YAML values lose their surrounding quotes")
    func frontMatterQuoteStripping() throws {
        let src = """
        ---
        title: "Hello, World"
        slug: 'hello-world'
        ---

        body
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        #expect(parsed.frontMatter?["title"] == "Hello, World")
        #expect(parsed.frontMatter?["slug"] == "hello-world")
    }

    @Test("Document without front matter parses normally")
    func frontMatterAbsent() throws {
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: "# Just a heading\n"))
        #expect(parsed.frontMatter == nil)
        #expect(!parsed.html.contains("writ-front-matter"))
    }

    @Test("Front matter range emerges as a SyntaxSpan for the editor")
    func frontMatterSyntaxSpan() throws {
        let src = """
        ---
        title: Hello
        ---

        # Body
        """
        let extractor = SyntaxSpanExtractor()
        let spans = extractor.extract(from: src)
        let fmSpans = spans.filter { $0.kind == .frontMatter }
        #expect(fmSpans.count == 1, "exactly one frontMatter span per document")

        let fm = fmSpans[0]
        // The span should cover the opener, body, and closer — i.e.
        // up through the closing `---\n`. The first heading after is
        // outside the span.
        let ns = src as NSString
        let covered = ns.substring(with: fm.range)
        #expect(covered.contains("title: Hello"))
        #expect(covered.contains("---"))
        #expect(!covered.contains("# Body"), "body markdown stays outside the FM range")
    }

    @Test("Malformed front matter (no closer) is left as body text")
    func frontMatterUnclosed() throws {
        let src = """
        ---
        title: never closed
        body line that's not a closer
        # heading
        """
        let parser = SwiftMarkdownParser()
        let parsed = try parser.parse(DocumentSnapshot(revision: .zero, source: src))
        #expect(parsed.frontMatter == nil)
        // The leading --- gets treated as a thematic break here, which
        // is the right CommonMark fallback when there's no closer.
        #expect(parsed.html.contains("<hr"))
    }

    @Test("HTMLSanitizer strips dangerous SVG nesting")
    func sanitizerSVGNesting() {
        let svg = """
        <svg width="100" height="100">
          <rect x="0" y="0" width="100" height="100" fill="blue"/>
          <foreignObject width="100" height="100">
            <body><script>alert('xss')</script></body>
          </foreignObject>
          <animate attributeName="onload" to="alert('xss')"/>
          <use xlink:href="javascript:bad()"/>
        </svg>
        """
        let cleaned = HTMLSanitizer.sanitize(svg)
        #expect(!cleaned.lowercased().contains("foreignobject"))
        #expect(!cleaned.lowercased().contains("<animate"))
        #expect(!cleaned.lowercased().contains("<use"))
        #expect(!cleaned.lowercased().contains("javascript:"))
        // The benign rect inside the SVG survives.
        #expect(cleaned.contains("<rect"))
    }

    @Test("HTMLSanitizer keeps safe SVG primitives")
    func sanitizerSafeSVG() {
        let svg = """
        <svg viewBox="0 0 100 100">
          <rect x="0" y="0" width="50" height="50" fill="red"/>
          <circle cx="50" cy="50" r="20"/>
          <path d="M0 0 L100 100"/>
          <text x="10" y="20">Label</text>
        </svg>
        """
        let cleaned = HTMLSanitizer.sanitize(svg)
        #expect(cleaned.contains("<rect"))
        #expect(cleaned.contains("<circle"))
        #expect(cleaned.contains("<path"))
        #expect(cleaned.contains("<text"))
    }

    @Test("HTMLSanitizer rewrites javascript: in xlink:href")
    func sanitizerXlinkHref() {
        let input = "<svg><a xlink:href=\"javascript:bad()\">x</a></svg>"
        let cleaned = HTMLSanitizer.sanitize(input)
        #expect(!cleaned.contains("javascript:"))
    }

    @Test("HTMLSanitizer rewrites data:text/html in href, keeps data: in img src")
    func sanitizerDataURLs() {
        let bad = "<a href=\"data:text/html,<script>x</script>\">click</a>"
        let cleaned = HTMLSanitizer.sanitize(bad)
        #expect(!cleaned.contains("data:text/html"))

        let goodImg = "<img src=\"data:image/png;base64,iVBORw0KGgo=\" alt=\"x\">"
        let cleanedImg = HTMLSanitizer.sanitize(goodImg)
        #expect(cleanedImg.contains("data:image/png"), "data: image URLs must still pass through")
    }

    @Test("Span extractor recognises list/task markers and tables")
    func spansLineLevel() {
        let src = """
        - item
        - [x] done
        - [ ] todo

        | a | b |
        | - | - |
        | 1 | 2 |
        """
        let spans = SyntaxSpanExtractor().extract(from: src)
        #expect(spans.contains { $0.kind == .listMarker })
        #expect(spans.contains { $0.kind == .taskMarker })
        #expect(spans.contains { $0.kind == .tableSeparator })
    }

    @Test("Table column alignment markers reach HTML")
    func tableAlignment() throws {
        let src = """
        | l | c | r |
        | :--- | :---: | ---: |
        | 1 | 2 | 3 |
        """
        let s = DocumentSnapshot(revision: .zero, source: src)
        let p = try parser.parse(s)
        #expect(p.html.contains("text-align:left"))
        #expect(p.html.contains("text-align:center"))
        #expect(p.html.contains("text-align:right"))
    }

    // MARK: - Emoji shortcodes (#16)

    @Test("Emoji shortcode: known tokens substitute to glyphs")
    func emojiSubstitutesKnown() throws {
        let s = DocumentSnapshot(revision: .zero, source: "Ship it :rocket: with :sparkles:!")
        let p = try parser.parse(s)
        #expect(p.html.contains("🚀"))
        #expect(p.html.contains("✨"))
        #expect(!p.html.contains(":rocket:"))
        #expect(!p.html.contains(":sparkles:"))
    }

    @Test("Emoji shortcode: unknown tokens stay literal")
    func emojiUnknownTokensLiteral() throws {
        let s = DocumentSnapshot(revision: .zero, source: "Edge case :not_a_real_emoji: stays.")
        let p = try parser.parse(s)
        #expect(p.html.contains(":not_a_real_emoji:"))
    }

    @Test("Emoji shortcode: inside inline code, stays literal")
    func emojiInsideInlineCode() throws {
        let s = DocumentSnapshot(revision: .zero, source: "use the `:rocket:` shortcode")
        let p = try parser.parse(s)
        // The `<code>:rocket:</code>` literal must survive.
        #expect(p.html.contains("<code>:rocket:</code>"))
        // Body text outside the code span did not have a shortcode to
        // substitute, so no rocket glyph should appear anywhere.
        #expect(!p.html.contains("🚀"))
    }

    @Test("Emoji shortcode: inside a fenced code block, stays literal")
    func emojiInsideCodeBlock() throws {
        let src = """
        ```
        :rocket: do not transform
        ```
        """
        let s = DocumentSnapshot(revision: .zero, source: src)
        let p = try parser.parse(s)
        #expect(p.html.contains(":rocket: do not transform"))
        #expect(!p.html.contains("🚀"))
    }

    @Test("Emoji shortcode: +1 / -1 aliases work")
    func emojiPlusMinusAliases() throws {
        let s = DocumentSnapshot(revision: .zero, source: "Feedback: :+1: or :-1:")
        let p = try parser.parse(s)
        #expect(p.html.contains("👍"))
        #expect(p.html.contains("👎"))
    }

    // MARK: - Autolink bare URLs (#21)

    @Test("Autolink: https URL becomes a link")
    func autolinkHTTPS() throws {
        let s = DocumentSnapshot(revision: .zero, source: "Visit https://example.com today.")
        let p = try parser.parse(s)
        #expect(p.html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }

    @Test("Autolink: trailing punctuation is not part of the link")
    func autolinkTrailingPunctuation() throws {
        let s = DocumentSnapshot(revision: .zero, source: "See https://foo.com. Done.")
        let p = try parser.parse(s)
        // The trailing period stays outside the anchor.
        #expect(p.html.contains("<a href=\"https://foo.com\">https://foo.com</a>"))
        #expect(!p.html.contains("https://foo.com.\""))
    }

    @Test("Autolink: www. host prepends http:// scheme")
    func autolinkWWWPrefix() throws {
        let s = DocumentSnapshot(revision: .zero, source: "Try www.example.com next.")
        let p = try parser.parse(s)
        #expect(p.html.contains("<a href=\"http://www.example.com\">www.example.com</a>"))
    }

    @Test("Autolink: URL inside backticks stays literal")
    func autolinkInsideInlineCode() throws {
        let s = DocumentSnapshot(revision: .zero, source: "Use `https://example.com` literally.")
        let p = try parser.parse(s)
        // Inside <code>, the URL is escaped text, not an anchor.
        #expect(p.html.contains("<code>https://example.com</code>"))
        // Make sure we didn't accidentally also emit an anchor.
        #expect(!p.html.contains("<a href=\"https://example.com\""))
    }

    @Test("Autolink: URL inside an existing link does not double-link")
    func autolinkInsideExistingLink() throws {
        let s = DocumentSnapshot(revision: .zero, source: "[click https://example.com here](https://elsewhere.com)")
        let p = try parser.parse(s)
        // Outer <a> points at /elsewhere.com.
        #expect(p.html.contains("href=\"https://elsewhere.com\""))
        // The bare URL inside the link's display text should NOT be
        // wrapped in another <a> — searching for the nested anchor
        // signature would catch a regression.
        #expect(!p.html.contains("<a href=\"https://example.com\""))
    }

    @Test("Autolink: balances trailing close-paren")
    func autolinkBalancedParen() throws {
        let s = DocumentSnapshot(revision: .zero, source: "Reference (see https://foo.com).")
        let p = try parser.parse(s)
        // The trailing `)` belongs to the wrapping parens, not the URL.
        #expect(p.html.contains("<a href=\"https://foo.com\">https://foo.com</a>"))
        #expect(!p.html.contains("foo.com)"))
    }
}
