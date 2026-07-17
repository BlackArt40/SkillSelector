import Foundation

public struct AgentRegistry: Sendable {
    public private(set) var definitions: [AgentDefinition]

    public init(definitions: [AgentDefinition], customDefinitions: [AgentDefinition] = []) {
        self.definitions = definitions
        merge(customDefinitions: customDefinitions)
    }

    public func definition(id: String) -> AgentDefinition? {
        definitions.first { $0.id == id }
    }

    public func matchingGlobalRoot(_ root: String) -> [AgentDefinition] {
        definitions.filter { $0.globalRoots.contains(root) }
    }

    public mutating func merge(customDefinitions: [AgentDefinition]) {
        for definition in customDefinitions {
            if let existingIndex = definitions.firstIndex(where: { $0.id == definition.id }) {
                definitions[existingIndex] = definition
            } else {
                definitions.append(definition)
            }
        }
    }
}
