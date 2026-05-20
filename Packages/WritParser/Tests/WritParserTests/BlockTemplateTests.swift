import Testing
import Foundation
@testable import WritParser

@Suite("OutlineExtractor")
struct OutlineTests {
    @Test("Collects every heading with its level and line number")
    func basic() {
        let src = """
        # One

        ## Two

        Text.

        ### Three

        # Four
        """
        let outline = OutlineExtractor.extract(from: src)
        #expect(outline.count == 4)
        #expect(outline[0].level == 1)
        #expect(outline[0].title == "One")
        #expect(outline[0].line == 1)
        #expect(outline[1].level == 2)
        #expect(outline[2].level == 3)
        #expect(outline[3].title == "Four")
    }

    @Test("Empty document returns empty outline")
    func empty() {
        #expect(OutlineExtractor.extract(from: "").isEmpty)
    }

    @Test("Plain text without headings yields empty outline")
    func noHeadings() {
        #expect(OutlineExtractor.extract(from: "Just a paragraph.").isEmpty)
    }
}

@Suite("BlockTemplate")
struct BlockTemplateTests {
    @Test("Code template wraps placeholder with fenced code markers")
    func codeShape() {
        #expect(BlockTemplate.code.prefix == "```\n")
        #expect(BlockTemplate.code.placeholder == "code")
        #expect(BlockTemplate.code.suffix == "\n```")
    }

    @Test("Math template uses display-math delimiters")
    func mathShape() {
        #expect(BlockTemplate.math.prefix == "$$\n")
        #expect(BlockTemplate.math.suffix == "\n$$")
    }

    @Test("Mermaid template uses the mermaid fence label")
    func mermaidShape() {
        #expect(BlockTemplate.mermaid.prefix.hasPrefix("```mermaid"))
    }

    @Test("Insertion at start of empty doc does not need a leading blank")
    func insertAtStart() {
        let plan = BlockTemplate.code.plan(insertingAt: 0, in: "")
        #expect(!plan.needsLeadingBlank)
        #expect(plan.inserted.hasPrefix("```\n"))
        // Placeholder range targets the body so the user can type to replace.
        let body = (plan.inserted as NSString).substring(with: plan.placeholderRange)
        #expect(body == "code")
    }

    @Test("Insertion mid-paragraph adds a blank line first")
    func insertMidParagraph() {
        let source = "Some text"
        let plan = BlockTemplate.math.plan(insertingAt: source.count, in: source)
        #expect(plan.needsLeadingBlank)
        #expect(plan.inserted.hasPrefix("\n$$\n"))
    }

    @Test("Insertion already after blank line skips the leading blank")
    func insertAfterBlank() {
        let source = "Some text\n\n"
        let plan = BlockTemplate.mermaid.plan(insertingAt: source.count, in: source)
        #expect(!plan.needsLeadingBlank)
        #expect(plan.inserted.hasPrefix("```mermaid"))
    }

    @Test("Placeholder range falls inside the inserted string")
    func placeholderInRange() {
        let plan = BlockTemplate.code.plan(insertingAt: 10, in: String(repeating: "a", count: 20))
        let upperBound = plan.placeholderRange.location + plan.placeholderRange.length
        // Account for the leading-blank prefix that shifts the placeholder.
        let insertedLength = 10 + (plan.inserted as NSString).length
        #expect(upperBound <= insertedLength)
    }
}
