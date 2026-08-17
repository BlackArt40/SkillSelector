import Foundation

/// Local JSON interchange for custom Agent definitions, so a machine
/// migration can carry them out of UserDefaults (which never leaves the
/// machine it was written on).
public enum CustomAgentTransferError: Error, Equatable {
    case unreadableFile(String)
    case unsupportedFormat
}

public struct CustomAgentTransferDocument: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public let version: Int
    public let agents: [AgentDefinition]

    public init(agents: [AgentDefinition], version: Int = CustomAgentTransferDocument.formatVersion) {
        self.agents = agents
        self.version = version
    }
}

public struct CustomAgentTransfer: Sendable {
    public init() {}

    public func archive(_ agents: [AgentDefinition]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CustomAgentTransferDocument(agents: agents))
    }

    /// Entry filenames are validated on import so a hand-edited file cannot
    /// smuggle an unusable definition into the registry.
    public func parse(_ data: Data) throws -> [AgentDefinition] {
        let document: CustomAgentTransferDocument
        do {
            document = try JSONDecoder().decode(CustomAgentTransferDocument.self, from: data)
        } catch {
            throw CustomAgentTransferError.unreadableFile(String(describing: error))
        }
        guard document.version <= CustomAgentTransferDocument.formatVersion,
              document.version >= 1 else {
            throw CustomAgentTransferError.unsupportedFormat
        }
        return document.validated()
    }
}

private extension CustomAgentTransferDocument {
    func validated() -> [AgentDefinition] {
        agents.filter { definition in
            !definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && EntryFilename.isValid(definition.entryFilename)
        }
    }
}
