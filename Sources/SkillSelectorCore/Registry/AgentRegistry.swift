import Foundation

public struct SkillRootDeclaration: Hashable, Sendable {
    public let value: String
    public let entryFilename: String
    public let agentID: String?

    public init(value: String, entryFilename: String = "SKILL.md", agentID: String?) {
        self.value = value
        self.entryFilename = entryFilename
        self.agentID = agentID
    }
}

public struct AgentRegistry: Sendable {
    public private(set) var definitions: [AgentDefinition]
    public let sharedGlobalRoots: [String]
    public let sharedProjectPatterns: [String]

    private let bundledDefinitions: [AgentDefinition]
    private var customDefinitions: [AgentDefinition]

    public init(
        definitions: [AgentDefinition],
        customDefinitions: [AgentDefinition] = [],
        sharedGlobalRoots: [String] = [],
        sharedProjectPatterns: [String] = []
    ) {
        bundledDefinitions = definitions
        self.customDefinitions = []
        self.definitions = definitions
        self.sharedGlobalRoots = Array(Set(sharedGlobalRoots)).sorted()
        self.sharedProjectPatterns = Array(Set(sharedProjectPatterns)).sorted()
        merge(customDefinitions: customDefinitions)
    }

    public var globalDeclarations: [SkillRootDeclaration] {
        declarations(
            shared: sharedGlobalRoots,
            bundled: bundledDefinitions.flatMap { definition in
                definition.globalRoots.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            },
            custom: customDefinitions.flatMap { definition in
                definition.globalRoots.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            }
        )
    }

    public var projectDeclarations: [SkillRootDeclaration] {
        declarations(
            shared: sharedProjectPatterns,
            bundled: bundledDefinitions.flatMap { definition in
                definition.projectPatterns.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            },
            custom: customDefinitions.flatMap { definition in
                definition.projectPatterns.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            }
        )
    }

    public func definition(id: String) -> AgentDefinition? {
        definitions.first { $0.id == id }
    }

    /// IDs of the bundled (built-in) definitions. Custom imports must not
    /// overwrite these — `merge(customDefinitions:)` enforces this by
    /// ignoring colliding custom definitions, and callers pre-validate
    /// against this set for user-facing error messages (audit R5).
    public var bundledDefinitionIDs: Set<String> {
        Set(bundledDefinitions.map(\.id))
    }

    public func matchingGlobalRoot(_ root: String) -> [AgentDefinition] {
        let ownerIDs = Set(globalDeclarations.filter { $0.value == root }.compactMap(\.agentID))
        return definitions.filter { ownerIDs.contains($0.id) }
    }

    public mutating func merge(customDefinitions newDefinitions: [AgentDefinition]) {
        for definition in newDefinitions {
            // Audit R5, now enforced here: a custom import whose id collides
            // with a bundled Agent is ignored instead of overwriting it.
            // Previously a hand-edited transfer file with `id: "claude"`
            // silently mutated a built-in Agent while this type's docs
            // claimed the opposite; callers still pre-validate via
            // `bundledDefinitionIDs` for user-facing error messages.
            guard !bundledDefinitionIDs.contains(definition.id) else { continue }
            if let index = customDefinitions.firstIndex(where: { $0.id == definition.id }) {
                customDefinitions[index] = definition
            } else {
                customDefinitions.append(definition)
            }
        }
        definitions = bundledDefinitions
        // Defensive re-check: even if `customDefinitions` were polluted
        // through some future path, bundled definitions are never replaced.
        for definition in customDefinitions
        where !bundledDefinitionIDs.contains(definition.id) {
            definitions.append(definition)
        }
    }

    private func declarations(
        shared: [String],
        bundled: [SkillRootDeclaration],
        custom: [SkillRootDeclaration]
    ) -> [SkillRootDeclaration] {
        var claimed = Set<String>()
        var result = [SkillRootDeclaration]()
        for declaration in shared.map({ SkillRootDeclaration(value: $0, agentID: nil) })
            + bundled + custom {
            let key = "\(declaration.value)\u{1f}\(declaration.entryFilename)"
            if claimed.insert(key).inserted {
                result.append(declaration)
            }
        }
        return result.sorted {
            $0.value == $1.value ? $0.entryFilename < $1.entryFilename : $0.value < $1.value
        }
    }
}
