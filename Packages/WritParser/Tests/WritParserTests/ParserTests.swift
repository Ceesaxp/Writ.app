import Testing
import WritCore
@testable import WritParser

@Suite("MathPreprocessor")
struct MathPreprocessorTests {
    @Test("Block math is replaced by div placeholder")
    func blockMath() {
        let (out, blocks) = MathPreprocessor.extract("before $$x^2$$ after")
        #expect(blocks.count == 1)
        #expect(blocks[0].isBlock)
        #expect(blocks[0].block.source == "x^2")
        #expect(out.contains("data-writ-block=\"MATH_0\""))
        #expect(!out.contains("$$"))
    }

    @Test("Inline math is replaced by span placeholder")
    func inlineMath() {
        let (out, blocks) = MathPreprocessor.extract("inline $a+b$ math")
        #expect(blocks.count == 1)
        #expect(!blocks[0].isBlock)
        #expect(blocks[0].block.source == "a+b")
        #expect(out.contains("class=\"writ-math-inline\""))
    }

    @Test("Whitespace-adjacent inline math is not extracted")
    func currencySafe() {
        let (_, blocks) = MathPreprocessor.extract("It costs $ 5 and $10.")
        #expect(blocks.isEmpty)
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

    @Test("Block math may span newlines")
    func blockSpansLines() {
        let (_, blocks) = MathPreprocessor.extract("$$\nx = y\n$$")
        #expect(blocks.count == 1)
        #expect(blocks[0].isBlock)
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
        let s = DocumentSnapshot(revision: .zero, source: "$$x^2$$")
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
}
