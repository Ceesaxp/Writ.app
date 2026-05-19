import Foundation

/// Status of an outstanding preview render job, used by the status bar UI and
/// the scheduler.
public enum RenderStatus: Sendable, Hashable {
    case idle
    case rendering(revision: DocumentRevision)
    case current(revision: DocumentRevision, duration: Duration)
    case stale(revision: DocumentRevision)
    case failed(revision: DocumentRevision, message: String)
}

/// Outcome of a single preview render attempt. The renderer always returns the
/// revision that produced the output so the scheduler can decide whether the
/// result is still relevant.
public struct RenderResult: Sendable {
    public let revision: DocumentRevision
    public let html: String
    public let blocks: [TechnicalBlock]
    public let duration: Duration
    public let diagnostics: [RenderDiagnostic]

    public init(
        revision: DocumentRevision,
        html: String,
        blocks: [TechnicalBlock],
        duration: Duration,
        diagnostics: [RenderDiagnostic] = []
    ) {
        self.revision = revision
        self.html = html
        self.blocks = blocks
        self.duration = duration
        self.diagnostics = diagnostics
    }
}

public struct RenderDiagnostic: Sendable, Hashable {
    public enum Severity: Sendable, Hashable { case info, warning, error }

    public let severity: Severity
    public let blockID: String?
    public let message: String

    public init(severity: Severity, blockID: String? = nil, message: String) {
        self.severity = severity
        self.blockID = blockID
        self.message = message
    }
}
