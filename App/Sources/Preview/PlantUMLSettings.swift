import Foundation
import WritCore
import WritParser

/// The user preference behind the remote PlantUML renderer, plus the two
/// pure predicates that decide whether a render pass may use it.
///
/// Rendering PlantUML means sending the fence's source to a server, so it
/// stays off unless *two independent* conditions both hold: the user
/// configured an endpoint here, and the document itself opted in with a
/// `plantuml: true` front-matter pragma. Neither is set by default, and
/// neither implies the other — a document carrying the pragma renders
/// nothing on a machine with no endpoint, and a configured endpoint never
/// sees a document that didn't ask.
///
/// Unlike the other preference holders in this folder this enum is
/// deliberately *not* `@MainActor`: ``endpoint(from:)`` and
/// ``shouldRender(frontMatter:endpoint:blocks:)`` are pure functions of
/// their arguments, and keeping them off the main actor is what lets the
/// hostless test bundle exercise the gate without a run loop.
enum PlantUMLSettings {
    /// Front-matter key the document must set to `true`.
    static let frontMatterPragma = "plantuml"

    static let endpointDefaultsKey = "WritPlantUMLEndpoint"

    /// The endpoint as the user typed it. An empty string means the
    /// feature is off, which is the default.
    static var endpointURLString: String {
        get { UserDefaults.standard.string(forKey: endpointDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: endpointDefaultsKey) }
    }

    /// The configured endpoint, or `nil` when unset or unusable.
    static var endpointURL: URL? { endpoint(from: endpointURLString) }

    /// Parses a user-typed endpoint. Pure.
    ///
    /// Only `http` and `https` with a non-empty host pass. This string is
    /// about to receive document content, so the bar is "a server we can
    /// POST to": a `file:` or `ftp:` URL, a scheme-less word, and the
    /// host-less `http://` are all rejected rather than coerced.
    static func endpoint(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return url
    }

    /// Whether this render pass may send its diagrams to the endpoint. Pure.
    ///
    /// All three conditions must hold: an endpoint is configured, the
    /// document opted in, and there is actually a PlantUML block to render
    /// — the last one so an opted-in document without diagrams costs
    /// nothing.
    static func shouldRender(frontMatter: FrontMatter?, endpoint: URL?, blocks: [TechnicalBlock]) -> Bool {
        guard endpoint != nil else { return false }
        guard let frontMatter, frontMatter.isEnabled(frontMatterPragma) else { return false }
        return blocks.contains { $0.kind == .plantuml }
    }
}
