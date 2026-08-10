import Foundation

public struct ParseIssue: Codable, Hashable, Sendable {
    public let line: Int?
    public let message: String
    public let diagnostic: StructuredDiagnostic?

    public init(
        line: Int? = nil,
        message: String,
        diagnostic: StructuredDiagnostic? = nil
    ) {
        self.line = line
        self.message = message
        self.diagnostic = diagnostic
    }

    public init(
        line: Int? = nil,
        code: DiagnosticCode,
        arguments: [String] = []
    ) {
        let diagnostic = StructuredDiagnostic(code: code, arguments: arguments)
        self.init(line: line, message: diagnostic.fallbackMessage, diagnostic: diagnostic)
    }
}

public struct ParsedSkillDocument: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var title: String?
    public var firstDescriptiveParagraph: String?
    public var fields: [String: String]
    public var issues: [ParseIssue]

    public init(
        name: String? = nil,
        description: String? = nil,
        title: String? = nil,
        firstDescriptiveParagraph: String? = nil,
        fields: [String: String] = [:],
        issues: [ParseIssue] = []
    ) {
        self.name = name
        self.description = description
        self.title = title
        self.firstDescriptiveParagraph = firstDescriptiveParagraph
        self.fields = fields
        self.issues = issues
    }
}
