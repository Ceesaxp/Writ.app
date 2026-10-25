import Testing
import Foundation
import WritCore
import WritParser
@testable import WritRender

// MARK: - HTTP stubbing

/// Canned responses keyed by absolute URL, plus the requests the stub
/// protocol has seen.
///
/// `URLSession` instantiates the `URLProtocol` subclass itself, so there is
/// nowhere to inject per-test state — it has to be global. The lock makes
/// that safe under Swift 6 and under swift-testing's parallel execution;
/// tests additionally use a fresh URL each, so they can't read each other's
/// stubs even while running at the same time.
final class StubRegistry: @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    struct ObservedRequest {
        let method: String?
        let contentType: String?
        let body: Data
    }

    static let shared = StubRegistry()

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var observed: [String: [ObservedRequest]] = [:]

    /// A URL no test has stubbed, so each one gets its own keyspace.
    static func freshURL() -> URL {
        URL(string: "https://plantuml.stub.invalid/\(UUID().uuidString)")!
    }

    func stub(_ url: URL, status: Int = 200, contentType: String? = "image/svg+xml", body: Data) {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        lock.withLock { responses[url.absoluteString] = Response(status: status, headers: headers, body: body) }
    }

    func stub(_ url: URL, status: Int = 200, contentType: String? = "image/svg+xml", body: String) {
        stub(url, status: status, contentType: contentType, body: Data(body.utf8))
    }

    func response(for url: URL) -> Response? {
        lock.withLock { responses[url.absoluteString] }
    }

    func record(_ request: ObservedRequest, for url: URL) {
        lock.withLock { observed[url.absoluteString, default: []].append(request) }
    }

    func requests(for url: URL) -> [ObservedRequest] {
        lock.withLock { observed[url.absoluteString] ?? [] }
    }
}

