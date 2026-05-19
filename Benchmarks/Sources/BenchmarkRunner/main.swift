import Foundation
import WritCore
import WritParser
import WritRender

// Pure-Swift portion of the M0 spike.
//
// Measures:
//   - Markdown parse + HTML emission per fixture (cold and warm)
//   - PreviewBridgePayload encoding cost
//   - Technical block extraction counts
//
// MathJax vs KaTeX timing requires a `WKWebView` and is measured by the app's
// internal `--bench` mode (see App/Sources/App/BenchmarkMode.swift).

struct BenchResult: Codable {
    var fixture: String
    var byteCount: Int
    var lineCount: Int
    var coldParseMicros: Int
    var warmParseMicrosP50: Int
    var warmParseMicrosP90: Int
    var htmlBytes: Int
    var technicalBlocks: Int
    var payloadEncodeMicros: Int
}

func micros(_ d: Duration) -> Int {
    let attos = d.components.attoseconds
    let secs = d.components.seconds
    return Int(secs) * 1_000_000 + Int(attos / 1_000_000_000_000)
}

func percentile(_ values: [Int], _ p: Double) -> Int {
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: writ-bench <fixtures-dir> [results.json]\n".utf8))
    exit(2)
}

let fixturesDir = CommandLine.arguments[1]
let resultsPath = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : nil

let names = ["10kb.md", "1mb.md", "5mb.md", "code-heavy.md", "math-heavy.md", "mermaid-heavy.md"]
let parser = WritParserFactory.make()
var results: [BenchResult] = []
let clock = ContinuousClock()

func pad(_ s: String, _ w: Int, leftAlign: Bool = true) -> String {
    if s.count >= w { return s }
    let fill = String(repeating: " ", count: w - s.count)
    return leftAlign ? s + fill : fill + s
}
func row(_ cols: [(String, Int)]) -> String {
    cols.map { pad($0.0, $0.1, leftAlign: false) }.joined(separator: "  ")
}
let header = pad("fixture", 22) + "  " +
             pad("bytes", 10, leftAlign: false) + "  " +
             pad("parse_cold", 10, leftAlign: false) + "  " +
             pad("parse_p50", 10, leftAlign: false) + "  " +
             pad("parse_p90", 10, leftAlign: false) + "  " +
             pad("blocks", 8, leftAlign: false) + "  " +
             pad("html", 8, leftAlign: false)
print(header)
print(String(repeating: "-", count: header.count))

for name in names {
    let url = URL(fileURLWithPath: fixturesDir).appendingPathComponent(name)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        print("missing: \(name)")
        continue
    }
    let snapshot = DocumentSnapshot(revision: DocumentRevision(1), source: source)

    let coldStart = clock.now
    let cold = try parser.parse(snapshot)
    let coldDuration = clock.now - coldStart

    // Warm parse — repeat
    var warmTimes: [Int] = []
    for _ in 0..<5 {
        let s = clock.now
        _ = try parser.parse(snapshot)
        warmTimes.append(micros(clock.now - s))
    }

    let payload = PreviewBridgePayload(revision: snapshot.revision, html: cold.html, blocks: cold.blocks, theme: "light")
    let payloadStart = clock.now
    _ = try payload.encodedAsJSON()
    let payloadDuration = clock.now - payloadStart

    let r = BenchResult(
        fixture: name,
        byteCount: snapshot.byteCount,
        lineCount: snapshot.lineCount,
        coldParseMicros: micros(coldDuration),
        warmParseMicrosP50: percentile(warmTimes, 0.5),
        warmParseMicrosP90: percentile(warmTimes, 0.9),
        htmlBytes: cold.html.utf8.count,
        technicalBlocks: cold.blocks.count,
        payloadEncodeMicros: micros(payloadDuration)
    )
    results.append(r)

    let line = pad(name, 22) + "  " +
               pad("\(r.byteCount)", 10, leftAlign: false) + "  " +
               pad("\(r.coldParseMicros)", 10, leftAlign: false) + "  " +
               pad("\(r.warmParseMicrosP50)", 10, leftAlign: false) + "  " +
               pad("\(r.warmParseMicrosP90)", 10, leftAlign: false) + "  " +
               pad("\(r.technicalBlocks)", 8, leftAlign: false) + "  " +
               pad("\(r.htmlBytes)", 8, leftAlign: false)
    print(line)
}

if let resultsPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(results)
    try data.write(to: URL(fileURLWithPath: resultsPath))
    print("\nResults written to \(resultsPath)")
}
