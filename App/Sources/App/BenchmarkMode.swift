import Cocoa
import WebKit
import WritCore
import WritParser
import WritRender

/// `Writ --bench <fixtures-dir> [results.json]` — runs the M0 preview spike
/// inside the real app process so WKWebView startup, JS bridge round-trips,
/// and math/Mermaid render costs are measured against the real shell.
///
/// Measures three update strategies per fixture: full `loadHTMLString` vs.
/// `Writ.update(...)` body replacement vs. reused `WKWebView` with no shell
/// reload. Also benchmarks KaTeX vs MathJax against the math-heavy fixture.
@MainActor
enum BenchmarkMode {
    struct Result: Codable {
        var fixture: String
        var byteCount: Int
        var blocks: Int
        var parseAndEncodeMicros: Int
        var firstPaintMicros: Int
        var warmUpdateMicrosP50: Int
        var warmUpdateMicrosP90: Int
        var mathRenderer: String
    }

    static func run() {
        let args = CommandLine.arguments
        guard let fixturesIdx = args.firstIndex(of: "--bench"),
              fixturesIdx + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: Writ --bench <fixtures-dir> [results.json]\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let fixturesDir = args[fixturesIdx + 1]
        let resultsPath = args.indices.contains(fixturesIdx + 2) ? args[fixturesIdx + 2] : nil

        let runner = BenchmarkRunner(fixturesDir: fixturesDir, resultsPath: resultsPath)
        runner.start()
    }
}

@MainActor
final class BenchmarkRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let fixturesDir: String
    private let resultsPath: String?
    private var webView: WKWebView!
    private var window: NSWindow!
    private var continuation: CheckedContinuation<Void, Never>?
    private let parser = WritParserFactory.make()
    private var renderer: String = "katex"

    init(fixturesDir: String, resultsPath: String?) {
        self.fixturesDir = fixturesDir
        self.resultsPath = resultsPath
        super.init()
    }

    func start() {
        Task {
            await runAll()
            NSApp.terminate(nil)
        }
    }

    private func makeWebView() async {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "writ")
        config.userContentController = controller
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderOut(nil)
        self.window = window
        self.webView = webView
        await loadShell()
    }

    private func loadShell() async {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "preview")
                ?? Bundle.main.url(forResource: "preview/index", withExtension: "html") else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "writ", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready", let cont = continuation {
            continuation = nil
            cont.resume()
        } else if type == "rendered", let cont = continuation {
            continuation = nil
            cont.resume()
        }
    }

    private func runAll() async {
        let names = ["10kb.md", "1mb.md", "5mb.md", "code-heavy.md", "math-heavy.md", "mermaid-heavy.md"]
        var results: [BenchmarkMode.Result] = []

        for renderer in ["katex", "mathjax"] {
            self.renderer = renderer
            // Fresh WebView per renderer to capture shell startup cost.
            await makeWebView()
            await evalAndWait("window.Writ && window.Writ.setMathRenderer('\(renderer)')")

            for name in names {
                let url = URL(fileURLWithPath: fixturesDir).appendingPathComponent(name)
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let snapshot = DocumentSnapshot(revision: DocumentRevision(1), source: source)
                let clock = ContinuousClock()

                let parseStart = clock.now
                guard let parsed = try? parser.parse(snapshot) else { continue }
                let payload = PreviewBridgePayload(revision: parsed.revision, html: parsed.html, blocks: parsed.blocks, theme: "auto")
                let json = (try? payload.encodedAsJSON()) ?? "{}"
                let parseAndEncode = micros(clock.now - parseStart)

                let paintStart = clock.now
                await evalAndWaitForRender(js: "window.Writ.update(\(json))")
                let firstPaint = micros(clock.now - paintStart)

                var warm: [Int] = []
                for i in 0..<5 {
                    let mutated = source + "\n<!-- iter \(i) -->\n"
                    let snap = DocumentSnapshot(revision: DocumentRevision(UInt64(i + 2)), source: mutated)
                    guard let parsed = try? parser.parse(snap) else { continue }
                    let payload = PreviewBridgePayload(revision: parsed.revision, html: parsed.html, blocks: parsed.blocks, theme: "auto")
                    let json = (try? payload.encodedAsJSON()) ?? "{}"
                    let s = clock.now
                    await evalAndWaitForRender(js: "window.Writ.update(\(json))")
                    warm.append(micros(clock.now - s))
                }

                results.append(BenchmarkMode.Result(
                    fixture: name,
                    byteCount: source.utf8.count,
                    blocks: parsed.blocks.count,
                    parseAndEncodeMicros: parseAndEncode,
                    firstPaintMicros: firstPaint,
                    warmUpdateMicrosP50: percentile(warm, 0.5),
                    warmUpdateMicrosP90: percentile(warm, 0.9),
                    mathRenderer: renderer
                ))
            }
        }

        print("renderer  fixture                bytes   parse+enc   firstPaint   warm_p50   warm_p90")
        for r in results {
            let line = pad(r.mathRenderer, 9) +
                       pad(r.fixture, 22) +
                       pad("\(r.byteCount)", 9, leftAlign: false) +
                       pad("\(r.parseAndEncodeMicros)", 12, leftAlign: false) +
                       pad("\(r.firstPaintMicros)", 13, leftAlign: false) +
                       pad("\(r.warmUpdateMicrosP50)", 11, leftAlign: false) +
                       pad("\(r.warmUpdateMicrosP90)", 11, leftAlign: false)
            print(line)
        }

        if let resultsPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(results) {
                try? data.write(to: URL(fileURLWithPath: resultsPath))
                print("results written to \(resultsPath)")
            }
        }
    }

    private func evalAndWait(_ js: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js) { _, _ in cont.resume() }
        }
    }

    private func evalAndWaitForRender(js: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            webView.evaluateJavaScript(js) { _, _ in /* wait for rendered message */ }
        }
    }

    private func micros(_ d: Duration) -> Int {
        let attos = d.components.attoseconds
        let secs = d.components.seconds
        return Int(secs) * 1_000_000 + Int(attos / 1_000_000_000_000)
    }

    private func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }

    private func pad(_ s: String, _ w: Int, leftAlign: Bool = true) -> String {
        if s.count >= w { return String(s.prefix(w)) }
        let fill = String(repeating: " ", count: w - s.count)
        return leftAlign ? s + fill : fill + s
    }
}