/// Serves `StubRegistry` responses so no test touches the network.
///
/// `canInit` claims *every* request: gating it on "is this URL stubbed"
/// would let a typo fall through to the real network instead of failing.
final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        StubRegistry.shared.record(
            StubRegistry.ObservedRequest(
                method: request.httpMethod,
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: Self.body(of: request)
            ),
            for: url
        )
        guard let stub = StubRegistry.shared.response(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` hands a POST body to the protocol as a stream, not as
    /// `httpBody`, so reading only the latter would see an empty request.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let chunk = 4096
        var buffer = [UInt8](repeating: 0, count: chunk)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunk)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - RemotePlantUMLRenderer

@Suite("RemotePlantUMLRenderer")
struct RemotePlantUMLRendererTests {
    private let diagram = "@startuml\nAlice -> Bob: hi\n@enduml"

    @Test("A 200 image/svg+xml response returns the SVG")
    func successReturnsSVG() async throws {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, body: #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>"#)
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        let svg = try await renderer.renderSVG(source: diagram)

        #expect(svg.hasPrefix("<svg"))
        #expect(svg.contains("<rect"))
    }

    @Test("The request is a text/plain POST carrying the raw source")
    func postsRawSourceAsTextPlain() async throws {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, body: "<svg/>")
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        _ = try await renderer.renderSVG(source: diagram)

        let observed = try #require(StubRegistry.shared.requests(for: url).first)
        #expect(observed.method == "POST")
        #expect(observed.contentType == "text/plain; charset=utf-8")
        #expect(String(data: observed.body, encoding: .utf8) == diagram)
    }

    @Test("A hostile SVG response is defanged before it is returned")
    func hostileResponseIsSanitized() async throws {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, body: """
        <svg xmlns="http://www.w3.org/2000/svg">
        <script>alert(1)</script>
        <a xlink:href="javascript:void(0)"><text x="0" y="0">click</text></a>
        </svg>
        """)
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        let svg = try await renderer.renderSVG(source: diagram)

        #expect(!svg.contains("<script"))
        #expect(!svg.contains("alert(1)"))
        #expect(!svg.lowercased().contains("javascript:"))
        #expect(svg.contains("xlink:href=\"#\""))
        // The legitimate drawing survives the sweep.
        #expect(svg.contains("<text"))
    }

    @Test("A server error surfaces its status code")
    func serverErrorIsBadStatus() async {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, status: 500, contentType: "text/plain", body: "boom")
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        await #expect(throws: PlantUMLRenderError.badStatus(500)) {
            _ = try await renderer.renderSVG(source: diagram)
        }
    }

    @Test("A 200 HTML login page is rejected rather than injected")
    func htmlLoginPageIsNotSVG() async {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, status: 200, contentType: "text/html", body: """
        <!DOCTYPE html>
        <html><body><form action="/login"><input name="password"></form></body></html>
        """)
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        await #expect(throws: PlantUMLRenderError.notSVG(contentType: "text/html")) {
            _ = try await renderer.renderSVG(source: diagram)
        }
    }

    @Test("An empty body is reported as empty, not as a render")
    func emptyBodyIsEmpty() async {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, body: Data())
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        await #expect(throws: PlantUMLRenderError.empty) {
            _ = try await renderer.renderSVG(source: diagram)
        }
    }

    @Test("A whitespace-only body is reported as empty")
    func whitespaceOnlyBodyIsEmpty() async {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, body: "\n   \n")
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        await #expect(throws: PlantUMLRenderError.empty) {
            _ = try await renderer.renderSVG(source: diagram)
        }
    }

    @Test("An XML-declaration prologue is accepted")
    func xmlPrologueIsAccepted() async throws {
        let url = StubRegistry.freshURL()
        StubRegistry.shared.stub(url, body: """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>
        """)
        let renderer = RemotePlantUMLRenderer(endpoint: url, session: stubbedSession())

        let svg = try await renderer.renderSVG(source: diagram)

        #expect(svg.contains("<circle"))
    }
}

// MARK: - PlantUMLBlockResolver

/// A renderer that records what it was asked for and can be told to fail
/// for particular sources.
///
/// The resolver tests assert on *how many renders happened*, which is the
/// observable that matters for caching and deduplication, so they use this
/// rather than the HTTP stub: all blocks would POST to the same endpoint,
/// so failing one block and not its sibling would mean sniffing bodies.
final class RecordingRenderer: PlantUMLRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []
    private let failing: Set<String>

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var renderCount: Int { lock.withLock { sources.count } }
    var renderedSources: [String] { lock.withLock { sources } }

    func renderSVG(source: String) async throws -> String {
        lock.withLock { sources.append(source) }
        if failing.contains(source) { throw PlantUMLRenderError.badStatus(500) }
        return "<svg data-source=\"\(source)\"/>"
    }
}

@Suite("PlantUMLBlockResolver")
struct PlantUMLBlockResolverTests {
    private func block(_ id: String, _ source: String, kind: TechnicalBlockKind = .plantuml) -> TechnicalBlock {
        TechnicalBlock(id: id, kind: kind, source: source)
    }

    @Test("A plantuml block is rendered and keyed by its id")
    func resolvesPlantUMLBlock() async {
        let renderer = RecordingRenderer()
        let resolver = PlantUMLBlockResolver(renderer: renderer, cache: TechnicalBlockCache(), rendererVersion: "http://localhost:8080/svg")

        let resolved = await resolver.resolve([block("b1", "@startuml\nA->B\n@enduml")])

        #expect(resolved["b1"] == "<svg data-source=\"@startuml\nA->B\n@enduml\"/>")
        #expect(renderer.renderCount == 1)
    }

    @Test("Blocks of other kinds are left alone")
    func ignoresOtherKinds() async {
        let renderer = RecordingRenderer()
        let resolver = PlantUMLBlockResolver(renderer: renderer, cache: TechnicalBlockCache(), rendererVersion: "v1")

        let resolved = await resolver.resolve([
            block("m1", "graph TD", kind: .mermaid),
            block("x1", "x^2", kind: .math)
        ])

        #expect(resolved.isEmpty)
        #expect(renderer.renderCount == 0)
    }

    @Test("A cache hit issues no second render")
    func cacheHitSkipsRender() async {
        let renderer = RecordingRenderer()
        let cache = TechnicalBlockCache()
        let resolver = PlantUMLBlockResolver(renderer: renderer, cache: cache, rendererVersion: "v1")
        let diagram = block("b1", "@startuml\nA->B\n@enduml")

        let first = await resolver.resolve([diagram])
        let second = await resolver.resolve([diagram])

        #expect(renderer.renderCount == 1)
        #expect(first["b1"] != nil)
        #expect(second["b1"] == first["b1"])
    }

    @Test("A different renderer version is not served from the cache")
    func versionChangeForcesRerender() async {
        let renderer = RecordingRenderer()
        let cache = TechnicalBlockCache()
        let diagram = block("b1", "@startuml\nA->B\n@enduml")

        _ = await PlantUMLBlockResolver(renderer: renderer, cache: cache, rendererVersion: "http://a/svg")
            .resolve([diagram])
        _ = await PlantUMLBlockResolver(renderer: renderer, cache: cache, rendererVersion: "http://b/svg")
            .resolve([diagram])

        #expect(renderer.renderCount == 2)
    }

    @Test("Identical sources in one call are rendered once and both ids resolve")
    func deduplicatesWithinOneCall() async {
        let renderer = RecordingRenderer()
        let resolver = PlantUMLBlockResolver(renderer: renderer, cache: TechnicalBlockCache(), rendererVersion: "v1")
        let source = "@startuml\nA->B\n@enduml"

        let resolved = await resolver.resolve([block("b1", source), block("b2", source)])

        #expect(renderer.renderedSources == [source])
        #expect(resolved.count == 2)
        #expect(resolved["b1"] != nil)
        #expect(resolved["b2"] == resolved["b1"])
    }

    @Test("A failing block is omitted while its siblings still resolve")
    func failureIsOmitted() async {
        let renderer = RecordingRenderer(failing: ["@startuml\nbroken\n@enduml"])
        let resolver = PlantUMLBlockResolver(renderer: renderer, cache: TechnicalBlockCache(), rendererVersion: "v1")

        let resolved = await resolver.resolve([
            block("bad", "@startuml\nbroken\n@enduml"),
            block("good", "@startuml\nA->B\n@enduml")
        ])

        #expect(resolved["bad"] == nil)
        #expect(resolved["good"] != nil)
        #expect(resolved.count == 1)
    }

    @Test("A failed render is not cached, so a later call retries it")
    func failureIsNotCached() async {
        let renderer = RecordingRenderer(failing: ["@startuml\nbroken\n@enduml"])
        let cache = TechnicalBlockCache()
        let resolver = PlantUMLBlockResolver(renderer: renderer, cache: cache, rendererVersion: "v1")
        let diagram = block("bad", "@startuml\nbroken\n@enduml")

        _ = await resolver.resolve([diagram])
        _ = await resolver.resolve([diagram])

        #expect(renderer.renderCount == 2)
        #expect(cache.count == 0)
    }
}
