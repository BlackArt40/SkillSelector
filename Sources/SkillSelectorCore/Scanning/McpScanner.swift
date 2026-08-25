import Foundation

/// Scans authorized roots for MCP config files and parses their server
/// declarations. Read-only, mirrors `SkillScanner`'s philosophy: only paths
/// inside already-authorized roots are touched, config files are small and
/// read whole, and no probing happens here.
public struct McpScanner: Sendable {
    public init() {}

    /// Scans the given authorized roots.
    ///
    /// - Parameter homeRoot: the authorized `.home` root (or a system root
    ///   holding user-level configs). Global config paths resolve against it.
    /// - Parameter projectRoots: authorized `.project` roots. Project config
    ///   files (`.mcp.json` etc.) resolve inside each.
    public func scan(
        homeRoot: AuthorizedRootSnapshot?,
        projectRoots: [AuthorizedRootSnapshot]
    ) -> [McpServerDescriptor] {
        var servers: [McpServerDescriptor] = []

        for declaration in McpRegistry.globalDeclarations {
            guard let homeRoot,
                  let url = Self.resolve(globalPath: declaration.globalPath, relativeTo: homeRoot.url) else {
                continue
            }
            servers.append(contentsOf: parse(
                fileURL: url,
                format: declaration.format,
                agentID: declaration.agentID,
                projectRootID: nil
            ))
        }

        for root in projectRoots {
            for declaration in McpRegistry.projectDeclarations {
                guard let projectPath = declaration.projectPath else { continue }
                let url = root.url.appendingPathComponent(projectPath).standardizedFileURL
                servers.append(contentsOf: parse(
                    fileURL: url,
                    format: declaration.format,
                    agentID: declaration.agentID,
                    projectRootID: root.id
                ))
            }
        }

        return servers.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.configFile < rhs.configFile : lhs.name < rhs.name
        }
    }

    private func parse(
        fileURL: URL,
        format: String,
        agentID: String,
        projectRootID: String?
    ) -> [McpServerDescriptor] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let parsed: [ParsedMcpServer]
        do {
            parsed = try McpConfigParser.parse(data, format: format)
        } catch {
            return []
        }
        return parsed.filter { $0.command != nil || $0.url != nil }
            .map { server in
                McpServerDescriptor(
                    name: server.name,
                    agentID: agentID,
                    transport: server.transport,
                    command: server.command,
                    arguments: server.arguments,
                    url: server.url,
                    configFile: fileURL.path,
                    projectRootID: projectRootID
                )
            }
    }

    /// Resolves a `~/...` global path against the home root, guarding
    /// against escaping it (e.g. "~/.config/../../etc" style input).
    static func resolve(globalPath: String, relativeTo home: URL) -> URL? {
        let home = home.standardizedFileURL
        guard globalPath.hasPrefix("~/") else { return nil }
        let components = globalPath.dropFirst(2).split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let url = components.reduce(home) { $0.appendingPathComponent($1) }
            .standardizedFileURL
        guard url.isContained(in: home) else { return nil }
        return url
    }
}