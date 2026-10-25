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
    /// Whether the preview should expect PlantUML diagrams to arrive
    /// out-of-band (via `Writ.applyResolvedBlocks`) for this revision.
    ///
    /// Purely a presentation hint: it decides whether the JS replaces the
    /// "not configured" notice with "Rendering diagram…" or leaves the
    /// fence exactly as the emitter produced it. The *decision* to talk to
    /// a server is made natively, in `PlantUMLSettings.shouldRender`.
    /// Defaults to `false`, so a caller that doesn't know about the
    /// feature gets the old behaviour.
    public let plantUMLEnabled: Bool

    public init(
        revision: DocumentRevision,
        html: String,
        blocks: [TechnicalBlock],
        theme: String,
        documentBaseURL: String? = nil,
        plantUMLEnabled: Bool = false
    ) {
        self.revision = revision.value
        self.html = html
        self.blocks = blocks.map { Block(id: $0.id, kind: $0.kind.rawValue, source: $0.source, language: $0.language) }
        self.theme = theme
        self.documentBaseURL = documentBaseURL
        self.plantUMLEnabled = plantUMLEnabled
    }

    public func encodedAsJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
