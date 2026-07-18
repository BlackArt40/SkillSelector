import Foundation

public protocol AgentDefinitionStoring: Sendable {
    func definitions() throws -> [AgentDefinition]
    func save(_ definition: AgentDefinition) throws
    func remove(id: String) throws
}

public final class UserDefaultsAgentDefinitionStore: AgentDefinitionStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "SkillSelector.customAgentDefinitions"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func definitions() throws -> [AgentDefinition] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try decoder.decode([AgentDefinition].self, from: data)
            .sorted { $0.id < $1.id }
    }

    public func save(_ definition: AgentDefinition) throws {
        var values = try definitions()
        if let index = values.firstIndex(where: { $0.id == definition.id }) {
            values[index] = definition
        } else {
            values.append(definition)
        }
        try persist(values)
    }

    public func remove(id: String) throws {
        try persist(try definitions().filter { $0.id != id })
    }

    private func persist(_ definitions: [AgentDefinition]) throws {
        defaults.set(try encoder.encode(definitions.sorted { $0.id < $1.id }), forKey: key)
    }
}
