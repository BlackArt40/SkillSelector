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

public struct DiagnosticExportInput: Codable, Hashable, Sendable {
    public let appVersion: String
    public let macOSVersion: String
    public let registryIDs: [String]
    public let roots: [DiagnosticRootSummary]
    public let diagnostics: [AppDiagnostic]

    public init(
        appVersion: String,
        macOSVersion: String,
        registryIDs: [String],
        roots: [DiagnosticRootSummary],
        diagnostics: [AppDiagnostic]
    ) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.registryIDs = registryIDs
        self.roots = roots
        self.diagnostics = diagnostics
    }
}

public struct DiagnosticExporter: Sendable {
    private let redactor: Redactor

    public init(redactor: Redactor = Redactor()) {
        self.redactor = redactor
    }

    /// The export payload with every string passed through the redactor.
    /// Also the source for the in-app read-only viewer, so what the user
    /// sees on screen can never be less redacted than what leaves the disk.
    public func sanitized(_ input: DiagnosticExportInput) -> DiagnosticExportInput {
        DiagnosticExportInput(
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
            diagnostics: input.diagnostics.map {
                AppDiagnostic(
                    timestamp: $0.timestamp,
                    category: $0.category,
                    code: redactor.redact($0.code),
                    message: redactor.redact($0.message)
                )
            }
        )
    }

    public func archive(_ input: DiagnosticExportInput) throws -> Data {
        let sanitizedInput = sanitized(input)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(sanitizedInput)
    }

    public func write(_ input: DiagnosticExportInput, to url: URL) throws {
        try archive(input).write(to: url, options: .atomic)
    }
}
