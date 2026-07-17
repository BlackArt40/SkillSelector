import Foundation

public typealias CommandRunning = ExternalCommandRunning

public enum MetadataProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case github
    case npm
}

public struct MetadataQuery: Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct MetadataCandidate: Codable, Hashable, Sendable {
    public let provider: MetadataProviderKind
    public let sourceIdentifier: String
    public let skillSubdirectory: String?
    public let description: String
    public let evidenceURL: URL
    public let sourceBinding: String?

    public init(
        provider: MetadataProviderKind,
        sourceIdentifier: String,
        skillSubdirectory: String?,
        description: String,
        evidenceURL: URL,
        sourceBinding: String?
    ) {
        self.provider = provider
        self.sourceIdentifier = sourceIdentifier
        self.skillSubdirectory = skillSubdirectory
        self.description = description
        self.evidenceURL = evidenceURL
        self.sourceBinding = sourceBinding
    }
}

public enum SourceBindingDecision {
    public static func shouldRequestConfirmation(
        bindAsUpdateSource: Bool,
        sourceBinding: String?
    ) -> Bool {
        bindAsUpdateSource && sourceBinding != nil
    }
}

public protocol MetadataProvider: Sendable {
    func candidates(for query: MetadataQuery) async throws -> [MetadataCandidate]
}

public enum MetadataProviderError: Error, Equatable, Sendable {
    case invalidQuery
    case invalidResponse(provider: MetadataProviderKind)
    case rateLimited(provider: MetadataProviderKind)
    case unauthenticated(provider: MetadataProviderKind)
    case commandFailed(provider: MetadataProviderKind, status: Int32)
}

enum MetadataProviderSupport {
    static func validatedQueryName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.utf8.count <= 200,
              !name.hasPrefix("-"),
              !name.contains(":"),
              !name.contains("/"),
              !name.contains("\\"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw MetadataProviderError.invalidQuery
        }
        return name
    }

    static func checkedResult(
        _ result: CommandResult,
        provider: MetadataProviderKind
    ) throws -> Data {
        guard result.succeeded else {
            let errorText = result.stderrString.lowercased()
            if errorText.contains("rate limit")
                || errorText.contains("too many requests")
                || errorText.contains("e429") {
                throw MetadataProviderError.rateLimited(provider: provider)
            }
            if result.terminationStatus == 4
                || errorText.contains("auth login")
                || errorText.contains("unauthenticated")
                || errorText.contains("authentication required") {
                throw MetadataProviderError.unauthenticated(provider: provider)
            }
            throw MetadataProviderError.commandFailed(
                provider: provider,
                status: result.terminationStatus
            )
        }
        return result.stdout
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func readmeParagraph(_ value: String?) -> String? {
        guard let value else { return nil }
        return nonempty(rawDescriptiveParagraph(in: value))
    }

    private static func rawDescriptiveParagraph(in source: String) -> String? {
        let lines = sourceLines(source)
        var scanStart = 0
        if lines.first.map({ trimmed(source, line: $0) }) == "---",
           let boundary = lines.dropFirst().firstIndex(where: {
               trimmed(source, line: $0) == "---"
           }) {
            scanStart = boundary + 1
        }

        var paragraphStart: String.Index?
        var paragraphEnd: String.Index?
        var insideFence = false
        for line in lines.dropFirst(scanStart) {
            let value = trimmed(source, line: line)
            if value.hasPrefix("```") || value.hasPrefix("~~~") {
                if paragraphStart != nil { break }
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if value.isEmpty {
                if paragraphStart != nil { break }
                continue
            }
            if value == "---"
                || value.hasPrefix("#")
                || value.hasPrefix("-")
                || value.hasPrefix("*")
                || value.hasPrefix(">") {
                if paragraphStart != nil { break }
                continue
            }
            paragraphStart = paragraphStart ?? line.content.lowerBound
            paragraphEnd = line.content.upperBound
        }

        guard let paragraphStart, let paragraphEnd else { return nil }
        return String(source[paragraphStart..<paragraphEnd])
    }

    private struct SourceLine {
        let content: Range<String.Index>
    }

    private static func sourceLines(_ source: String) -> [SourceLine] {
        var lines: [SourceLine] = []
        var start = source.startIndex
        var cursor = start
        while cursor < source.endIndex {
            if source[cursor].isNewline {
                lines.append(SourceLine(content: start..<cursor))
                cursor = source.index(after: cursor)
                start = cursor
            } else {
                cursor = source.index(after: cursor)
            }
        }
        lines.append(SourceLine(content: start..<source.endIndex))
        return lines
    }

    private static func trimmed(_ source: String, line: SourceLine) -> String {
        source[line.content].trimmingCharacters(in: .whitespaces)
    }
}
