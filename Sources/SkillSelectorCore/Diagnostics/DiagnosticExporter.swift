import Foundation

public struct DiagnosticRootSummary: Codable, Hashable, Sendable {
    public let id: String
    public let kind: AuthorizedRootKind
    public let isAvailable: Bool

    public init(id: String, kind: AuthorizedRootKind, isAvailable: Bool) {
        self.id = id
        self.kind = kind
        self.isAvailable = isAvailable
    }
}

public struct DiagnosticToolSummary: Codable, Hashable, Sendable {
    public let kind: ToolKind
    public let state: ToolAvailabilityState
    public let version: String?

    public init(kind: ToolKind, state: ToolAvailabilityState, version: String?) {
        self.kind = kind
        self.state = state
        self.version = version
    }
}

public struct DiagnosticExportInput: Codable, Hashable, Sendable {
    public let appVersion: String
    public let macOSVersion: String
    public let registryIDs: [String]
    public let roots: [DiagnosticRootSummary]
    public let tools: [DiagnosticToolSummary]
    public let diagnostics: [AppDiagnostic]

    public init(
        appVersion: String,
        macOSVersion: String,
        registryIDs: [String],
        roots: [DiagnosticRootSummary],
        tools: [DiagnosticToolSummary],
        diagnostics: [AppDiagnostic]
    ) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.registryIDs = registryIDs
        self.roots = roots
        self.tools = tools
        self.diagnostics = diagnostics
    }
}

public struct DiagnosticExporter: Sendable {
    private let redactor: Redactor

    public init(redactor: Redactor = Redactor()) {
        self.redactor = redactor
    }

    public func archive(_ input: DiagnosticExportInput) throws -> Data {
        let sanitized = DiagnosticExportInput(
            appVersion: redactor.redact(input.appVersion),
            macOSVersion: redactor.redact(input.macOSVersion),
            registryIDs: input.registryIDs.map(redactor.redact).sorted(),
            roots: input.roots.map {
                DiagnosticRootSummary(
                    id: redactor.redact($0.id),
                    kind: $0.kind,
                    isAvailable: $0.isAvailable
                )
            }.sorted { $0.id < $1.id },
            tools: input.tools.map {
                DiagnosticToolSummary(
                    kind: $0.kind,
                    state: $0.state,
                    version: $0.version.map(redactor.redact)
                )
            }.sorted { $0.kind.rawValue < $1.kind.rawValue },
            diagnostics: input.diagnostics.map {
                AppDiagnostic(
                    timestamp: $0.timestamp,
                    category: $0.category,
                    code: redactor.redact($0.code),
                    message: redactor.redact($0.message)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(sanitized)
    }

    public func write(_ input: DiagnosticExportInput, to url: URL) throws {
        try archive(input).write(to: url, options: .atomic)
    }
}
