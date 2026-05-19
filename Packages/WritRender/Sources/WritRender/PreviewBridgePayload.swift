import Foundation
import WritCore

/// Payload sent from the native side to the preview JS for one render pass.
///
/// Encoded as JSON and either embedded in the initial shell or pushed via
/// `evaluateJavaScript("Writ.update(...)")` for subsequent updates.
public struct PreviewBridgePayload: Codable, Sendable {
    public struct Block: Codable, Sendable {
        public let id: String
        public let kind: String
        public let source: String
        public let language: String?
    }

    public let revision: UInt64
    public let html: String
    public let blocks: [Block]
    public let theme: String
    public let documentBaseURL: String?

    public init(revision: DocumentRevision, html: String, blocks: [TechnicalBlock], theme: String, documentBaseURL: String? = nil) {
        self.revision = revision.value
        self.html = html
        self.blocks = blocks.map { Block(id: $0.id, kind: $0.kind.rawValue, source: $0.source, language: $0.language) }
        self.theme = theme
        self.documentBaseURL = documentBaseURL
    }

    public func encodedAsJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
