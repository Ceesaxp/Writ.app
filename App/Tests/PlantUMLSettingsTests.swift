import Foundation
import Testing
import WritCore
import WritParser

/// `PlantUMLSettings` is the gate in front of the only feature in Writ that
/// sends document content off the machine, so both halves of the gate are
/// covered here rather than trusted to the UI.
///
/// Everything under test is pure, which is why these run in the hostless
/// bundle: no `UserDefaults`, no run loop, no network.
@Suite("PlantUML settings gate")
struct PlantUMLSettingsTests {

    // MARK: - endpoint(from:)

    @Test("an empty endpoint string is no endpoint, which is what keeps the feature off by default")
    func emptyStringIsNotAnEndpoint() {
        #expect(PlantUMLSettings.endpoint(from: "") == nil)
    }

    @Test("a whitespace-only endpoint string is no endpoint")
    func whitespaceOnlyStringIsNotAnEndpoint() {
        #expect(PlantUMLSettings.endpoint(from: "   \n\t ") == nil)
    }

    @Test("a local PlantUML-server URL parses")
    func localPlantUMLServerParses() {
        let url = PlantUMLSettings.endpoint(from: "http://localhost:8080/svg")
        #expect(url?.absoluteString == "http://localhost:8080/svg")
    }

    @Test("an https Kroki URL parses")
    func httpsKrokiURLParses() {
        let url = PlantUMLSettings.endpoint(from: "https://kroki.io/plantuml/svg")
        #expect(url?.absoluteString == "https://kroki.io/plantuml/svg")
    }

    @Test("a non-http scheme is rejected: this string is about to receive document content")
    func nonHTTPSchemeIsRejected() {
        #expect(PlantUMLSettings.endpoint(from: "ftp://example.com") == nil)
    }

    @Test("a string that isn't a URL is rejected rather than coerced")
    func nonURLStringIsRejected() {
        #expect(PlantUMLSettings.endpoint(from: "not a url") == nil)
    }

    @Test("a scheme with no host is rejected")
    func schemeWithoutHostIsRejected() {
        #expect(PlantUMLSettings.endpoint(from: "http://") == nil)
    }

    @Test("surrounding whitespace is trimmed, so a pasted URL still works")
    func surroundingWhitespaceIsTrimmed() {
        let url = PlantUMLSettings.endpoint(from: "  http://localhost:8080/svg\n")
        #expect(url?.absoluteString == "http://localhost:8080/svg")
    }

    // MARK: - shouldRender(frontMatter:endpoint:blocks:)

    private static let endpoint = URL(string: "http://localhost:8080/svg")!

    private static let plantUMLBlock = TechnicalBlock(
        id: "PLANTUML_0",
        kind: .plantuml,
        source: "@startuml\nAlice -> Bob: Writ\n@enduml"
    )

    /// Runs the pragma through the real front-matter parser rather than
    /// hand-building a `FrontMatter`, so the test fails if the parser ever
    /// stops reading the pragma the way the gate expects.
    private static func frontMatter(_ yaml: String) -> FrontMatter? {
        FrontMatterExtractor.extract(yaml)?.0
    }

    @Test("no configured endpoint means no render, whatever the document asks for")
    func noEndpointMeansNoRender() {
        let fm = Self.frontMatter("---\nplantuml: true\n---\n# Doc\n")
        #expect(fm != nil, "the fixture's front matter must parse for this test to mean anything")
        #expect(PlantUMLSettings.shouldRender(frontMatter: fm, endpoint: nil, blocks: [Self.plantUMLBlock]) == false)
    }

    @Test("a document with no front matter at all never renders")
    func absentFrontMatterMeansNoRender() {
        #expect(PlantUMLSettings.shouldRender(frontMatter: nil, endpoint: Self.endpoint, blocks: [Self.plantUMLBlock]) == false)
    }

    @Test("front matter without the pragma never renders: the opt-in has to be explicit")
    func missingPragmaMeansNoRender() {
        let fm = Self.frontMatter("---\ntitle: Notes\n---\n# Doc\n")
        #expect(fm != nil, "the fixture's front matter must parse for this test to mean anything")
        #expect(PlantUMLSettings.shouldRender(frontMatter: fm, endpoint: Self.endpoint, blocks: [Self.plantUMLBlock]) == false)
    }

    @Test("an explicit plantuml: false never renders")
    func falsePragmaMeansNoRender() {
        let fm = Self.frontMatter("---\nplantuml: false\n---\n# Doc\n")
        #expect(PlantUMLSettings.shouldRender(frontMatter: fm, endpoint: Self.endpoint, blocks: [Self.plantUMLBlock]) == false)
    }

    @Test("an opted-in document with no plantuml blocks makes no request")
    func noPlantUMLBlocksMeansNoRender() {
        let fm = Self.frontMatter("---\nplantuml: true\n---\n# Doc\n")
        let mermaid = TechnicalBlock(id: "MERMAID_0", kind: .mermaid, source: "graph TD; A-->B;")
        #expect(PlantUMLSettings.shouldRender(frontMatter: fm, endpoint: Self.endpoint, blocks: [mermaid]) == false)
        #expect(PlantUMLSettings.shouldRender(frontMatter: fm, endpoint: Self.endpoint, blocks: []) == false)
    }

    @Test("an endpoint, the pragma and a plantuml block together are the only way to render")
    func allThreeConditionsRender() {
        let fm = Self.frontMatter("---\nplantuml: true\n---\n# Doc\n")
        #expect(PlantUMLSettings.shouldRender(frontMatter: fm, endpoint: Self.endpoint, blocks: [Self.plantUMLBlock]) == true)
    }

    @Test("the pragma is case-insensitive in its value, as FrontMatter.isEnabled defines it")
    func pragmaValueIsCaseInsensitive() {
        let fm = Self.frontMatter("---\nplantuml: TRUE\n---\n# Doc\n")
        #expect(PlantUMLSettings.shouldRender(frontMatter: fm, endpoint: Self.endpoint, blocks: [Self.plantUMLBlock]) == true)
    }
}
