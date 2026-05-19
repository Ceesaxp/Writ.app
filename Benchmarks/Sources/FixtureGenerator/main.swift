import Foundation

// Deterministic Markdown fixture generator for M0 perf spikes.
// Usage:
//   writ-fixtures <output-dir>
//
// Produces: 10kb.md, 1mb.md, 5mb.md, code-heavy.md, math-heavy.md, mermaid-heavy.md

struct Lcg {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func choice<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
    mutating func int(_ range: Range<Int>) -> Int {
        Int(next() % UInt64(range.count)) + range.lowerBound
    }
}

let prose = [
    "Writ aims to be a fast, native macOS Markdown editor for technical writing.",
    "The core promise is plain text in, publication-quality preview out.",
    "Performance is treated as a product feature, not an implementation detail.",
    "The source remains portable Markdown, making it future-proof and tool-friendly.",
    "Live preview updates are debounced to avoid blocking the editor during typing.",
    "Large documents are detected automatically and switch to a degraded preview mode.",
    "The preview uses a persistent WKWebView and is updated through a structured bridge.",
    "Technical blocks like math and Mermaid diagrams are rendered locally and cached.",
    "Cache keys are derived from a content hash so deterministic renders are reused.",
    "Stale render results are discarded when a newer document revision is already applied."
]

let codeSnippets = [
    "let total = items.reduce(0, +)\nprint(total)",
    "func fibonacci(_ n: Int) -> Int {\n    n < 2 ? n : fibonacci(n - 1) + fibonacci(n - 2)\n}",
    "fn main() {\n    let v = vec![1, 2, 3];\n    println!(\"{:?}\", v);\n}",
    "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"hi\") }",
    "SELECT id, name FROM users WHERE created_at > now() - interval '7 days';",
    "const sum = (a, b) => a + b;\nconsole.log(sum(2, 3));"
]

let codeLanguages = ["swift", "rust", "go", "javascript", "python", "sql", "shell", "ruby"]

let mathSnippets = [
    "e^{i\\pi} + 1 = 0",
    "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}",
    "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}",
    "f(x) = \\frac{1}{\\sigma\\sqrt{2\\pi}} e^{-\\frac{1}{2}\\left(\\frac{x-\\mu}{\\sigma}\\right)^2}",
    "\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}",
    "A = \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"
]

let mermaidSnippets = [
    "graph TD\n  A[Start] --> B{Decision}\n  B -->|Yes| C[Continue]\n  B -->|No| D[Stop]",
    "sequenceDiagram\n  Editor->>Scheduler: edit\n  Scheduler->>Parser: snapshot\n  Parser-->>Scheduler: html\n  Scheduler->>WebView: update",
    "flowchart LR\n  A --> B --> C\n  A --> D\n  D --> C",
    "classDiagram\n  Document <|-- Editor\n  Editor *-- Preview"
]

func makeMixed(targetBytes: Int, seed: UInt64) -> String {
    var rng = Lcg(state: seed)
    var out = "# Writ Mixed Fixture\n\n"
    var section = 1
    while out.utf8.count < targetBytes {
        out += "## Section \(section)\n\n"
        section += 1
        let paragraphs = rng.int(2..<6)
        for _ in 0..<paragraphs {
            let sentences = rng.int(3..<7)
            for _ in 0..<sentences { out += rng.choice(prose) + " " }
            out += "\n\n"
        }
        switch rng.int(0..<4) {
        case 0:
            let lang = rng.choice(codeLanguages)
            out += "```\(lang)\n" + rng.choice(codeSnippets) + "\n```\n\n"
        case 1:
            out += "- item one\n- item two\n- [ ] task\n- [x] done\n\n"
        case 2:
            out += "> " + rng.choice(prose) + "\n\n"
        default:
            out += "| col | val |\n| --- | --- |\n| a | 1 |\n| b | 2 |\n\n"
        }
    }
    return out
}

func makeCodeHeavy(blocks: Int, seed: UInt64) -> String {
    var rng = Lcg(state: seed)
    var out = "# Code-heavy fixture\n\n"
    for i in 0..<blocks {
        out += "## Snippet \(i)\n\n"
        out += "```\(rng.choice(codeLanguages))\n" + rng.choice(codeSnippets) + "\n```\n\n"
    }
    return out
}

func makeMathHeavy(blocks: Int, seed: UInt64) -> String {
    var rng = Lcg(state: seed)
    var out = "# Math-heavy fixture\n\n"
    for i in 0..<blocks {
        out += "## Equation \(i)\n\n"
        out += "Inline: $\(rng.choice(mathSnippets))$ ends here.\n\n"
        out += "$$\n\(rng.choice(mathSnippets))\n$$\n\n"
        out += "```math\n\(rng.choice(mathSnippets))\n```\n\n"
    }
    return out
}

func makeMermaidHeavy(blocks: Int, seed: UInt64) -> String {
    var rng = Lcg(state: seed)
    var out = "# Mermaid-heavy fixture\n\n"
    for i in 0..<blocks {
        out += "## Diagram \(i)\n\n"
        out += "```mermaid\n\(rng.choice(mermaidSnippets))\n```\n\n"
    }
    return out
}

guard let outDir = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write(Data("usage: writ-fixtures <output-dir>\n".utf8))
    exit(2)
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func write(_ name: String, _ contents: String) throws {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    print("\(name): \(contents.utf8.count) bytes")
}

try write("10kb.md", makeMixed(targetBytes: 10_000, seed: 1))
try write("1mb.md", makeMixed(targetBytes: 1_000_000, seed: 2))
try write("5mb.md", makeMixed(targetBytes: 5_000_000, seed: 3))
try write("code-heavy.md", makeCodeHeavy(blocks: 200, seed: 4))
try write("math-heavy.md", makeMathHeavy(blocks: 100, seed: 5))
try write("mermaid-heavy.md", makeMermaidHeavy(blocks: 60, seed: 6))
