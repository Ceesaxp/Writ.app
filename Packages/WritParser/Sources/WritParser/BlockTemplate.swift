import Foundation

/// Pure-logic templates for the Insert menu's code/math/mermaid blocks.
///
/// Extracted from the editor view controller so the substitution shape
/// (prefix, placeholder body, suffix, where the cursor lands afterwards)
/// can be unit-tested without an NSTextView harness.
public struct BlockTemplate: Sendable, Equatable {
    public let prefix: String
    public let placeholder: String
    public let suffix: String

    public init(prefix: String, placeholder: String, suffix: String) {
        self.prefix = prefix
        self.placeholder = placeholder
        self.suffix = suffix
    }

    public static let code = BlockTemplate(prefix: "```\n", placeholder: "code", suffix: "\n```")
    public static let math = BlockTemplate(prefix: "$$\n", placeholder: "x^2 + y^2 = z^2", suffix: "\n$$")
    public static let mermaid = BlockTemplate(prefix: "```mermaid\n", placeholder: "graph TD\n  A --> B", suffix: "\n```")

    public struct InsertionPlan: Sendable, Equatable {
        public let inserted: String
        public let placeholderRange: NSRange
        public let needsLeadingBlank: Bool
    }

    /// Builds the final string to insert at `selectionLocation` plus the
    /// selection range that should be applied afterwards (the placeholder
    /// body, so the user can immediately type to replace it).
    public func plan(insertingAt selectionLocation: Int, in source: String) -> InsertionPlan {
        let needsLeadingBlank = needsLeading(in: source, at: selectionLocation)
        let leading = needsLeadingBlank ? "\n" : ""
        let inserted = leading + prefix + placeholder + suffix + "\n"
        let placeholderStart = selectionLocation + (leading as NSString).length + (prefix as NSString).length
        let placeholderRange = NSRange(location: placeholderStart, length: (placeholder as NSString).length)
        return InsertionPlan(inserted: inserted, placeholderRange: placeholderRange, needsLeadingBlank: needsLeadingBlank)
    }

    private func needsLeading(in source: String, at location: Int) -> Bool {
        guard location > 0 else { return false }
        let ns = source as NSString
        // We need a leading blank line iff we're not already at the start
        // of a paragraph (i.e. previous character is not a newline that
        // follows another newline).
        let start = max(0, location - 2)
        let length = min(2, location - start)
        guard length > 0 else { return false }
        let prefix = ns.substring(with: NSRange(location: start, length: length))
        return !prefix.hasSuffix("\n\n")
    }
}
