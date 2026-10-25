import Foundation
import WritCore
import WritParser

/// Why a remote PlantUML render didn't produce a diagram.
///
/// Every case is a reason to keep the caller's existing fallback (the
/// fence rendered as source) rather than to put anything in the preview.
public enum PlantUMLRenderError: Error, Equatable {
    /// The server answered, but not with 200.
    case badStatus(Int)
    /// The body didn't look like SVG — a misconfigured URL answering with
    /// an HTML login page lands here. Carries the response's `Content-Type`
    /// so the caller can say something useful.
    case notSVG(contentType: String?)
    /// The server answered 200 with nothing (or only whitespace) in it.
    case empty
}

/// Turns PlantUML source into SVG. Abstracted so the resolver — and the
/// App layer above it — can be exercised without a server.
public protocol PlantUMLRendering: Sendable {
    func renderSVG(source: String) async throws -> String
}

/// Renders PlantUML by POSTing the source to a PlantUML-server or Kroki
/// endpoint.
///
/// The wire protocol is deliberately the plainest one both servers accept:
/// `POST <endpoint>` with `Content-Type: text/plain` and the raw source as
/// the body, answering `200 image/svg+xml`. No deflate, no custom base64,
/// no hex — there is nothing to encode.
///
/// This is network egress of document content, so nothing here decides
/// *whether* to render: the caller gates that on a configured endpoint and
/// an explicit `plantuml: true` front-matter pragma.
public struct RemotePlantUMLRenderer: PlantUMLRendering {
    private let endpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(endpoint: URL, session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.session = session
        self.timeout = timeout
    }

    public func renderSVG(source: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(source.utf8)
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")

        if let http, http.statusCode != 200 {
            throw PlantUMLRenderError.badStatus(http.statusCode)
        }

        guard let decoded = String(data: data, encoding: .utf8) else {
            throw PlantUMLRenderError.notSVG(contentType: contentType)
        }
        let body = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PlantUMLRenderError.empty }

        // Check the shape of the payload before trusting it: a reverse
        // proxy or captive portal will happily answer 200 with an HTML
        // login page, and that must never reach the preview webview.
        guard Self.looksLikeSVG(body) else {
            throw PlantUMLRenderError.notSVG(contentType: contentType)
        }

        // Validate first, then sanitise. This is remote content being
        // injected into the preview, so it goes through the same sweep as
        // raw HTML from the document itself.
        return HTMLSanitizer.sanitize(body)
    }

    private static func looksLikeSVG(_ body: String) -> Bool {
        let head = body.prefix(5).lowercased()
        return head.hasPrefix("<svg") || head.hasPrefix("<?xml")
    }
}

/// Fills in the PlantUML blocks of a render pass, serving repeats from
/// ``TechnicalBlockCache`` instead of the network.
///
/// Never throws: a block that fails to render is simply absent from the
/// result, which leaves the caller's existing fallback (the fence shown as
/// source) in place for that one block.
public actor PlantUMLBlockResolver {
    private let renderer: any PlantUMLRendering
    private let cache: TechnicalBlockCache
    /// Opaque cache-invalidation token, passed straight through to the
    /// cache. The caller supplies the endpoint so that re-pointing Writ at
    /// a different server doesn't serve diagrams rendered by the old one.
    private let rendererVersion: String

    public init(renderer: any PlantUMLRendering, cache: TechnicalBlockCache, rendererVersion: String) {
        self.renderer = renderer
        self.cache = cache
        self.rendererVersion = rendererVersion
    }

    /// Maps block id -> sanitized SVG for every `.plantuml` block that
    /// rendered. Blocks of other kinds, and blocks that failed, are omitted.
    public func resolve(_ blocks: [TechnicalBlock]) async -> [String: String] {
        var resolved: [String: String] = [:]
        for group in Self.grouped(blocks) {
            guard let svg = await renderedSVG(for: group.block) else { continue }
            for id in group.ids { resolved[id] = svg }
        }
        return resolved
    }

    private func renderedSVG(for block: TechnicalBlock) async -> String? {
        if let hit = cache.get(block, rendererVersion: rendererVersion) {
            return hit.renderedHTML
        }
        let start = ContinuousClock.now
        do {
            let svg = try await renderer.renderSVG(source: block.source)
            cache.set(
                block,
                rendererVersion: rendererVersion,
                entry: TechnicalBlockCache.Entry(
                    renderedHTML: svg,
                    createdAt: Date(),
                    renderDuration: ContinuousClock.now - start
                )
            )
            return svg
        } catch {
            // Deliberately swallowed: one bad diagram must not cost the
            // others their render, and the caller has a fallback.
            return nil
        }
    }

    /// Collapses the `.plantuml` blocks onto one entry per distinct
    /// content, keeping source order.
    ///
    /// Grouping uses ``TechnicalBlock/contentHash`` — the same key the
    /// cache uses — so one render satisfies every block that would have
    /// hit the same cache entry.
    private static func grouped(_ blocks: [TechnicalBlock]) -> [(block: TechnicalBlock, ids: [String])] {
        var order: [ContentHash] = []
        var groups: [ContentHash: (block: TechnicalBlock, ids: [String])] = [:]
        for block in blocks where block.kind == .plantuml {
            let hash = block.contentHash
            if var group = groups[hash] {
                group.ids.append(block.id)
                groups[hash] = group
            } else {
                order.append(hash)
                groups[hash] = (block, [block.id])
            }
        }
        return order.compactMap { groups[$0] }
    }
}
